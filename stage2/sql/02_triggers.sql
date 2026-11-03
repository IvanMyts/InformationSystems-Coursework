-- =====================================================================
-- ИС «Бдительность». Этап 2.
-- 02_triggers.sql — триггеры целостности данных.
--
-- Триггеры защищают только данные: журналы, согласованность баланса и ИЛ
-- с журналами, вместимость квартиры, модели состояний и историю заявок.
-- Бизнес-правила (условия подачи заявок, правила ИЛ, уведомления, права)
-- реализует серверная часть на Spring.
--
-- Коды ошибок (SQLSTATE), по которым Spring выбирает ответ HTTP:
--   BH404 — объект не найден;
--   BH409 — действие недопустимо в текущем состоянии;
--   BH422 — не выполнено условие (нет средств, неверный код, неподходящий донос).
-- Нарушения ограничений таблиц имеют стандартные коды:
--   23505 — UNIQUE, 23514 — CHECK, 23503 — внешний ключ.
-- =====================================================================

BEGIN;

-- 1. Журналы нельзя изменять и удалять (S008)
CREATE FUNCTION trg_forbid_modification() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Записи таблицы % не изменяются и не удаляются', TG_TABLE_NAME
        USING ERRCODE = 'BH409';
END;
$$;

CREATE TRIGGER balance_operation_immutable BEFORE UPDATE OR DELETE ON balance_operation
    FOR EACH ROW EXECUTE FUNCTION trg_forbid_modification();
CREATE TRIGGER loyalty_change_immutable BEFORE UPDATE OR DELETE ON loyalty_change
    FOR EACH ROW EXECUTE FUNCTION trg_forbid_modification();
CREATE TRIGGER request_event_immutable BEFORE UPDATE OR DELETE ON request_event
    FOR EACH ROW EXECUTE FUNCTION trg_forbid_modification();

-- 2. Операция по балансу изменяет баланс жильца и запоминает остаток.
--    В минус баланс уходит только из-за штрафа (S004).
CREATE FUNCTION trg_balance_operation_apply() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    SELECT balance INTO v_balance FROM resident WHERE id = NEW.resident_id FOR UPDATE;
    IF NEW.amount < 0 AND NEW.op_type <> 'FINE' AND v_balance + NEW.amount < 0 THEN
        RAISE EXCEPTION 'Недостаточно средств: на балансе % руб., требуется % руб.', v_balance, -NEW.amount
            USING ERRCODE = 'BH422';
    END IF;
    NEW.balance_after := v_balance + NEW.amount;
    UPDATE resident SET balance = NEW.balance_after WHERE id = NEW.resident_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER balance_operation_apply BEFORE INSERT ON balance_operation
    FOR EACH ROW EXECUTE FUNCTION trg_balance_operation_apply();

-- 3. Изменение ИЛ: величина берётся из правила, ИЛ остаётся в 0..100 (S005)
CREATE FUNCTION trg_loyalty_change_apply() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_current SMALLINT;
BEGIN
    SELECT loyalty_index INTO v_current FROM resident WHERE id = NEW.resident_id FOR UPDATE;
    NEW.value_after := LEAST(100, GREATEST(0,
        v_current + (SELECT delta FROM loyalty_rule WHERE code = NEW.rule_code)));
    NEW.delta_applied := NEW.value_after - v_current;
    UPDATE resident SET loyalty_index = NEW.value_after WHERE id = NEW.resident_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER loyalty_change_apply BEFORE INSERT ON loyalty_change
    FOR EACH ROW EXECUTE FUNCTION trg_loyalty_change_apply();

-- 4. Жилец:
--    - в квартире живут не более 10 жильцов (ограничение 7 SRS); строка
--      квартиры блокируется, чтобы одновременные заселения шли по очереди;
--    - новый жилец начинает с баланса 0 и ИЛ 50 (C002), дальше баланс и ИЛ
--      меняют только триггеры журналов (они работают на глубине >= 2).
CREATE FUNCTION trg_resident_guard() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'ACTIVE' AND (TG_OP = 'INSERT' OR NEW.apartment_id <> OLD.apartment_id
                                  OR OLD.status <> 'ACTIVE') THEN
        PERFORM 1 FROM apartment WHERE id = NEW.apartment_id FOR UPDATE;
        IF (SELECT count(*) FROM resident
            WHERE apartment_id = NEW.apartment_id AND status = 'ACTIVE' AND id <> NEW.id) >= 10 THEN
            RAISE EXCEPTION 'В квартире уже проживает 10 жильцов' USING ERRCODE = 'BH409';
        END IF;
    END IF;

    IF TG_OP = 'INSERT' AND (NEW.balance <> 0 OR NEW.loyalty_index <> 50) THEN
        RAISE EXCEPTION 'Новый жилец создаётся с балансом 0 и ИЛ 50' USING ERRCODE = 'BH409';
    END IF;
    IF TG_OP = 'UPDATE' AND pg_trigger_depth() < 2
       AND (NEW.balance <> OLD.balance OR NEW.loyalty_index <> OLD.loyalty_index) THEN
        RAISE EXCEPTION 'Баланс и ИЛ изменяются только через журналы' USING ERRCODE = 'BH409';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER resident_guard BEFORE INSERT OR UPDATE ON resident
    FOR EACH ROW EXECUTE FUNCTION trg_resident_guard();

-- 5. Модель состояний заявки (S009): заявка создаётся в статусе SUBMITTED,
--    далее — только допустимые переходы.
CREATE FUNCTION trg_request_status() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.status <> 'SUBMITTED' THEN
        RAISE EXCEPTION 'Заявка создаётся в статусе SUBMITTED' USING ERRCODE = 'BH409';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.status <> OLD.status AND NOT (
           (OLD.status = 'SUBMITTED'           AND NEW.status IN ('IN_PROGRESS', 'REJECTED', 'CANCELLED'))
        OR (OLD.status = 'IN_PROGRESS'         AND NEW.status IN ('NEEDS_CLARIFICATION', 'COMPLETED', 'REJECTED'))
        OR (OLD.status = 'NEEDS_CLARIFICATION' AND NEW.status = 'IN_PROGRESS')) THEN
        RAISE EXCEPTION 'Недопустимый переход статуса заявки: % → %', OLD.status, NEW.status
            USING ERRCODE = 'BH409';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER request_status BEFORE INSERT OR UPDATE ON service_request
    FOR EACH ROW EXECUTE FUNCTION trg_request_status();

-- 6. История заявки (S008): подача и каждая смена статуса записываются
--    с исполнителем и комментарием из status_changed_by и status_comment.
CREATE FUNCTION trg_request_history() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO request_event (request_id, to_status, actor_id, comment)
        VALUES (NEW.id, NEW.status, NEW.status_changed_by, NEW.status_comment);
    ELSIF NEW.status <> OLD.status THEN
        INSERT INTO request_event (request_id, from_status, to_status, actor_id, comment)
        VALUES (NEW.id, OLD.status, NEW.status, NEW.status_changed_by, NEW.status_comment);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER request_history AFTER INSERT OR UPDATE ON service_request
    FOR EACH ROW EXECUTE FUNCTION trg_request_history();

-- 7. Модель состояний доноса (S009): донос создаётся в статусе SUBMITTED,
--    решение принимается один раз.
CREATE FUNCTION trg_denunciation_status() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.status <> 'SUBMITTED' THEN
        RAISE EXCEPTION 'Донос создаётся в статусе SUBMITTED' USING ERRCODE = 'BH409';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.status <> OLD.status AND OLD.status <> 'SUBMITTED' THEN
        RAISE EXCEPTION 'Донос уже рассмотрен (статус %)', OLD.status USING ERRCODE = 'BH409';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER denunciation_status BEFORE INSERT OR UPDATE ON denunciation
    FOR EACH ROW EXECUTE FUNCTION trg_denunciation_status();

-- 8. Основание наказания (связь M:N) — подтверждённый донос на того же
--    жильца, которому назначено наказание (C013).
CREATE FUNCTION trg_punishment_basis_check() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM denunciation d JOIN punishment p ON p.id = NEW.punishment_id
                   WHERE d.id = NEW.denunciation_id AND d.status = 'CONFIRMED'
                     AND d.suspect_id = p.resident_id) THEN
        RAISE EXCEPTION 'Донос % не подтверждён или подан не на наказываемого жильца', NEW.denunciation_id
            USING ERRCODE = 'BH422';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER punishment_basis_check BEFORE INSERT OR UPDATE ON punishment_basis
    FOR EACH ROW EXECUTE FUNCTION trg_punishment_basis_check();

COMMIT;
