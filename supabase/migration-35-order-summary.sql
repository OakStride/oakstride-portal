-- Migration 35: agreement_acceptances.order_summary skrivs ned i repot
--
-- Dokumentation, inte en beteendeandring i drift. Samma sort som 29, 32 och 33:
-- kolumnen FINNS i produktion, den saknas bara i repot.
--
-- ⚠️ FILEN SKA VARA EN NO-OP MOT PRODUKTION. Den enda villkorslosa satsen ar
-- `set client_encoding`. Sjalva tillagget ar `add column if not exists`, och en vakt
-- efterat sager till om den faktiskt gjorde nagot.
--
-- ============================ HUR GLAPPET HITTADES ============================
-- Provet 2026-09-09 (Fredriks kort k-20260906-05, "kor provet lokalt"): hela repot
-- byggdes till en databas i PGlite och jamfordes mot drift. Funktioner, policies och
-- triggers var IDENTISKA - 114 objekt, samma md5. Kolumnerna var det inte:
--
--   drift  151 kolumner i public (utan applied_migrations)
--   repot  150
--   skillnaden: agreement_acceptances.order_summary
--
-- Tidigare kartlaggningar missade den for att de jamforde OBJEKT, aldrig kolumner.
-- Ratt kontroll fanns, men inte pa den niva dar felet satt.
--
-- ============================ VARFOR DET SPELAR ROLL ============================
-- Kolumnen ar inte oanvand. Tva stallen rakar ut for den:
--
--   portal/app.js:2001 och :2048
--     skriver order_summary vid VARJE avtalsgodkannande.
--   supabase/migration-23-notify-published-email.sql:83 och :90
--     laser new.order_summary i aviseringstriggern.
--
-- I en ateruppbyggnad ur repot hade alltsa avtalsgodkannandet fallit pa en okand
-- kolumn, och aviseringen med den. Det ar agreement_acceptances - tabellen som bar
-- beviset for att kunden godkant avtalet. Se studio/minne/kunskap-avtal-villkor.md.
--
-- ============================ KVITTO PA MATNINGEN ============================
-- Mot drift (wtekqlkkcomtgizjtqeo) 2026-09-09. Kor om och jamfor:
--
--   select column_name, data_type, is_nullable, column_default
--     from information_schema.columns
--    where table_schema='public' and table_name='agreement_acceptances'
--    order by ordinal_position;
--
-- Gav nio rader, den nionde:
--   order_summary | text | YES | (inget default)
--
-- Och:
--   select count(*) from applied_migrations;   -> 28
-- alltsa exakt de 28 filer som ligger i repot. Kolumnen kom in FOR HAND, utanfor
-- migrationskedjan. Den har filen ar det som gor kedjan hel igen.
--
-- ⚠️ Ingen `not null`, inget default - med flit. Sa ser den ut i drift, och en
-- `not null` hade dessutom fallit pa befintliga rader. Skriv inte om den till nagot
-- "snyggare" an det som faktiskt korr.

set client_encoding to 'UTF8';

alter table public.agreement_acceptances
  add column if not exists order_summary text;

-- Vakt. I drift ska den ha funnits innan; i en ateruppbyggnad ar det vantat att den
-- skapades nu. Bada lagen ar giltiga - det ar DARFOR den sager vilket det var, i
-- stallet for att tiga. kor-migrationer.yml lyfter warning till en annotering.
do $$
declare
  v_finns boolean;
begin
  select exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name   = 'agreement_acceptances'
       and column_name  = 'order_summary'
  ) into v_finns;

  if not v_finns then
    -- Kan bara intraffa om `add column` ovan tystnade, vilket den inte kan. Star har
    -- anda: en vakt som bara kontrollerar det forvantade larmar aldrig om det ovantade.
    raise exception 'migration 35: order_summary saknas EFTER add column. Nagot har stoppat satsen.';
  end if;

  -- Sag ocksa nagot om typen. En kolumn som finns men ar t.ex. jsonb ar inte samma
  -- kolumn, och `add column if not exists` hade da tigit och latit den vara.
  perform 1 from information_schema.columns
   where table_schema='public' and table_name='agreement_acceptances'
     and column_name='order_summary' and data_type='text';
  if not found then
    raise warning 'migration 35: order_summary finns men ar INTE text. Repot och drift beskriver da olika kolumner.';
  else
    raise notice 'migration 35: order_summary finns och ar text.';
  end if;
end $$;
