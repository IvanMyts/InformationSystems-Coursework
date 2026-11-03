-- =====================================================================
-- ИС «Бдительность». Этап 2.
-- 04_indexes.sql — индексы для самых частых запросов прецедентов.
-- Индексы первичных ключей и ограничений UNIQUE создаются автоматически
-- (01_create.sql); здесь созданы индексы, которые PostgreSQL сам не создаёт.
-- =====================================================================

BEGIN;

-- I1. UC17 «Посмотреть список заявок»: очередь необработанных заявок.
-- Частичный индекс содержит только активные заявки, доля которых мала.
CREATE INDEX idx_request_active ON service_request (status, created_at)
    WHERE status IN ('SUBMITTED', 'IN_PROGRESS', 'NEEDS_CLARIFICATION');

-- I2. UC10 «Мои заявки»: заявки жильца, новые сначала.
CREATE INDEX idx_request_resident ON service_request (resident_id, created_at DESC);

-- I3. UC10: история обработки заявки.
CREATE INDEX idx_request_event_request ON request_event (request_id, created_at);

-- I4. UC22 «Рассмотреть донос»: очередь нерассмотренных доносов.
CREATE INDEX idx_denunciation_pending ON denunciation (created_at)
    WHERE status = 'SUBMITTED';

-- I5. UC05 «Просмотреть баланс и историю операций».
CREATE INDEX idx_balance_operation_resident ON balance_operation (resident_id, created_at DESC);

-- I6. Непрочитанные уведомления на главной странице кабинета.
CREATE INDEX idx_notification_unread ON notification (account_id, created_at DESC)
    WHERE NOT is_read;

COMMIT;
