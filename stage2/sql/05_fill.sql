-- =====================================================================
-- ИС «Бдительность». Этап 2.
-- 05_fill.sql — тестовые данные. Выполняется сразу после install.sql
-- на пустой базе, поэтому идентификаторы известны заранее:
-- управляющий — учётная запись 1, жилец № N — запись N в resident,
-- донос № N — запись N в denunciation, заявка № N — запись N в service_request.
--
-- Скрипт делает то же, что будет делать серверная часть: пишет строки
-- и вызывает функции из 03_functions.sql, а последствия действий
-- (пошлины, правила ИЛ, наказания, уведомления) записывает явно.
--
-- Учётные записи: manager / manager123, жильцы gromov, belova и др. / resident123
-- =====================================================================

BEGIN;

DO $$
DECLARE
    -- bcrypt-хеши (cost 10) паролей manager123 и resident123
    c_manager_hash  CONSTANT TEXT := '$2a$10$flpiB2aXIbmhUgp83bL.3eQEdfH1Wg8s4Cx21qDwETEq5SLehNGzi';
    c_resident_hash CONSTANT TEXT := '$2a$10$yEpqWNJv1WQ.bwx.4go04.P0czv6HFXcGeP1U2r9.s5W0EzUIA3/6';
BEGIN
    -- ------------------------------------------------- управляющий и квартиры
    INSERT INTO account (login, password_hash, role) VALUES ('manager', c_manager_hash, 'MANAGER');

    INSERT INTO apartment (number, floor, area, rent_tariff)
    SELECT n, (n - 1) / 5 + 1, 32 + (n * 7) % 30, (32 + (n * 7) % 30) * 12
    FROM generate_series(1, 30) AS n;

    -- ------------------------------------------------- заселение (UC13)
    -- жилец № N живёт в квартире № N; жильцы 23 и 24 подселены в квартиры 21 и 22
    INSERT INTO resident (apartment_id, last_name, first_name, patronymic, birth_date, phone, settled_at)
    SELECT a.id, v.last_name, v.first_name, v.patronymic, v.birth_date, v.phone,
           TIMESTAMPTZ '2026-09-01 10:00:00+03'
    FROM (VALUES
        ( 1,  1, 'Громов',   'Аркадий', 'Павлович',       DATE '1958-03-14', '+7 900 100-01-01'),
        ( 2,  2, 'Белова',   'Нина',    'Сергеевна',      DATE '1965-07-02', '+7 900 100-01-02'),
        ( 3,  3, 'Шустов',   'Олег',    'Игоревич',       DATE '1972-11-23', '+7 900 100-01-03'),
        ( 4,  4, 'Кравец',   'Лидия',   'Андреевна',      DATE '1980-01-30', '+7 900 100-01-04'),
        ( 5,  5, 'Зотов',    'Пётр',    'Ильич',          DATE '1949-05-09', '+7 900 100-01-05'),
        ( 6,  6, 'Ланская',  'Вера',    'Михайловна',     DATE '1990-09-17', '+7 900 100-01-06'),
        ( 7,  7, 'Мельник',  'Степан',  'Богданович',     DATE '1975-04-11', '+7 900 100-01-07'),
        ( 8,  8, 'Орлова',   'Тамара',  'Викторовна',     DATE '1968-12-05', '+7 900 100-01-08'),
        ( 9,  9, 'Ершов',    'Глеб',    'Константинович', DATE '1986-06-21', '+7 900 100-01-09'),
        (10, 10, 'Сабурова', 'Ирина',   'Олеговна',       DATE '1993-02-14', '+7 900 100-01-10'),
        (11, 11, 'Ткач',     'Виктор',  'Семёнович',      DATE '1961-08-30', '+7 900 100-01-11'),
        (12, 12, 'Фомина',   'Алла',    'Петровна',       DATE '1983-10-10', '+7 900 100-01-12'),
        (13, 13, 'Рябов',    'Денис',   'Юрьевич',        DATE '1979-03-03', '+7 900 100-01-13'),
        (14, 14, 'Кузьмина', 'Зоя',     'Аркадьевна',     DATE '1955-01-19', '+7 900 100-01-14'),
        (15, 15, 'Литвин',   'Марк',    'Ефимович',       DATE '1988-07-07', '+7 900 100-01-15'),
        (16, 16, 'Голубева', 'Ольга',   'Николаевна',     DATE '1971-05-25', '+7 900 100-01-16'),
        (17, 17, 'Никитин',  'Юрий',    'Валентинович',   DATE '1966-11-11', '+7 900 100-01-17'),
        (18, 18, 'Пахомова', 'Дарья',   'Игоревна',       DATE '1995-04-04', '+7 900 100-01-18'),
        (19, 19, 'Осипов',   'Лев',     'Григорьевич',    DATE '1952-09-09', '+7 900 100-01-19'),
        (20, 20, 'Ветрова',  'Анна',    'Леонидовна',     DATE '1987-12-12', '+7 900 100-01-20'),
        (21, 21, 'Сомов',    'Илья',    'Борисович',      DATE '1991-06-30', NULL),
        (22, 22, 'Чернова',  'Елена',   'Павловна',       DATE '1984-02-28', NULL),
        (23, 21, 'Жуков',    'Артём',   'Олегович',       DATE '1997-08-15', NULL),
        (24, 22, 'Мирская',  'Софья',   'Дмитриевна',     DATE '1960-10-01', NULL)
    ) AS v (n, apt, last_name, first_name, patronymic, birth_date, phone)
    JOIN apartment a ON a.number = v.apt
    ORDER BY v.n;

    -- коды приглашения (в приложении их генерирует SecureRandom)
    INSERT INTO invitation (resident_id, code)
    SELECT id, 'TEST' || lpad(id::text, 4, '0') FROM resident ORDER BY id;

    -- ------------------------------------------------- активация (UC01); жильцы 21–24 ещё не активировали
    PERFORM activate_account('TEST' || lpad(v.n::text, 4, '0'), v.login, c_resident_hash)
    FROM (VALUES (1, 'gromov'), (2, 'belova'), (3, 'shustov'), (4, 'kravets'), (5, 'zotov'),
                 (6, 'lanskaya'), (7, 'melnik'), (8, 'orlova'), (9, 'ershov'), (10, 'saburova'),
                 (11, 'tkach'), (12, 'fomina'), (13, 'ryabov'), (14, 'kuzmina'), (15, 'litvin'),
                 (16, 'golubeva'), (17, 'nikitin'), (18, 'pakhomova'), (19, 'osipov'), (20, 'vetrova')
         ) AS v (n, login)
    ORDER BY v.n;

    -- ------------------------------------------------- пополнение баланса (UC04)
    INSERT INTO payment (resident_id, yookassa_payment_id, amount)
    SELECT t.n, format('2f3a0000-000f-5000-9000-%s', lpad(t.n::text, 12, '0')), t.amount
    FROM unnest(ARRAY[6000, 5000, 4000, 4000, 3500, 4000, 400, 4000, 3000, 4000,
                      3000, 3500, 3000, 3500, 1500, 3500, 2500, 3000, 2500, 2200])
         WITH ORDINALITY AS t (amount, n);
    PERFORM apply_payment_status(yookassa_payment_id, 'SUCCEEDED') FROM payment ORDER BY id;
    -- повторное подтверждение ничего не меняет (N007)
    PERFORM apply_payment_status('2f3a0000-000f-5000-9000-000000000001', 'SUCCEEDED');
    -- платёж в ожидании и отменённый платёж
    INSERT INTO payment (resident_id, yookassa_payment_id, amount) VALUES
        (3, '2f3a0000-000f-5000-9000-000000000101', 1000),
        (6, '2f3a0000-000f-5000-9000-000000000102', 500);
    PERFORM apply_payment_status('2f3a0000-000f-5000-9000-000000000102', 'CANCELED');

    INSERT INTO notification (account_id, message)
    SELECT r.account_id, format('Баланс пополнен на %s руб.', p.amount)
    FROM payment p JOIN resident r ON r.id = p.resident_id
    WHERE p.status = 'SUCCEEDED';

    -- ------------------------------------------------- квартплата (S001, UC06, S002)
    PERFORM accrue_rent(DATE '2026-10-01');
    PERFORM accrue_rent(DATE '2026-11-01');
    -- уведомление о начислении получают все жильцы квартиры
    INSERT INTO notification (account_id, message)
    SELECT r.account_id, format('Начислена квартплата за %s: %s руб.', to_char(rc.period, 'MM.YYYY'), rc.amount)
    FROM rent_charge rc JOIN resident r ON r.apartment_id = rc.apartment_id
    WHERE r.account_id IS NOT NULL;

    -- октябрь оплачивают жильцы 1–14 (кроме 7), ноябрь — 1–20 (кроме 7, 15, 17, 19)
    PERFORM pay_rent(r.id, rc.id)
    FROM resident r JOIN rent_charge rc ON rc.apartment_id = r.apartment_id
    WHERE (rc.period = DATE '2026-10-01' AND r.id BETWEEN 1 AND 14 AND r.id <> 7)
       OR (rc.period = DATE '2026-11-01' AND r.id BETWEEN 1 AND 20 AND r.id NOT IN (7, 15, 17, 19))
    ORDER BY rc.period, r.id;

    -- RL03 — плательщику за оплату в срок; RL04 — всем жильцам квартиры за просрочку
    INSERT INTO loyalty_change (resident_id, rule_code, rent_charge_id, comment)
    SELECT paid_by, 'RL03', id, 'Квартплата оплачена в срок'
    FROM rent_charge WHERE status = 'PAID' AND paid_at::date <= due_date ORDER BY id;

    INSERT INTO loyalty_change (resident_id, rule_code, rent_charge_id, comment)
    SELECT resident_id, 'RL04', charge_id, 'Просрочена квартплата'
    FROM register_overdue_rent(DATE '2026-10-31');

    -- ------------------------------------------------- доносы (UC11)
    INSERT INTO denunciation (author_id, suspect_id, description, incident_date, is_anonymous)
    SELECT v.author, v.suspect, v.text, v.incident, v.anonymous
    FROM (VALUES
        ( 1,  1,  7, 'Сварщик Мельник после полуночи выносил из подвала мешки с неизвестным содержимым.', DATE '2026-10-02', FALSE),
        ( 2,  1,  9, 'Ершов на служебной машине вывозил из города посторонних людей без разрешения.',      DATE '2026-10-03', FALSE),
        ( 3,  1, 11, 'Из квартиры Ткача ночью слышна иностранная радиопередача.',                          DATE '2026-10-04', FALSE),
        ( 4,  1, 13, 'Рябов самовольно подключился к общедомовой электросети.',                              DATE '2026-10-05', FALSE),
        ( 5,  1, 15, 'Литвин фотографировал двор и окна соседей.',                                           DATE '2026-10-06', FALSE),
        ( 6,  1, 17, 'Никитин хранит в квартире запрещённую литературу.',                                     DATE '2026-10-07', FALSE),
        ( 7,  1, 19, 'Осипов переплетал книги без штампа цензора.',                                         DATE '2026-10-08', FALSE),
        ( 8,  1,  7, 'Мельник повторно выносил мешки из подвала, содержимое прятал в подсобке.',             DATE '2026-10-09', FALSE),
        ( 9,  1, 15, 'Литвин передавал плёнки неизвестному лицу у подъезда.',                                DATE '2026-10-10', FALSE),
        (10,  2, 11, 'Ткач принимал у себя гостей после комендантского часа.',                               DATE '2026-10-11', FALSE),
        (11,  2, 13, 'Рябов громко высказывался против новых директив.',                                     DATE '2026-10-12', FALSE),
        (12,  2, 19, 'Осипов распространял самодельные брошюры.',                                           DATE '2026-10-13', FALSE),
        (13,  2,  9, 'Ершов курил на лестнице и оскорблял соседей.',                                        DATE '2026-10-14', FALSE),
        (14,  2, 15, 'Литвин проявлял фотографии в ванной ночью.',                                         DATE '2026-10-15', FALSE),
        (15,  4,  7, 'Мельник прятал инструменты в подвале.',                                              DATE '2026-10-09', TRUE),
        (16,  3,  4, 'Кравец выносила медикаменты из больницы.',                                           DATE '2026-10-16', FALSE),
        (17,  8,  5, 'Зотов слишком часто бывает на почте.',                                              DATE '2026-10-17', FALSE),
        (18, 10,  1, 'Громов хранит дома незарегистрированный радиоприёмник.',                              DATE '2026-10-18', FALSE),
        (19, 12, 16, 'Голубева выносила продукты из столовой.',                                          DATE '2026-10-20', FALSE),
        (20, 14, 18, 'Пахомова собирает у себя студентов по вечерам.',                                   DATE '2026-10-21', TRUE),
        (21, 20,  6, 'Ланская подслушивает чужие телефонные разговоры.',                                 DATE '2026-10-22', FALSE),
        (22,  6,  3, 'Шустов хранит чертежи у себя дома.',                                                DATE '2026-10-23', FALSE),
        (23,  1, 19, 'Осипов передавал соседям переплетённые брошюры без штампа.',                           DATE '2026-10-24', FALSE)
    ) AS v (n, author, suspect, text, incident, anonymous)
    ORDER BY v.n;

    -- ------------------------------------------------- рассмотрение доносов (UC22); 19–22 ждут решения
    UPDATE denunciation SET status = 'CONFIRMED', reviewed_by = 1, reviewed_at = now(),
                            review_comment = 'Факты подтверждены проверкой'
    WHERE id <= 15 OR id IN (18, 23);
    UPDATE denunciation SET status = 'FALSE', reviewed_by = 1, reviewed_at = now(),
                            review_comment = 'Проверка в больнице нарушений не выявила'
    WHERE id = 16;
    UPDATE denunciation SET status = 'REJECTED', reviewed_by = 1, reviewed_at = now(),
                            review_comment = 'Посещение почты не является нарушением'
    WHERE id = 17;

    -- RL01 / RL02 — только авторам неанонимных доносов
    INSERT INTO loyalty_change (resident_id, rule_code, denunciation_id, comment)
    SELECT author_id, CASE status WHEN 'CONFIRMED' THEN 'RL01' ELSE 'RL02' END, id,
           format('Рассмотрен донос № %s', id)
    FROM denunciation WHERE status IN ('CONFIRMED', 'FALSE') AND NOT is_anonymous ORDER BY id;

    INSERT INTO notification (account_id, message)
    SELECT r.account_id, format('Донос № %s рассмотрен: %s', d.id, d.status)
    FROM denunciation d JOIN resident r ON r.id = d.author_id
    WHERE d.status <> 'SUBMITTED' AND r.account_id IS NOT NULL;

    -- ------------------------------------------------- наказания (UC23, UC14)
    INSERT INTO punishment (resident_id, type, amount, reason, assigned_by)
    SELECT v.resident, v.type::punishment_type, v.amount, v.reason, 1
    FROM (VALUES
        ( 1,  7, 'FINE',     1000::numeric, 'Хищение имущества из подвала'),
        ( 2,  9, 'WARNING',  NULL,          'Незаконная перевозка людей'),
        ( 3,  9, 'FINE',     300,           'Незаконная перевозка людей'),
        ( 4,  9, 'WARNING',  NULL,          'Нарушение порядка в подъезде'),
        ( 5, 11, 'WARNING',  NULL,          'Прослушивание иностранного радио'),
        ( 6, 11, 'FINE',     250,           'Приём гостей в комендантский час'),
        ( 7, 13, 'FINE',     200,           'Самовольное подключение к электросети'),
        ( 8, 13, 'WARNING',  NULL,          'Высказывания против директив'),
        ( 9, 19, 'WARNING',  NULL,          'Работа без штампа цензора'),
        (10,  1, 'WARNING',  NULL,          'Хранение незарегистрированного приёмника'),
        (11, 15, 'FINE',     300,           'Фотосъёмка жилого двора'),
        (12, 15, 'FINE',     500,           'Передача плёнок посторонним'),
        (13, 15, 'FINE',     200,           'Использование ванной как фотолаборатории'),
        (14, 15, 'EVICTION', NULL,          'ИЛ ниже критического уровня'),
        (15, 17, 'EVICTION', NULL,          'Хранение запрещённой литературы')
    ) AS v (n, resident, type, amount, reason)
    ORDER BY v.n;

    -- основания (M:N): наказание 1 — по трём доносам, донос 2 — основание наказаний 2 и 3;
    -- выселение 14 назначено без доноса
    INSERT INTO punishment_basis (punishment_id, denunciation_id) VALUES
        (1, 1), (1, 8), (1, 15), (2, 2), (3, 2), (4, 13), (5, 3), (6, 10), (7, 4),
        (8, 11), (9, 7), (9, 12), (10, 18), (11, 5), (12, 9), (13, 14), (15, 6);

    -- последствия: штраф списывается с баланса, RL05 / RL06, уведомления
    INSERT INTO balance_operation (resident_id, op_type, amount, punishment_id)
    SELECT resident_id, 'FINE', -amount, id FROM punishment WHERE type = 'FINE' ORDER BY id;

    INSERT INTO loyalty_change (resident_id, rule_code, punishment_id, comment)
    SELECT resident_id, CASE type WHEN 'WARNING' THEN 'RL05' ELSE 'RL06' END, id, reason
    FROM punishment WHERE type <> 'EVICTION' ORDER BY id;

    INSERT INTO notification (account_id, message)
    SELECT r.account_id, CASE p.type WHEN 'WARNING' THEN 'Вам вынесено предупреждение: '
                                     ELSE format('Вам назначен штраф %s руб.: ', p.amount) END || p.reason
    FROM punishment p JOIN resident r ON r.id = p.resident_id
    WHERE p.type <> 'EVICTION' AND r.account_id IS NOT NULL;

    -- ИЛ Литвина опустился ниже 10 — уведомление управляющему (S007)
    INSERT INTO notification (account_id, message)
    SELECT 1, format('ИЛ жильца %s %s опустился до %s. Жилец подлежит выселению.',
                     last_name, first_name, loyalty_index)
    FROM resident WHERE loyalty_index < 10;

    -- выселение: статус жильца и блокировка учётной записи (C005)
    UPDATE resident r SET status = 'EVICTED', evicted_at = now(), eviction_reason = p.reason
    FROM punishment p WHERE p.resident_id = r.id AND p.type = 'EVICTION';
    UPDATE account SET is_blocked = TRUE
    WHERE id IN (SELECT account_id FROM resident WHERE status = 'EVICTED');

    -- ------------------------------------------------- заявки (UC07)
    INSERT INTO service_request (resident_id, service_id, details, period_from, period_to,
                                 target_apartment_id, fee_paid, status_changed_by, status_comment)
    SELECT v.resident, s.id, v.details, v.period_from, v.period_to, a.id, s.fee, r.account_id, 'Заявка подана'
    FROM (VALUES
        ( 1,  5, 'SV01', 'Протекает кран на кухне.',                                  NULL::date,        NULL::date,        NULL::integer),
        ( 2,  3, 'SV04', 'Приезд брата на выходные.',                                 DATE '2026-11-07', DATE '2026-11-08', NULL),
        ( 3,  6, 'SV02', 'Справка для предъявления по месту работы.',                 NULL,              NULL,              NULL),
        ( 4,  8, 'SV03', 'Талон на ноябрь.',                                          DATE '2026-11-01', DATE '2026-11-30', NULL),
        ( 5, 10, 'SV04', 'Приём родителей.',                                          DATE '2026-11-14', DATE '2026-11-15', NULL),
        ( 6, 12, 'SV05', 'Ночное дежурство в библиотеке.',                            DATE '2026-11-05', DATE '2026-11-05', NULL),
        ( 7, 14, 'SV01', 'Не работает розетка в комнате.',                            NULL,              NULL,              NULL),
        ( 8, 16, 'SV02', 'Справка для поликлиники.',                                  NULL,              NULL,              NULL),
        ( 9, 20, 'SV03', 'Дополнительный талон.',                                     DATE '2026-11-01', DATE '2026-11-30', NULL),
        (10, 18, 'SV02', 'Справка для общежития.',                                    NULL,              NULL,              NULL),
        (11,  2, 'SV07', 'Прошу переселить в квартиру большей площади.',              NULL,              NULL,              27),
        (12,  1, 'SV08', 'Поездка к сестре в соседний город.',                        DATE '2026-11-20', DATE '2026-11-27', NULL),
        (13,  1, 'SV09', 'Прошу снять предупреждение: приёмник сдан на регистрацию.', NULL,              NULL,              NULL)
    ) AS v (n, resident, code, details, period_from, period_to, target)
    JOIN service s ON s.code = v.code
    JOIN resident r ON r.id = v.resident
    LEFT JOIN apartment a ON a.number = v.target
    ORDER BY v.n;

    -- пошлина списывается при подаче
    INSERT INTO balance_operation (resident_id, op_type, amount, request_id)
    SELECT resident_id, 'FEE', -fee_paid, id FROM service_request WHERE fee_paid > 0 ORDER BY id;

    -- ------------------------------------------------- обработка заявок (UC08, UC09, UC18–UC21)
    -- 1, 2 — поданы; 5 — в работе; 6 — ждёт уточнения
    UPDATE service_request SET status = 'IN_PROGRESS', status_changed_by = 1, status_comment = NULL
    WHERE id IN (3, 4, 5, 6, 7, 9, 11, 12, 13);

    UPDATE service_request sr SET status = 'NEEDS_CLARIFICATION', status_changed_by = 1, status_comment = v.question
    FROM (VALUES (6, 'Приложите приказ о дежурстве с подписью начальника.'),
                 (7, 'Укажите удобное время для визита электрика.')) AS v (id, question)
    WHERE sr.id = v.id;

    -- ответ жильца на уточнение
    UPDATE service_request SET status = 'IN_PROGRESS', status_comment = 'В будни после 18:00.',
                               status_changed_by = (SELECT account_id FROM resident WHERE id = 14)
    WHERE id = 7;

    UPDATE service_request sr
    SET status = 'COMPLETED', conclusion = v.conclusion, document_text = v.document,
        valid_from = v.valid_from, valid_to = v.valid_to, status_changed_by = 1, status_comment = v.conclusion
    FROM (VALUES
        ( 3, 'Справка выдана.', 'СПРАВКА. Ланская Вера Михайловна проживает в доме, кв. 6. Управляющий домом.',
             NULL::date, NULL::date),
        ( 4, 'Талон выдан.', 'ТАЛОН № 1108 на получение продуктов', DATE '2026-11-01', DATE '2026-11-30'),
        ( 7, 'Розетка заменена электриком.', NULL, NULL, NULL),
        (11, 'Жилец переселён в квартиру № 27.', NULL, NULL, NULL),
        (12, 'Выезд разрешён.', 'РАЗРЕШЕНИЕ на выезд из города', DATE '2026-11-20', DATE '2026-11-27'),
        (13, 'Предупреждение снято.', NULL, NULL, NULL)
    ) AS v (id, conclusion, document, valid_from, valid_to)
    WHERE sr.id = v.id;

    -- отклонение (8 — с возвратом пошлины, 9 — без) и отмена жильцом (10)
    UPDATE service_request sr
    SET status = 'REJECTED', rejection_reason = v.reason, fee_refunded = v.refund,
        status_changed_by = 1, status_comment = v.reason
    FROM (VALUES (8, 'Справка для поликлиники выдаётся по запросу поликлиники.', TRUE),
                 (9, 'Талон на ноябрь уже выдан по месту работы.', FALSE)) AS v (id, reason, refund)
    WHERE sr.id = v.id;

    UPDATE service_request SET status = 'CANCELLED', fee_refunded = TRUE, status_comment = 'Отменена жильцом',
                               status_changed_by = (SELECT account_id FROM resident WHERE id = 18)
    WHERE id = 10;

    INSERT INTO balance_operation (resident_id, op_type, amount, request_id)
    SELECT resident_id, 'FEE_REFUND', fee_paid, id FROM service_request WHERE fee_refunded ORDER BY id;

    -- результат услуг: переселение Беловой (SV07) и снятие предупреждения Громова (SV09)
    UPDATE resident SET apartment_id = (SELECT id FROM apartment WHERE number = 27) WHERE id = 2;
    UPDATE punishment SET is_revoked = TRUE, revoked_by_request_id = 13 WHERE id = 10;
    INSERT INTO loyalty_change (resident_id, rule_code, request_id, comment)
    VALUES (1, 'RL07', 13, 'Снято предупреждение');

    INSERT INTO notification (account_id, message)
    SELECT r.account_id, format('Заявка № %s: статус %s', e.request_id, e.to_status)
    FROM request_event e
    JOIN service_request sr ON sr.id = e.request_id
    JOIN resident r ON r.id = sr.resident_id
    WHERE e.from_status IS NOT NULL AND r.account_id IS NOT NULL
    ORDER BY e.id;

    -- ------------------------------------------------- досье (UC16)
    INSERT INTO dossier_note (resident_id, author_id, text) VALUES
        ( 1, 1, 'Надёжный информатор. Сведения, как правило, подтверждаются.'),
        ( 7, 1, 'Имеет доступ к подвалу. Проверять содержимое подсобки.'),
        ( 9, 1, 'Часто выезжает за пределы района на служебной машине.'),
        ( 3, 1, 'Подал ложный донос на соседку. Достоверность сведений низкая.'),
        (16, 1, 'Поступил донос о выносе продуктов, на рассмотрении.');

    -- ------------------------------------------------- уведомления об изменении ИЛ; часть прочитана
    INSERT INTO notification (account_id, message)
    SELECT r.account_id, format('Индекс лояльности изменён на %s: %s', lc.delta_applied, lr.description)
    FROM loyalty_change lc
    JOIN loyalty_rule lr ON lr.code = lc.rule_code
    JOIN resident r ON r.id = lc.resident_id
    WHERE lc.delta_applied <> 0 AND r.account_id IS NOT NULL
    ORDER BY lc.id;

    UPDATE notification SET is_read = TRUE WHERE id % 3 = 0;
END;
$$;

COMMIT;
