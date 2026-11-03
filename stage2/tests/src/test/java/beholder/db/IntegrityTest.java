package beholder.db;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.sql.SQLException;

import static org.junit.jupiter.api.Assertions.assertEquals;

/** Ограничения таблиц (01_create.sql) и триггеры целостности (02_triggers.sql). */
@DisplayName("Целостность данных")
class IntegrityTest extends DbTest {

    @Test
    @DisplayName("Ограничения таблиц: один управляющий, донос не на себя, у штрафа есть сумма")
    void tableConstraints() throws SQLException {
        manager();
        assertError("23505", "INSERT INTO account (login, password_hash, role) VALUES ('second', 'hash', 'MANAGER')");

        int resident = resident(apartment());
        assertError("23514", "INSERT INTO denunciation (author_id, suspect_id, description) "
                + "VALUES (?, ?, 'Описание нарушения')", resident, resident);
        assertError("23514", "INSERT INTO punishment (resident_id, type, reason, assigned_by) "
                + "VALUES (?, 'FINE', 'Нарушение', ?)", resident, manager());
    }

    @Test
    @DisplayName("Баланс меняется через журнал; в минус уводит только штраф")
    void balanceJournal() throws SQLException {
        int resident = resident(apartment());
        int fine = number("INSERT INTO punishment (resident_id, type, amount, reason, assigned_by) "
                + "VALUES (?, 'FINE', 300, 'Нарушение', ?) RETURNING id", resident, manager());
        exec("INSERT INTO balance_operation (resident_id, op_type, amount, punishment_id) "
                + "VALUES (?, 'FINE', -300, ?)", resident, fine);
        assertEquals(-300, number("SELECT balance FROM resident WHERE id = ?", resident));

        int request = number("INSERT INTO service_request (resident_id, service_id, details, fee_paid) "
                + "VALUES (?, 2, 'Справка', 0) RETURNING id", resident);
        assertError("BH422", "INSERT INTO balance_operation (resident_id, op_type, amount, request_id) "
                + "VALUES (?, 'FEE', -50, ?)", resident, request);
    }

    @Test
    @DisplayName("ИЛ меняется по правилу и остаётся в пределах 0–100")
    void loyaltyJournal() throws SQLException {
        int resident = resident(apartment());
        exec("INSERT INTO loyalty_change (resident_id, rule_code) VALUES (?, 'RL01')", resident);
        assertEquals(55, number("SELECT loyalty_index FROM resident WHERE id = ?", resident));

        for (int i = 0; i < 10; i++) {
            exec("INSERT INTO loyalty_change (resident_id, rule_code) VALUES (?, 'RL01')", resident);
        }
        assertEquals(100, number("SELECT loyalty_index FROM resident WHERE id = ?", resident));
    }

    @Test
    @DisplayName("Баланс и ИЛ нельзя изменить напрямую, журналы нельзя изменить")
    void noDirectChanges() throws SQLException {
        int resident = resident(apartment());
        exec("INSERT INTO loyalty_change (resident_id, rule_code) VALUES (?, 'RL01')", resident);

        assertError("BH409", "UPDATE resident SET balance = 1000 WHERE id = ?", resident);
        assertError("BH409", "UPDATE resident SET loyalty_index = 100 WHERE id = ?", resident);
        assertError("BH409", "DELETE FROM loyalty_change WHERE resident_id = ?", resident);
    }

    @Test
    @DisplayName("В квартире не больше 10 жильцов")
    void apartmentCapacity() throws SQLException {
        int apartment = apartment();
        for (int i = 0; i < 10; i++) {
            resident(apartment);
        }
        assertError("BH409", "INSERT INTO resident (apartment_id, last_name, first_name, birth_date) "
                + "VALUES (?, 'Тестов', 'Тест', DATE '1990-01-01')", apartment);
    }

    @Test
    @DisplayName("Статус заявки меняется по модели состояний, переходы пишутся в историю")
    void requestStatus() throws SQLException {
        int request = number("INSERT INTO service_request (resident_id, service_id, details, fee_paid) "
                + "VALUES (?, 1, 'Ремонт', 0) RETURNING id", resident(apartment()));
        exec("UPDATE service_request SET status = 'IN_PROGRESS' WHERE id = ?", request);
        exec("UPDATE service_request SET status = 'COMPLETED', conclusion = 'Готово' WHERE id = ?", request);

        assertEquals(3, number("SELECT count(*) FROM request_event WHERE request_id = ?", request));
        assertError("BH409", "UPDATE service_request SET status = 'SUBMITTED' WHERE id = ?", request);
    }

    @Test
    @DisplayName("Решение по доносу принимается один раз; основание наказания — подтверждённый донос")
    void denunciation() throws SQLException {
        int suspect = resident(apartment());
        int denunciation = number("INSERT INTO denunciation (author_id, suspect_id, description) "
                + "VALUES (?, ?, 'Описание нарушения') RETURNING id", resident(apartment()), suspect);
        int warning = number("INSERT INTO punishment (resident_id, type, reason, assigned_by) "
                + "VALUES (?, 'WARNING', 'Нарушение', ?) RETURNING id", suspect, manager());

        assertError("BH422", "INSERT INTO punishment_basis VALUES (?, ?)", warning, denunciation);

        exec("UPDATE denunciation SET status = 'CONFIRMED', reviewed_at = now() WHERE id = ?", denunciation);
        exec("INSERT INTO punishment_basis VALUES (?, ?)", warning, denunciation);
        assertError("BH409", "UPDATE denunciation SET status = 'REJECTED' WHERE id = ?", denunciation);
    }
}
