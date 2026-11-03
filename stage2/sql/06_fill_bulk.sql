-- =====================================================================
-- ИС «Бдительность». Этап 2.
-- 06_fill_bulk.sql — массовые данные для проверки индексов (N003):
-- 100 квартир, 300 жильцов, 10 000 заявок и 10 000 доносов.
-- Необязательный скрипт, выполняется после 05_fill.sql. Данные
-- детерминированы: распределение задаётся остатком от деления номера.
-- Массовые записи помечены: квартиры 31–100, логины bulk*,
-- текст «Массовая заявка» и «Массовый донос».
-- =====================================================================

BEGIN;

DO $$
DECLARE
    m INTEGER := (SELECT id FROM account WHERE role = 'MANAGER');
    n INTEGER;   -- число жильцов массовых данных
BEGIN
    -- ------------------------------------------------- квартиры 31–100 и 276 жильцов (по 3–4 на квартиру)
    INSERT INTO apartment (number, floor, area, rent_tariff)
    SELECT g, (g - 1) / 5 + 1, 32 + (g * 7) % 30, (32 + (g * 7) % 30) * 12
    FROM generate_series(31, 100) AS g;

    INSERT INTO resident (apartment_id, last_name, first_name, birth_date)
    SELECT a.id, 'Жилец' || g, 'Тест', DATE '1950-01-01' + ((g * 37) % 18000)::integer
    FROM generate_series(1, 300 - (SELECT count(*) FROM resident)::integer) AS g
    JOIN apartment a ON a.number = 31 + (g - 1) % 70
    ORDER BY g;

    CREATE TEMP TABLE bulk_resident ON COMMIT DROP AS
    SELECT r.id, row_number() OVER (ORDER BY r.id) - 1 AS k
    FROM resident r JOIN apartment a ON a.id = r.apartment_id
    WHERE a.number > 30;
    n := (SELECT count(*) FROM bulk_resident);

    -- коды приглашения, активация и пополнение баланса
    INSERT INTO invitation (resident_id, code)
    SELECT id, 'BULK' || lpad(id::text, 4, '0') FROM bulk_resident;
    PERFORM activate_account('BULK' || lpad(id::text, 4, '0'), 'bulk' || id,
                             (SELECT password_hash FROM account WHERE login = 'gromov'))
    FROM bulk_resident ORDER BY id;

    INSERT INTO payment (resident_id, yookassa_payment_id, amount)
    SELECT id, 'bulk-topup-' || id, 1000000 FROM bulk_resident;
    PERFORM apply_payment_status(yookassa_payment_id, 'SUCCEEDED')
    FROM payment WHERE yookassa_payment_id LIKE 'bulk-%' ORDER BY id;

    -- ------------------------------------------------- 10 000 заявок: SV01 — 50 %, SV02 — 30 %, SV04 — 20 %
    INSERT INTO service_request (resident_id, service_id, details, period_from, period_to,
                                 fee_paid, status_changed_by, status_comment)
    SELECT b.id, s.id, 'Массовая заявка № ' || g,
           CASE WHEN s.needs_period THEN DATE '2026-11-01' END,
           CASE WHEN s.needs_period THEN DATE '2026-11-02' END,
           s.fee, r.account_id, 'Заявка подана'
    FROM generate_series(1, 10000) AS g
    JOIN bulk_resident b ON b.k = (g * 7919) % n
    JOIN resident r ON r.id = b.id
    JOIN service s ON s.code = CASE WHEN g % 10 < 5 THEN 'SV01' WHEN g % 10 < 8 THEN 'SV02' ELSE 'SV04' END
    ORDER BY g;

    INSERT INTO balance_operation (resident_id, op_type, amount, request_id)
    SELECT resident_id, 'FEE', -fee_paid, id
    FROM service_request WHERE details LIKE 'Массовая заявка%' AND fee_paid > 0 ORDER BY id;

    -- статусы по остатку id % 100: 0–2 поданы, 3–5 в работе, 6 ждут уточнения,
    -- 7–11 отклонены, 12–13 отменены, 14–99 выполнены
    UPDATE service_request SET status = 'IN_PROGRESS', status_changed_by = m, status_comment = NULL
    WHERE details LIKE 'Массовая заявка%' AND (id % 100 BETWEEN 3 AND 6 OR id % 100 >= 14);

    UPDATE service_request SET status = 'NEEDS_CLARIFICATION', status_changed_by = m,
                               status_comment = 'Уточните сведения'
    WHERE details LIKE 'Массовая заявка%' AND id % 100 = 6;

    UPDATE service_request sr
    SET status = 'COMPLETED', conclusion = 'Выполнено', status_changed_by = m, status_comment = 'Выполнено',
        valid_from = CASE WHEN s.needs_period THEN DATE '2026-11-01' END,
        valid_to   = CASE WHEN s.needs_period THEN DATE '2026-11-02' END
    FROM service s
    WHERE s.id = sr.service_id AND sr.details LIKE 'Массовая заявка%' AND sr.id % 100 >= 14;

    UPDATE service_request SET status = 'REJECTED', rejection_reason = 'Недостаточно оснований',
                               fee_refunded = (id % 2 = 0 AND fee_paid > 0),
                               status_changed_by = m, status_comment = 'Недостаточно оснований'
    WHERE details LIKE 'Массовая заявка%' AND id % 100 BETWEEN 7 AND 11;

    UPDATE service_request sr SET status = 'CANCELLED', fee_refunded = (fee_paid > 0),
                                  status_changed_by = r.account_id, status_comment = 'Отменена жильцом'
    FROM resident r
    WHERE r.id = sr.resident_id AND sr.details LIKE 'Массовая заявка%' AND sr.id % 100 IN (12, 13);

    INSERT INTO balance_operation (resident_id, op_type, amount, request_id)
    SELECT resident_id, 'FEE_REFUND', fee_paid, id
    FROM service_request WHERE details LIKE 'Массовая заявка%' AND fee_refunded ORDER BY id;

    -- ------------------------------------------------- 10 000 доносов: 3 % ждут решения
    INSERT INTO denunciation (author_id, suspect_id, description, incident_date, is_anonymous)
    SELECT a.id, s.id, 'Массовый донос № ' || g, DATE '2026-10-01', g % 5 = 0
    FROM generate_series(1, 10000) AS g
    JOIN bulk_resident a ON a.k = (g * 31) % n
    JOIN bulk_resident s ON s.k = ((g * 31) % n + 1 + g % (n - 1)) % n
    ORDER BY g;

    UPDATE denunciation
    SET status = CASE WHEN id % 100 < 70 THEN 'REJECTED'
                      WHEN id % 100 < 75 THEN 'FALSE' ELSE 'CONFIRMED' END::denunciation_status,
        reviewed_by = m, reviewed_at = now(), review_comment = 'Рассмотрено'
    WHERE description LIKE 'Массовый донос%' AND id % 100 >= 3;

    -- ------------------------------------------------- квартплата за 12 месяцев; 5 % начислений не оплачено
    FOR g IN 0 .. 11 LOOP
        PERFORM accrue_rent((date_trunc('month', current_date) + make_interval(months => g))::date);
    END LOOP;

    PERFORM pay_rent((SELECT min(r.id) FROM resident r
                      WHERE r.apartment_id = rc.apartment_id AND r.status = 'ACTIVE'), rc.id)
    FROM rent_charge rc JOIN apartment a ON a.id = rc.apartment_id
    WHERE a.number > 30 AND rc.status = 'UNPAID' AND rc.id % 20 <> 0
    ORDER BY rc.id;

    -- ------------------------------------------------- уведомления о смене статуса заявок
    INSERT INTO notification (account_id, message)
    SELECT r.account_id, format('Заявка № %s: статус %s', e.request_id, e.to_status)
    FROM request_event e
    JOIN service_request sr ON sr.id = e.request_id
    JOIN resident r ON r.id = sr.resident_id
    WHERE sr.details LIKE 'Массовая заявка%' AND e.from_status IS NOT NULL
    ORDER BY e.id;
END;
$$;

COMMIT;

ANALYZE;
