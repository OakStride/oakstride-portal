-- Migration 34: databasen kräver samma kontrollsumma som avtalet lovar
--
-- ⚠️ DEN HÄR FILEN ÄNDRAR DRIFT MED FLIT. Den lägger en check-constraint på
-- `agreement_acceptances.document_hash`, alltså en spärr som avvisar en skrivning som
-- inte är en SHA-256-hex.
--
-- VARFÖR
-- ======
-- Fredriks beslut 2026-09-06, kort k-20260906-01, ordagrant: *"Blockera godkännandet om
-- kontrollsumman inte kan beräknas"*. Beslutet är verkställt i portalens klientkod
-- (PR #69) — men granskningen satte fingret på var det verkställandet slutar:
--
--   Avtalets finstilta lovar kunden "en kontrollsumma (SHA-256) av villkorstexten".
--   Efter PR #69 upprätthålls det löftet UTESLUTANDE av samma webbläsare som avtalet
--   själv erkänner kan misslyckas. `document_hash` är `text not null` utan formatkrav.
--
-- En check-constraint är det som gör beslutet verkställt i stället för avsett. Den gäller
-- oavsett väg in: portalens kod, ett direkt PostgREST-anrop, eller admin-policyn
-- `acceptances: admin skapar` (som finns i databasen men inte har någon kod i app.js).
--
-- ⛔ VAD SOM INTE LIGGER HÄR
--   * Ingen ändring av villkorstexten. Den ägs av `buildAgreement` i app.js, och regel 4
--     säger att den ändras bara där och bara av Fredrik.
--   * Ingen larmväg för blockerade godkännanden. Kunden får beskedet i gränssnittet;
--     OakStride får inget. Att bygga en serverside-kanal är ett eget beslut — Fredrik sa
--     2026-09-06 om en annan kanal: "bygg ingen ny kanal".
--   * Ingen städning av gamla rader. Det behövs inte, se mätningen nedan.
--
-- FÖRE-KONTROLL, och varför den ser ut så här
-- ===========================================
-- En `alter table ... add constraint` mot befintliga rader antingen lyckas eller kastar
-- ett svårläst fel med tabellnamnet i. Vi mäter i stället FÖRST och avbryter med en
-- mening som säger vad som är fel och vad man gör åt det.
--
-- Uppmätt i drift 2026-09-06 innan filen skrevs:
--   totalt 1 rad · riktig sha256 1 · ej sha256 0 · kortaste 64 · längsta 64

do $$
declare
  v_fel bigint;
  v_totalt bigint;
begin
  select count(*) filter (where document_hash !~ '^[0-9a-f]{64}$'), count(*)
    into v_fel, v_totalt
    from public.agreement_acceptances;

  if v_fel > 0 then
    raise exception 'migration 34 AVBRYTER: % av % rader i agreement_acceptances har ett document_hash som inte ar en SHA-256-hex. Constrainten skulle avvisa dem. Las raderna forst (select id, user_id, left(document_hash, 20) from public.agreement_acceptances where document_hash !~ ''^[0-9a-f]{64}$'') och avgor vad de ska bli - de ar godkannanden, inte skrap, och far inte raderas utan Fredriks ja.', v_fel, v_totalt;
  end if;

  raise notice 'migration 34: % rader kontrollerade, alla ar SHA-256-hex.', v_totalt;
end $$;

-- Själva ändringen. `not valid` används INTE: vi har just mätt att alla befintliga rader
-- håller, och en constraint som inte validerats ger ett falskt lugn - den ser ut som ett
-- skydd i katalogen medan gamla rader aldrig prövats mot den.
alter table public.agreement_acceptances
  drop constraint if exists agreement_acceptances_document_hash_sha256;

alter table public.agreement_acceptances
  add constraint agreement_acceptances_document_hash_sha256
  check (document_hash ~ '^[0-9a-f]{64}$');

comment on constraint agreement_acceptances_document_hash_sha256
  on public.agreement_acceptances is
  'Avtalet lovar kunden en SHA-256-kontrollsumma av villkorstexten. Constrainten gor det lofte till ett krav i databasen, inte bara i webblasaren. Fredriks beslut k-20260906-01 (2026-09-06).';

-- EFTER-KONTROLL. Katalogen är kvittot, inte att satsen ovan inte kastade.
do $$
declare
  v_finns boolean;
  v_giltig boolean;
begin
  select true, c.convalidated
    into v_finns, v_giltig
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'public'
     and t.relname = 'agreement_acceptances'
     and c.conname = 'agreement_acceptances_document_hash_sha256';

  if not coalesce(v_finns, false) then
    raise exception 'migration 34 AVBRYTER: constrainten finns inte i katalogen efter att den lagts till. Kor inte om utan att lasa pg_constraint for hand.';
  end if;
  if not coalesce(v_giltig, false) then
    raise exception 'migration 34 AVBRYTER: constrainten finns men ar INTE validerad. Da har den aldrig provats mot de befintliga raderna, och den ser ut som ett skydd utan att vara ett.';
  end if;

  raise notice 'migration 34: constrainten finns och ar validerad.';
end $$;
