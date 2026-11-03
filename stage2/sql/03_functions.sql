-- =====================================================================
-- ИС «Бдительность». Этап 2.
-- 03_functions.sql — функции для критически важных запросов
-- и представления.
--
-- Бизнес-логику (условия подачи заявок, правила ИЛ, уведомления, права)
-- реализует серверная часть на Spring, простые чтения и изменения она
-- выполняет через ORM. Функции нужны там, где операция должна быть
-- атомарной или выполняться одним запросом над многими строками:
-- активация по коду, зачисление и списание денег, ежемесячные расчёты,
-- очередь заявок и досье.
-- =====================================================================

BEGIN;

-- =====================================================================
-- Представления
-- =====================================================================

-- Доносы для управляющего: автор анонимного доноса не раскрывается (N005)
CREATE VIEW v_denunciation_for_manager AS
SELECT d.id,
       CASE WHEN d.is_anonymous THEN NULL ELSE d.author_id END AS author_id,
       d.suspect_id, d.description, d.incident_date, d.is_anonymous,
       d.status, d.review_comment, d.created_at, d.reviewed_at
FROM denunciation d;

-- История ИЛ для жильца: ссылки на доносы не выдаются (U004, N005)
CREATE VIEW v_loyalty_history AS
SELECT lc.id, lc.resident_id, lc.rule_code, lr.description AS rule_description,
       lc.delta_applied, lc.value_after, lc.comment, lc.created_at
FROM loyalty_change lc JOIN loyalty_rule lr ON lr.code = lc.rule_code;

-- Квартиры с числом проживающих и их списком (C001)
CREATE VIEW v_apartment_occupancy AS
SELECT a.id, a.number, a.floor, a.area, a.rent_tariff,
       count(r.id)::INTEGER AS resident_count,
       string_agg(r.last_name || ' ' || r.first_name, ', ' ORDER BY r.last_name) AS residents
FROM apartment a
LEFT JOIN resident r ON r.apartment_id = a.id AND r.status = 'ACTIVE'
GROUP BY a.id;

-- =====================================================================
-- Учётная запись
-- =====================================================================

-- UC01. Активировать учётную запись по коду приглашения.
-- Код помечается использованным и привязывается к новой учётной записи
-- в одной транзакции, поэтому один код нельзя активировать дважды даже
-- при одновременных запросах. Пароль хеширует приложение (bcrypt, N004).
CREATE FUNCTION activate_account(p_code CHAR(8), p_login VARCHAR, p_password_hash VARCHAR)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_resident INTEGER;
    v_account  INTEGER;
BEGIN
    UPDATE invitation SET used_at = now()
    WHERE code = upper(p_code) AND used_at IS NULL
    RETURNING resident_id INTO v_resident;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Код приглашения неверен или уже использован' USING ERRCODE = 'BH422';
    END IF;

    INSERT INTO account (login, password_hash, role)
    VALUES (p_login, p_password_hash, 'RESIDENT')
    RETURNING id INTO v_account;

    UPDATE resident SET account_id = v_account WHERE id = v_resident AND status = 'ACTIVE';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Жилец выселен, активация невозможна' USING ERRCODE = 'BH409';
    END IF;
    RETURN v_account;
END;
$$;

-- =====================================================================
-- Баланс и квартплата
-- =====================================================================

-- UC04. Применить статус платежа, полученный из ЮKassa (ограничение 6 SRS).
-- Обрабатывается только платёж в статусе PENDING, поэтому повторный вызов
-- ничего не меняет и деньги не зачисляются дважды (S003, N007).
-- Возвращает TRUE, если средства зачислены именно этим вызовом.
CREATE FUNCTION apply_payment_status(p_yookassa_id VARCHAR, p_status payment_status)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    v_pay payment%ROWTYPE;
BEGIN
    IF p_status = 'PENDING' THEN
        RETURN FALSE;
    END IF;

    UPDATE payment
    SET status = p_status,
        confirmed_at = CASE WHEN p_status = 'SUCCEEDED' THEN now() END
    WHERE yookassa_payment_id = p_yookassa_id AND status = 'PENDING'
    RETURNING * INTO v_pay;

    IF NOT FOUND THEN
        IF NOT EXISTS (SELECT 1 FROM payment WHERE yookassa_payment_id = p_yookassa_id) THEN
            RAISE EXCEPTION 'Платёж % не найден', p_yookassa_id USING ERRCODE = 'BH404';
        END IF;
        RETURN FALSE;   -- платёж уже обработан
    END IF;

    IF p_status = 'SUCCEEDED' THEN
        INSERT INTO balance_operation (resident_id, op_type, amount, payment_id)
        VALUES (v_pay.resident_id, 'TOPUP', v_pay.amount, v_pay.id);
    END IF;
    RETURN p_status = 'SUCCEEDED';
END;
$$;

-- UC06. Оплатить начисление квартплаты с баланса жильца. Начисление
-- выставлено квартире, оплатить его может любой её жилец, но только один
-- раз: строка начисления блокируется, и второй платёж получит ошибку.
-- Отметка об оплате и списание выполняются вместе; при недостатке средств
-- триггер журнала отменяет всю операцию. Возвращает TRUE, если оплата
-- сделана в срок (по этому признаку приложение применяет правило RL03).
CREATE FUNCTION pay_rent(p_resident_id INTEGER, p_charge_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    v_rc rent_charge%ROWTYPE;
BEGIN
    UPDATE rent_charge SET status = 'PAID', paid_at = now(), paid_by = p_resident_id
    WHERE id = p_charge_id AND status = 'UNPAID'
      AND apartment_id = (SELECT apartment_id FROM resident
                          WHERE id = p_resident_id AND status = 'ACTIVE')
    RETURNING * INTO v_rc;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Начисление % не относится к квартире жильца % или уже оплачено',
            p_charge_id, p_resident_id
            USING ERRCODE = 'BH409';
    END IF;

    IF v_rc.amount > 0 THEN
        INSERT INTO balance_operation (resident_id, op_type, amount, rent_charge_id)
        VALUES (p_resident_id, 'RENT', -v_rc.amount, v_rc.id);
    END IF;
    RETURN v_rc.paid_at::date <= v_rc.due_date;
END;
$$;

-- S001. Начислить квартплату за месяц одним запросом: одно начисление
-- в размере тарифа на каждую квартиру, где живёт хотя бы один жилец,
-- заселённый до конца месяца. Повторный запуск за тот же месяц дублей
-- не создаёт. Возвращает число новых начислений.
CREATE FUNCTION accrue_rent(p_period DATE)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_period DATE := date_trunc('month', p_period)::date;
    v_count  INTEGER;
BEGIN
    INSERT INTO rent_charge (apartment_id, period, amount, due_date)
    SELECT a.id, v_period, a.rent_tariff, v_period + 10
    FROM apartment a
    WHERE EXISTS (SELECT 1 FROM resident r
                  WHERE r.apartment_id = a.id AND r.status = 'ACTIVE'
                    AND r.settled_at < v_period + INTERVAL '1 month')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- S002. Отметить начисления, не оплаченные в срок, и вернуть жильцов
-- этих квартир с активированной учётной записью: приложение применяет
-- к каждому правило RL04 и отправляет уведомления.
CREATE FUNCTION register_overdue_rent(p_today DATE DEFAULT current_date)
RETURNS TABLE (charge_id INTEGER, resident_id INTEGER, period DATE)
LANGUAGE sql AS $$
    WITH marked AS (
        UPDATE rent_charge rc SET overdue_registered = TRUE
        WHERE rc.status = 'UNPAID' AND NOT rc.overdue_registered AND rc.due_date < p_today
        RETURNING rc.id, rc.apartment_id, rc.period)
    SELECT m.id, r.id, m.period
    FROM marked m JOIN resident r ON r.apartment_id = m.apartment_id
    WHERE r.status = 'ACTIVE' AND r.account_id IS NOT NULL;
$$;

-- =====================================================================
-- Выборки для управляющего
-- =====================================================================

-- UC17. Очередь необработанных заявок: по убыванию ИЛ заявителя,
-- затем по дате подачи (C006).
CREATE FUNCTION request_queue()
RETURNS TABLE (request_id INTEGER, created_at TIMESTAMPTZ, status request_status,
               service_name VARCHAR, resident_id INTEGER, resident_name TEXT,
               apartment_number INTEGER, loyalty_index SMALLINT)
LANGUAGE sql STABLE AS $$
    SELECT sr.id, sr.created_at, sr.status, s.name,
           r.id, r.last_name || ' ' || r.first_name, a.number, r.loyalty_index
    FROM service_request sr
    JOIN resident  r ON r.id = sr.resident_id
    JOIN service   s ON s.id = sr.service_id
    JOIN apartment a ON a.id = r.apartment_id
    WHERE sr.status IN ('SUBMITTED', 'IN_PROGRESS', 'NEEDS_CLARIFICATION')
      AND r.status = 'ACTIVE'
    ORDER BY r.loyalty_index DESC, sr.created_at, sr.id;
$$;

-- UC15. Досье жильца одним документом JSON: анкета, доносы на жильца
-- и поданные им, наказания, история ИЛ, заявки, операции, заметки (C017).
-- Авторы анонимных доносов не выдаются (N005).
CREATE FUNCTION resident_dossier(p_resident_id INTEGER)
RETURNS JSONB
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'resident', (SELECT to_jsonb(x) FROM (
            SELECT r.id, r.last_name, r.first_name, r.patronymic, r.birth_date,
                   r.phone, a.number AS apartment, r.loyalty_index, r.balance,
                   r.status, r.settled_at, r.evicted_at, r.eviction_reason
            FROM resident r JOIN apartment a ON a.id = r.apartment_id
            WHERE r.id = p_resident_id) x),
        'denunciations_against', coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.created_at DESC, d.id DESC)
            FROM v_denunciation_for_manager d WHERE d.suspect_id = p_resident_id), '[]'),
        'denunciations_filed', coalesce((SELECT jsonb_agg(jsonb_build_object(
                'id', d.id, 'suspect_id', d.suspect_id, 'status', d.status,
                'created_at', d.created_at) ORDER BY d.created_at DESC, d.id DESC)
            FROM denunciation d WHERE d.author_id = p_resident_id AND NOT d.is_anonymous), '[]'),
        'punishments', coalesce((SELECT jsonb_agg(jsonb_build_object(
                'id', p.id, 'type', p.type, 'amount', p.amount, 'reason', p.reason,
                'created_at', p.created_at, 'is_revoked', p.is_revoked,
                'denunciations', (SELECT coalesce(jsonb_agg(pb.denunciation_id), '[]')
                                  FROM punishment_basis pb WHERE pb.punishment_id = p.id))
                ORDER BY p.created_at DESC, p.id DESC)
            FROM punishment p WHERE p.resident_id = p_resident_id), '[]'),
        'loyalty_history', coalesce((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.created_at DESC, h.id DESC)
            FROM v_loyalty_history h WHERE h.resident_id = p_resident_id), '[]'),
        'requests', coalesce((SELECT jsonb_agg(jsonb_build_object(
                'id', sr.id, 'service', s.name, 'status', sr.status,
                'created_at', sr.created_at) ORDER BY sr.created_at DESC, sr.id DESC)
            FROM service_request sr JOIN service s ON s.id = sr.service_id
            WHERE sr.resident_id = p_resident_id), '[]'),
        'operations', coalesce((SELECT jsonb_agg(jsonb_build_object(
                'id', bo.id, 'type', bo.op_type, 'amount', bo.amount,
                'balance_after', bo.balance_after, 'created_at', bo.created_at)
                ORDER BY bo.created_at DESC, bo.id DESC)
            FROM balance_operation bo WHERE bo.resident_id = p_resident_id), '[]'),
        'notes', coalesce((SELECT jsonb_agg(jsonb_build_object(
                'id', n.id, 'text', n.text, 'created_at', n.created_at)
                ORDER BY n.created_at DESC, n.id DESC)
            FROM dossier_note n WHERE n.resident_id = p_resident_id), '[]')
    );
$$;

COMMIT;
