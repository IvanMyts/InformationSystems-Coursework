-- =====================================================================
-- ИС «Бдительность». Этап 2.
-- 00_drop.sql — удаление всех объектов базы.
-- Триггеры, индексы и ограничения удаляются вместе с таблицами.
-- =====================================================================

BEGIN;

DROP VIEW IF EXISTS v_apartment_occupancy, v_loyalty_history, v_denunciation_for_manager;

DROP TABLE IF EXISTS notification, dossier_note, loyalty_change, loyalty_rule,
    balance_operation, rent_charge, payment, punishment_basis, punishment,
    denunciation, request_event, service_request, service, invitation,
    resident, apartment, account;

DROP FUNCTION IF EXISTS
    activate_account(CHAR, VARCHAR, VARCHAR),
    apply_payment_status(VARCHAR, payment_status),
    pay_rent(INTEGER, INTEGER),
    accrue_rent(DATE),
    register_overdue_rent(DATE),
    request_queue(),
    resident_dossier(INTEGER),
    trg_forbid_modification(),
    trg_balance_operation_apply(),
    trg_loyalty_change_apply(),
    trg_resident_guard(),
    trg_request_status(),
    trg_request_history(),
    trg_denunciation_status(),
    trg_punishment_basis_check();

DROP TYPE IF EXISTS balance_op_type, rent_status, payment_status, punishment_type,
    denunciation_status, request_status, service_result_kind, resident_status, account_role;

COMMIT;
