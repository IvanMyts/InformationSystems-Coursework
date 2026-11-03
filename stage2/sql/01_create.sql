-- =====================================================================
-- ИС «Бдительность». Этап 2.
-- 01_create.sql — типы, таблицы, ограничения и справочные данные.
-- Объекты создаются в текущей схеме (на helios — в личной схеме базы studs).
-- =====================================================================

BEGIN;

-- Перечислимые типы
CREATE TYPE account_role        AS ENUM ('RESIDENT', 'MANAGER');
CREATE TYPE resident_status     AS ENUM ('ACTIVE', 'EVICTED');
CREATE TYPE service_result_kind AS ENUM ('WORK_MARK', 'DOCUMENT', 'TICKET', 'PERMIT', 'RELOCATION', 'WARNING_REMOVAL');
CREATE TYPE request_status      AS ENUM ('SUBMITTED', 'IN_PROGRESS', 'NEEDS_CLARIFICATION', 'COMPLETED', 'REJECTED', 'CANCELLED');
CREATE TYPE denunciation_status AS ENUM ('SUBMITTED', 'CONFIRMED', 'REJECTED', 'FALSE');
CREATE TYPE punishment_type     AS ENUM ('WARNING', 'FINE', 'EVICTION');
CREATE TYPE payment_status      AS ENUM ('PENDING', 'SUCCEEDED', 'CANCELED');
CREATE TYPE rent_status         AS ENUM ('UNPAID', 'PAID');
CREATE TYPE balance_op_type     AS ENUM ('TOPUP', 'RENT', 'FEE', 'FEE_REFUND', 'FINE');

-- Учётная запись
CREATE TABLE account (
    id             SERIAL PRIMARY KEY,
    login          VARCHAR(50)  NOT NULL UNIQUE CHECK (login ~ '^[A-Za-z0-9_.]{3,50}$'),
    password_hash  VARCHAR(100) NOT NULL,
    role           account_role NOT NULL,
    is_blocked     BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);
-- управляющий в системе один (ограничение 2 SRS)
CREATE UNIQUE INDEX uq_account_single_manager ON account (role) WHERE role = 'MANAGER';

-- Квартира
CREATE TABLE apartment (
    id           SERIAL PRIMARY KEY,
    number       INTEGER       NOT NULL UNIQUE CHECK (number > 0),
    floor        SMALLINT      NOT NULL CHECK (floor BETWEEN 1 AND 50),
    area         NUMERIC(6,2)  NOT NULL CHECK (area > 0),
    rent_tariff  NUMERIC(10,2) NOT NULL CHECK (rent_tariff >= 0)
);

-- Жилец (в квартире не более 10 жильцов — проверяет триггер resident_guard;
-- отрицательный баланс — задолженность по штрафам)
CREATE TABLE resident (
    id               SERIAL PRIMARY KEY,
    account_id       INTEGER UNIQUE REFERENCES account (id),
    apartment_id     INTEGER NOT NULL REFERENCES apartment (id),
    last_name        VARCHAR(60)     NOT NULL CHECK (btrim(last_name)  <> ''),
    first_name       VARCHAR(60)     NOT NULL CHECK (btrim(first_name) <> ''),
    patronymic       VARCHAR(60),
    birth_date       DATE            NOT NULL CHECK (birth_date > DATE '1900-01-01'),
    phone            VARCHAR(20)     CHECK (phone ~ '^\+?[0-9\- ]{5,20}$'),
    loyalty_index    SMALLINT        NOT NULL DEFAULT 50 CHECK (loyalty_index BETWEEN 0 AND 100),
    balance          NUMERIC(12,2)   NOT NULL DEFAULT 0,
    status           resident_status NOT NULL DEFAULT 'ACTIVE',
    settled_at       TIMESTAMPTZ     NOT NULL DEFAULT now(),
    evicted_at       TIMESTAMPTZ,
    eviction_reason  TEXT,
    CHECK ((status = 'EVICTED') = (evicted_at IS NOT NULL)),
    CHECK (status = 'ACTIVE' OR eviction_reason IS NOT NULL)
);

-- Код приглашения (один на жильца, используется один раз)
CREATE TABLE invitation (
    id           SERIAL PRIMARY KEY,
    resident_id  INTEGER     NOT NULL UNIQUE REFERENCES resident (id) ON DELETE CASCADE,
    code         CHAR(8)     NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9]{8}$'),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    used_at      TIMESTAMPTZ CHECK (used_at >= created_at)
);

-- Услуга (фиксированный перечень SV01–SV09)
CREATE TABLE service (
    id            SMALLSERIAL PRIMARY KEY,
    code          CHAR(4)             NOT NULL UNIQUE CHECK (code ~ '^SV[0-9]{2}$'),
    name          VARCHAR(100)        NOT NULL UNIQUE,
    description   TEXT                NOT NULL,
    min_loyalty   SMALLINT            NOT NULL CHECK (min_loyalty BETWEEN 0 AND 100),
    fee           NUMERIC(10,2)       NOT NULL CHECK (fee >= 0),
    result_kind   service_result_kind NOT NULL,
    needs_period  BOOLEAN             NOT NULL DEFAULT FALSE
);

-- Заявка на услугу. status_changed_by и status_comment — кто и с каким
-- комментарием изменил статус последним; триггер переносит их в историю.
CREATE TABLE service_request (
    id                   SERIAL PRIMARY KEY,
    resident_id          INTEGER        NOT NULL REFERENCES resident (id),
    service_id           SMALLINT       NOT NULL REFERENCES service (id),
    details              TEXT           NOT NULL CHECK (btrim(details) <> ''),
    period_from          DATE,
    period_to            DATE,
    target_apartment_id  INTEGER        REFERENCES apartment (id),
    status               request_status NOT NULL DEFAULT 'SUBMITTED',
    fee_paid             NUMERIC(10,2)  NOT NULL CHECK (fee_paid >= 0),
    fee_refunded         BOOLEAN        NOT NULL DEFAULT FALSE,
    conclusion           TEXT,
    document_text        TEXT,
    valid_from           DATE,
    valid_to             DATE,
    rejection_reason     TEXT,
    status_changed_by    INTEGER        REFERENCES account (id),
    status_comment       TEXT,
    created_at           TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ    NOT NULL DEFAULT now(),
    CHECK (period_from <= period_to),
    CHECK (valid_from <= valid_to),
    CHECK (status <> 'COMPLETED' OR coalesce(btrim(conclusion), '') <> ''),
    CHECK (status <> 'REJECTED'  OR coalesce(btrim(rejection_reason), '') <> ''),
    CHECK (NOT fee_refunded OR status IN ('REJECTED', 'CANCELLED'))
);

-- История обработки заявки (журнал)
CREATE TABLE request_event (
    id           BIGSERIAL PRIMARY KEY,
    request_id   INTEGER        NOT NULL REFERENCES service_request (id),
    from_status  request_status,
    to_status    request_status NOT NULL,
    actor_id     INTEGER        REFERENCES account (id),
    comment      TEXT,
    created_at   TIMESTAMPTZ    NOT NULL DEFAULT now(),
    CHECK (from_status IS DISTINCT FROM to_status)
);

-- Донос
CREATE TABLE denunciation (
    id              SERIAL PRIMARY KEY,
    author_id       INTEGER             NOT NULL REFERENCES resident (id),
    suspect_id      INTEGER             NOT NULL REFERENCES resident (id),
    description     TEXT                NOT NULL CHECK (length(btrim(description)) >= 10),
    incident_date   DATE,
    is_anonymous    BOOLEAN             NOT NULL DEFAULT FALSE,
    status          denunciation_status NOT NULL DEFAULT 'SUBMITTED',
    review_comment  TEXT,
    reviewed_by     INTEGER             REFERENCES account (id),
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT now(),
    reviewed_at     TIMESTAMPTZ,
    CHECK (author_id <> suspect_id),
    CHECK ((status = 'SUBMITTED') = (reviewed_at IS NULL)),
    CHECK (reviewed_at >= created_at)
);

-- Наказание (сумма — только у штрафа; снять можно только предупреждение)
CREATE TABLE punishment (
    id                     SERIAL PRIMARY KEY,
    resident_id            INTEGER         NOT NULL REFERENCES resident (id),
    type                   punishment_type NOT NULL,
    amount                 NUMERIC(10,2)   CHECK (amount > 0),
    reason                 TEXT            NOT NULL CHECK (btrim(reason) <> ''),
    assigned_by            INTEGER         NOT NULL REFERENCES account (id),
    created_at             TIMESTAMPTZ     NOT NULL DEFAULT now(),
    is_revoked             BOOLEAN         NOT NULL DEFAULT FALSE,
    revoked_by_request_id  INTEGER         REFERENCES service_request (id),
    CHECK ((type = 'FINE') = (amount IS NOT NULL)),
    CHECK (NOT is_revoked OR (type = 'WARNING' AND revoked_by_request_id IS NOT NULL))
);

-- Основание наказания: связь M:N «наказание — донос»
CREATE TABLE punishment_basis (
    punishment_id    INTEGER NOT NULL REFERENCES punishment (id) ON DELETE CASCADE,
    denunciation_id  INTEGER NOT NULL REFERENCES denunciation (id),
    PRIMARY KEY (punishment_id, denunciation_id)
);

-- Платёж ЮKassa
CREATE TABLE payment (
    id                   SERIAL PRIMARY KEY,
    resident_id          INTEGER        NOT NULL REFERENCES resident (id),
    yookassa_payment_id  VARCHAR(64)    NOT NULL UNIQUE,
    amount               NUMERIC(12,2)  NOT NULL CHECK (amount > 0),
    status               payment_status NOT NULL DEFAULT 'PENDING',
    created_at           TIMESTAMPTZ    NOT NULL DEFAULT now(),
    confirmed_at         TIMESTAMPTZ,
    CHECK ((status = 'SUCCEEDED') = (confirmed_at IS NOT NULL))
);

-- Начисление квартплаты: одно на квартиру за месяц, оплачивает любой её жилец
CREATE TABLE rent_charge (
    id                  SERIAL PRIMARY KEY,
    apartment_id        INTEGER       NOT NULL REFERENCES apartment (id),
    period              DATE          NOT NULL CHECK (extract(day FROM period) = 1),
    amount              NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
    due_date            DATE          NOT NULL,
    status              rent_status   NOT NULL DEFAULT 'UNPAID',
    paid_at             TIMESTAMPTZ,
    paid_by             INTEGER       REFERENCES resident (id),
    overdue_registered  BOOLEAN       NOT NULL DEFAULT FALSE,
    UNIQUE (apartment_id, period),
    CHECK (due_date > period),
    CHECK ((status = 'PAID') = (paid_at IS NOT NULL)),
    CHECK ((status = 'PAID') = (paid_by IS NOT NULL))
);

-- Операция по балансу (журнал). Знак суммы и ссылка на источник
-- зависят от типа операции.
CREATE TABLE balance_operation (
    id              BIGSERIAL PRIMARY KEY,
    resident_id     INTEGER         NOT NULL REFERENCES resident (id),
    op_type         balance_op_type NOT NULL,
    amount          NUMERIC(12,2)   NOT NULL CHECK (amount <> 0),
    balance_after   NUMERIC(12,2)   NOT NULL,
    payment_id      INTEGER UNIQUE  REFERENCES payment (id),
    rent_charge_id  INTEGER UNIQUE  REFERENCES rent_charge (id),
    request_id      INTEGER         REFERENCES service_request (id),
    punishment_id   INTEGER UNIQUE  REFERENCES punishment (id),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    CHECK (op_type <> 'TOPUP'      OR (amount > 0 AND payment_id     IS NOT NULL)),
    CHECK (op_type <> 'RENT'       OR (amount < 0 AND rent_charge_id IS NOT NULL)),
    CHECK (op_type <> 'FEE'        OR (amount < 0 AND request_id     IS NOT NULL)),
    CHECK (op_type <> 'FEE_REFUND' OR (amount > 0 AND request_id     IS NOT NULL)),
    CHECK (op_type <> 'FINE'       OR (amount < 0 AND punishment_id  IS NOT NULL))
);

-- Правило изменения ИЛ (фиксированный перечень RL01–RL07)
CREATE TABLE loyalty_rule (
    code         CHAR(4)      PRIMARY KEY CHECK (code ~ '^RL[0-9]{2}$'),
    description  VARCHAR(200) NOT NULL,
    delta        SMALLINT     NOT NULL CHECK (delta <> 0)
);

-- Изменение ИЛ (журнал); delta_applied — изменение с учётом границ 0..100
CREATE TABLE loyalty_change (
    id               BIGSERIAL PRIMARY KEY,
    resident_id      INTEGER     NOT NULL REFERENCES resident (id),
    rule_code        CHAR(4)     NOT NULL REFERENCES loyalty_rule (code),
    delta_applied    SMALLINT    NOT NULL,
    value_after      SMALLINT    NOT NULL CHECK (value_after BETWEEN 0 AND 100),
    denunciation_id  INTEGER     REFERENCES denunciation (id),
    punishment_id    INTEGER     REFERENCES punishment (id),
    rent_charge_id   INTEGER     REFERENCES rent_charge (id),
    request_id       INTEGER     REFERENCES service_request (id),
    comment          TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Заметка управляющего в досье жильца
CREATE TABLE dossier_note (
    id           SERIAL PRIMARY KEY,
    resident_id  INTEGER     NOT NULL REFERENCES resident (id) ON DELETE CASCADE,
    author_id    INTEGER     NOT NULL REFERENCES account (id),
    text         TEXT        NOT NULL CHECK (btrim(text) <> ''),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Уведомление пользователю
CREATE TABLE notification (
    id          BIGSERIAL PRIMARY KEY,
    account_id  INTEGER     NOT NULL REFERENCES account (id) ON DELETE CASCADE,
    message     TEXT        NOT NULL,
    is_read     BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Справочные данные (ограничение 4 SRS): без них не работают внешние ключи
-- заявок и журнала ИЛ и триггер loyalty_change_apply.
INSERT INTO service (code, name, description, min_loyalty, fee, result_kind, needs_period) VALUES
 ('SV01', 'Бытовой ремонт',                          'Ремонт сантехники, электрики и иного оборудования квартиры.', 0,   0,   'WORK_MARK',       FALSE),
 ('SV02', 'Справка о проживании',                    'Справка, подтверждающая проживание в доме.',                  20,  50,  'DOCUMENT',        FALSE),
 ('SV03', 'Продовольственный талон',                 'Талон на получение продуктов на указанный период.',           30,  50,  'TICKET',          TRUE),
 ('SV04', 'Разрешение на приём гостей',              'Разрешение принимать гостей в указанные даты.',               40,  100, 'PERMIT',          TRUE),
 ('SV05', 'Разрешение на выход в комендантский час', 'Разрешение находиться вне дома в комендантский час.',         50,  100, 'PERMIT',          TRUE),
 ('SV06', 'Замена мебели и бытовой техники',         'Замена мебели или бытовой техники в квартире.',               60,  300, 'WORK_MARK',       FALSE),
 ('SV07', 'Переселение в другую квартиру',           'Переселение в квартиру дома со свободным местом.',            70,  300, 'RELOCATION',      FALSE),
 ('SV08', 'Разрешение на выезд из города',           'Разрешение покинуть город на указанный период.',              80,  300, 'PERMIT',          TRUE),
 ('SV09', 'Снятие предупреждения из досье',          'Снятие последнего действующего предупреждения.',              85,  500, 'WARNING_REMOVAL', FALSE);

INSERT INTO loyalty_rule (code, description, delta) VALUES
 ('RL01', 'Донос жильца подтверждён (кроме анонимного)',                  5),
 ('RL02', 'Донос жильца признан ложным (кроме анонимного)',             -10),
 ('RL03', 'Квартплата оплачена в течение 10 дней с даты начисления',      1),
 ('RL04', 'Квартплата не оплачена в течение 10 дней с даты начисления',  -5),
 ('RL05', 'Жильцу вынесено предупреждение',                             -10),
 ('RL06', 'Жильцу назначен штраф',                                      -15),
 ('RL07', 'Выполнена услуга SV09',                                       10);

COMMIT;
