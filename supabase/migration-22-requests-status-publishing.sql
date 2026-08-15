-- Migration 22 (2026-08-15): BUGFIX "Lansera direkt" — requests.status tillät inte
-- 'publishing'/'published'. publish-change.yml PATCH:ar status=publishing → CHECK-fel (400)
-- → curl exit 22 → körningen föll redan i steg 1 (hittat vid E2E-test 2026-08-15, ärende #8).
-- Portalens UI (app.js) och notify_email hanterar redan båda värdena.
alter table public.requests drop constraint if exists requests_status_check;
alter table public.requests add constraint requests_status_check
  check (status = any (array['new','in_progress','questions','draft_ready','approved',
                             'waiting_customer','done','publishing','published']));
