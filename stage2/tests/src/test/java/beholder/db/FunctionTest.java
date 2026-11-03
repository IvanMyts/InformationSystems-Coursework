package beholder.db;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.sql.SQLException;
import java.time.LocalDate;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Функции для критически важных запросов (03_functions.sql). */
@DisplayName("Функции")
class FunctionTest extends DbTest {

    /** Первое число следующего месяца — срок оплаты такого начисления ещё не прошёл. */
    private static final LocalDate NEXT_MONTH = LocalDate.now().withDayOfMonth(1).plusMonths(1);

    /** Пополняет баланс жильца через apply_payment_status. */
    private void topUp(int resident, int amount) throws SQLException {
        String id = "test-" + resident;
        exec("INSERT INTO payment (resident_id, yookassa_payment_id, amount) VALUES (?, ?, ?)", resident, id, amount);
        exec("SELECT apply_payment_status(?, 'SUCCEEDED')", id);
    }

    @Test
    @DisplayName("activate_account: учётная запись создаётся, код используется один раз")
    void activateAccount() throws SQLException {
        int resident = resident(apartment());
        exec("INSERT INTO invitation (resident_id, code) VALUES (?, 'TSTA0001')", resident);

        int account = number("SELECT activate_account('TSTA0001', 'test_login', 'hash')");
        assertEquals(account, number("SELECT account_id FROM resident WHERE id = ?", resident));
        assertError("BH422", "SELECT activate_account('TSTA0001', 'test_login2', 'hash')");
    }

    @Test
    @DisplayName("apply_payment_status: платёж зачисляется ровно один раз")
    void paymentOnce() throws SQLException {
        int resident = resident(apartment());
        exec("INSERT INTO payment (resident_id, yookassa_payment_id, amount) VALUES (?, 'test-pay', 700)", resident);

        assertTrue((Boolean) value("SELECT apply_payment_status('test-pay', 'SUCCEEDED')"));
        assertFalse((Boolean) value("SELECT apply_payment_status('test-pay', 'SUCCEEDED')"));
        assertEquals(700, number("SELECT balance FROM resident WHERE id = ?", resident));
        assertError("BH404", "SELECT apply_payment_status('test-unknown', 'SUCCEEDED')");
    }

    @Test
    @DisplayName("accrue_rent: одно начисление на квартиру, повторный запуск ничего не добавляет")
    void accrueRent() throws SQLException {
        int apartment = apartment();
        resident(apartment);
        resident(apartment);

        number("SELECT accrue_rent(?)", NEXT_MONTH);
        assertEquals(1, number("SELECT count(*) FROM rent_charge WHERE apartment_id = ?", apartment));
        assertEquals(0, number("SELECT accrue_rent(?)", NEXT_MONTH));
    }

    @Test
    @DisplayName("pay_rent: платит любой жилец квартиры, но только один раз")
    void payRentOnce() throws SQLException {
        int apartment = apartment();
        int first = resident(apartment);
        int second = resident(apartment);
        topUp(first, 1000);
        topUp(second, 1000);
        number("SELECT accrue_rent(?)", NEXT_MONTH);
        int charge = number("SELECT id FROM rent_charge WHERE apartment_id = ?", apartment);

        assertTrue((Boolean) value("SELECT pay_rent(?, ?)", second, charge));   // оплачено в срок
        assertEquals(520, number("SELECT balance FROM resident WHERE id = ?", second));
        assertError("BH409", "SELECT pay_rent(?, ?)", first, charge);
    }

    @Test
    @DisplayName("register_overdue_rent: возвращает жильцов квартиры с учётной записью")
    void overdueRent() throws SQLException {
        int apartment = apartment();
        int withAccount = resident(apartment);
        resident(apartment);
        int account = number("INSERT INTO account (login, password_hash, role) "
                + "VALUES ('test_overdue', 'hash', 'RESIDENT') RETURNING id");
        exec("UPDATE resident SET account_id = ? WHERE id = ?", account, withAccount);
        int charge = number("INSERT INTO rent_charge (apartment_id, period, amount, due_date) "
                + "VALUES (?, DATE '2020-01-01', 480, DATE '2020-01-11') RETURNING id", apartment);

        assertEquals(withAccount, number(
                "SELECT resident_id FROM register_overdue_rent(CURRENT_DATE) WHERE charge_id = ?", charge));
    }

    @Test
    @DisplayName("request_queue: необработанные заявки по убыванию ИЛ заявителя")
    void requestQueue() throws SQLException {
        int ordinary = resident(apartment());
        int loyal = resident(apartment());
        exec("INSERT INTO loyalty_change (resident_id, rule_code) VALUES (?, 'RL01')", loyal);
        String insert = "INSERT INTO service_request (resident_id, service_id, details, fee_paid) "
                + "VALUES (?, 1, 'Ремонт', 0) RETURNING id";
        int first = number(insert, ordinary);
        int second = number(insert, loyal);

        assertEquals(second, number("SELECT request_id FROM request_queue() WITH ORDINALITY AS q "
                + "WHERE request_id IN (?, ?) ORDER BY q.ordinality LIMIT 1", first, second));
    }

    @Test
    @DisplayName("resident_dossier: автор анонимного доноса не раскрывается")
    void dossier() throws SQLException {
        int suspect = resident(apartment());
        exec("INSERT INTO denunciation (author_id, suspect_id, description, is_anonymous) "
                + "VALUES (?, ?, 'Описание нарушения', TRUE)", resident(apartment()), suspect);

        assertEquals(1, number("SELECT count(*) FROM jsonb_array_elements("
                + "resident_dossier(?) -> 'denunciations_against') d WHERE d ->> 'author_id' IS NULL", suspect));
    }
}
