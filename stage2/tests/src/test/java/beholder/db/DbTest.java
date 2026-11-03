package beholder.db;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Savepoint;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;


abstract class DbTest {

    private static final String URL = env("DB_URL", "jdbc:postgresql://localhost:5432/beholder");
    private static final String USER = env("DB_USER", "postgres");
    private static final String PASSWORD = env("DB_PASSWORD", "");

    protected Connection db;

    @BeforeEach
    void connect() throws SQLException {
        db = DriverManager.getConnection(URL, USER, PASSWORD);
        db.setAutoCommit(false);
    }

    @AfterEach
    void rollback() throws SQLException {
        db.rollback();
        db.close();
    }

    /** Выполняет запрос. */
    protected void exec(String sql, Object... args) throws SQLException {
        try (PreparedStatement st = prepare(sql, args)) {
            st.execute();
        }
    }

    /** Возвращает первое значение результата запроса. */
    protected Object value(String sql, Object... args) throws SQLException {
        try (PreparedStatement st = prepare(sql, args); ResultSet rs = st.executeQuery()) {
            return rs.next() ? rs.getObject(1) : null;
        }
    }

    protected int number(String sql, Object... args) throws SQLException {
        return ((Number) value(sql, args)).intValue();
    }

    /** Проверяет, что запрос завершается ошибкой с кодом SQLSTATE. */
    protected void assertError(String sqlState, String sql, Object... args) throws SQLException {
        Savepoint savepoint = db.setSavepoint();
        SQLException e = assertThrows(SQLException.class, () -> exec(sql, args));
        db.rollback(savepoint);
        assertEquals(sqlState, e.getSQLState(), e.getMessage());
    }

    /** Новая квартира с тарифом 480 руб. */
    protected int apartment() throws SQLException {
        return number("INSERT INTO apartment (number, floor, area, rent_tariff) "
                + "SELECT coalesce(max(number), 0) + 1, 1, 40, 480 FROM apartment RETURNING id");
    }

    /** Новый жилец в квартире. */
    protected int resident(int apartment) throws SQLException {
        return number("INSERT INTO resident (apartment_id, last_name, first_name, birth_date) "
                + "VALUES (?, 'Тестов', 'Тест', DATE '1990-01-01') RETURNING id", apartment);
    }

    /** Учётная запись управляющего (существующая или новая). */
    protected int manager() throws SQLException {
        Object id = value("SELECT id FROM account WHERE role = 'MANAGER'");
        return id != null ? ((Number) id).intValue()
                : number("INSERT INTO account (login, password_hash, role) "
                        + "VALUES ('test_manager', 'hash', 'MANAGER') RETURNING id");
    }

    private PreparedStatement prepare(String sql, Object... args) throws SQLException {
        PreparedStatement st = db.prepareStatement(sql);
        for (int i = 0; i < args.length; i++) {
            st.setObject(i + 1, args[i]);
        }
        return st;
    }

    private static String env(String name, String defaultValue) {
        String value = System.getenv(name);
        return value == null || value.isBlank() ? defaultValue : value;
    }
}
