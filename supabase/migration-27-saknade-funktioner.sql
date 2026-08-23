-- Migration 27: skriv ned det som fanns i produktion men saknades i repot
--
-- ⚠️ LÄS DETTA FÖRST: den här filen ÄNDRAR EN SAK I DRIFT, med flit.
-- Version 1 av filen påstod "ändrar ingenting i drift". Granskaren underkände den med fyra
-- blockerande fynd, och de var riktiga. Det här är omtaget. Se avsnitt 5 nedan för den enda
-- avsiktliga beteendeändringen: publiceringsloopen.
--
-- BAKGRUND
-- 2026-08-23 upptäcktes att `dispatch_publish_site` fanns i drift men saknade migrationsfil.
-- Version 1 kallade sig "en systematisk jämförelse av alla 31 funktioner" — och det var precis
-- vad den var: en revision av `pg_proc` och ingenting annat. Granskaren påpekade att driften
-- mellan repo och databas är mycket större. Det stämde. Uppmätt 2026-08-23:
--
--   SAKNADES I REPOT           FANNS I DRIFT
--   enum build_status          + publishing, publish_failed
--   build_jobs-kolumner        + published_at, live_url, dns_status, dns_instructions
--   trigger                    + build_jobs_publish_dispatch
--   funktioner                 + ai_usage_this_month, rls_auto_enable,
--                                dispatch_publish_site, request_publish_change
--
-- En återuppbyggnad från migrationerna hade alltså kraschat på första publiceringen
-- (`invalid input value for enum build_status`), saknat fyra kolumner som `publish-site.yml`
-- skriver till, och tappat det automatiska RLS-skyddet på nya tabeller.
--
-- ⚠️ TRANSAKTION: `kor-migrationer.yml` kör filen med `psql -1`, alltså i EN transaktion.
-- `alter type ... add value` är tillåtet i en transaktion från PG12, men det nya värdet får
-- inte *användas* i samma transaktion. Här används det inte — funktionerna nedan jämför mot
-- literalen först vid körning, inte vid definition. Mot dagens prod är enum-blocket ändå en
-- no-op, eftersom värdena redan finns.

-- ---------------------------------------------------------------------------
-- 1. Statusvärden som saknades i enumet
-- ---------------------------------------------------------------------------
alter type public.build_status add value if not exists 'publishing';
alter type public.build_status add value if not exists 'publish_failed';

-- ---------------------------------------------------------------------------
-- 2. Kolumner som publish-site.yml skriver till men som repot aldrig skapade
-- ---------------------------------------------------------------------------
alter table public.build_jobs add column if not exists published_at      timestamptz;
alter table public.build_jobs add column if not exists live_url          text;
alter table public.build_jobs add column if not exists dns_status        text;
alter table public.build_jobs add column if not exists dns_instructions  text;

-- ---------------------------------------------------------------------------
-- 3. ai_usage_this_month — förbrukningsmätaren som AVTALET hänvisar till
-- ---------------------------------------------------------------------------
-- Ordagrant ur drift (pg_get_functiondef 2026-08-23). Oförändrad.
CREATE OR REPLACE FUNCTION public.ai_usage_this_month()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_count int; v_cap int := 15;
begin
  select count(*) into v_count from agent_jobs aj
    join requests r on r.id = aj.request_id
    where r.user_id = auth.uid() and aj.created_at >= date_trunc('month', now());
  return json_build_object('used', v_count, 'cap', v_cap);
end $function$;

grant execute on function public.ai_usage_this_month() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. rls_auto_enable — slår på RLS automatiskt på varje ny tabell i public
-- ---------------------------------------------------------------------------
-- Ett SÄKERHETSSKYDD som ingen dokumenterat. En tabell utan RLS är läsbar för varje
-- inloggad kund. Ordagrant ur drift. Oförändrad.
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$;

-- Event-triggern. Version 1 kontrollerade BARA att namnet fanns — granskarens fynd 5.
-- Ett skydd vars enda kontroll är att ett namn förekommer i en katalog är dokumenterat,
-- inte verifierat. Nu kontrolleras att den pekar på rätt funktion, är påslagen, och har
-- rätt taggar. Avviker något HAVERERAR migrationen hellre än att rapportera framgång.
do $ens$
declare r record;
begin
  select e.evtfoid, e.evtenabled, e.evtevent, e.evttags into r
    from pg_event_trigger e where e.evtname = 'ensure_rls';

  if not found then
    create event trigger ensure_rls
      on ddl_command_end
      when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      execute function public.rls_auto_enable();
    raise notice 'Event-triggern ensure_rls skapad.';
    return;
  end if;

  if r.evtfoid <> 'public.rls_auto_enable'::regproc then
    raise exception 'Migration 27: event-triggern ensure_rls finns men pekar pa %, inte '
      'public.rls_auto_enable. RLS-skyddet ar da inte det vi tror. Reds ut for hand.',
      r.evtfoid::regproc;
  end if;
  if r.evtenabled = 'D' then
    raise exception 'Migration 27: event-triggern ensure_rls finns men ar AVSTANGD. Nya '
      'tabeller far da ingen RLS. Sla pa den med: alter event trigger ensure_rls enable;';
  end if;
  if not ('CREATE TABLE' = any(r.evttags)) then
    raise exception 'Migration 27: event-triggern ensure_rls taggar inte CREATE TABLE. '
      'Taggar: %. Skyddet galler da inte vanliga tabellskapanden.', r.evttags;
  end if;

  raise notice 'Event-triggern ensure_rls finns, pekar ratt, ar paslagen och taggar CREATE TABLE.';
end
$ens$;

-- ---------------------------------------------------------------------------
-- 5. dispatch_publish_site — HÄR ÄR DEN ENDA AVSIKTLIGA BETEENDEÄNDRINGEN
-- ---------------------------------------------------------------------------
-- 🔴 PUBLICERINGSLOOP, observerad i drift 2026-08-23 kl 12:56.
--
-- Sex publiceringskörningar avfyrades på nittio sekunder, ~11 sekunder isär, och fortsatte
-- köa nya tills byggjobbet raderades. Mekaniken:
--
--   publish-site.yml sätter status = 'publishing' i sitt forsta steg
--   publish-site.yml satter status = 'published' nar den ar klar
--   nasta koade korning satter 'publishing' igen -> old = 'published', ny = 'publishing'
--   -> triggern ser en ny overgang och avfyrar ANNU en publicering -> loop
--
-- Det gamla villkoret (`old.status is not distinct from 'publishing'`) skyddar bara mot att
-- samma körning fyrar två gånger. Det skyddar inte mot kedjan ovan.
--
-- FIXEN: dispatcha bara från de statusar portalen faktiskt tillåter publicering från.
-- `app.js` har regeln redan: canPublish kräver status i
-- (preview_ready, changes_requested, approved, publish_failed) — `published` finns INTE med.
-- Triggern speglar nu samma mängd, så databasen och gränssnittet säger samma sak.
--
-- Konsekvens att vara medveten om: en publicering som startas manuellt via workflow_dispatch
-- mot ett redan publicerat jobb dispatchar inte längre vidare. Det är avsikten — den körningen
-- är redan igång, den behöver ingen ny.
CREATE OR REPLACE FUNCTION public.dispatch_publish_site()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare pat text;
begin
  -- Endast vid övergång TILL 'publishing'...
  if new.status <> 'publishing' or old.status is not distinct from 'publishing' then
    return new;
  end if;
  -- ...och bara FRÅN en status portalen tillåter publicering från. Utan detta villkor
  -- loopar publiceringen: workflowet sätter 'published', nästa körning sätter 'publishing',
  -- triggern ser en ny övergång, och kedjan går runt. Observerad i drift 2026-08-23.
  if old.status not in ('preview_ready', 'changes_requested', 'approved', 'publish_failed') then
    raise log 'dispatch_publish_site: hoppar over % -> publishing (ingen giltig utgangsstatus)', old.status;
    return new;
  end if;

  select decrypted_secret into pat from vault.decrypted_secrets where name = 'github_pat';
  if pat is null then return new; end if;
  begin
    perform net.http_post(
      url := 'https://api.github.com/repos/OakStride/oakstride-agent/dispatches',
      body := jsonb_build_object(
        'event_type', 'publish-site',
        'client_payload', jsonb_build_object('job_id', new.id)
      ),
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || pat,
        'Accept', 'application/vnd.github+json',
        'Content-Type', 'application/json',
        'User-Agent', 'oakstride-portal'
      )
    );
  exception when others then null;
  end;
  return new;
end; $function$;

-- Triggern som band funktionen till tabellen saknades helt i repot — granskarens fynd 1.
-- Varje annan dispatch-funktion levereras med sin `create trigger` i samma fil; den här
-- gjorde det inte, så en återuppbyggnad hade gett en funktion som aldrig anropades.
-- Namnet är hämtat ur drift: build_jobs_publish_dispatch.
drop trigger if exists build_jobs_publish_dispatch on public.build_jobs;
create trigger build_jobs_publish_dispatch
  after update of status on public.build_jobs
  for each row execute function public.dispatch_publish_site();

-- ---------------------------------------------------------------------------
-- 6. request_publish_change — kundens "publicera min ändring"
-- ---------------------------------------------------------------------------
-- Ordagrant ur drift. Oförändrad. Bär hela behörighetskontrollen för direktpublicering.
CREATE OR REPLACE FUNCTION public.request_publish_change(p_request_id bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_owner uuid; v_is_admin boolean; v_status text; pat text;
begin
  select user_id, status into v_owner, v_status from requests where id = p_request_id;
  if v_owner is null then return json_build_object('ok', false, 'error', 'not_found'); end if;
  select coalesce(is_admin,false) into v_is_admin from profiles where id = auth.uid();
  if v_owner <> auth.uid() and not v_is_admin then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  if v_status <> 'draft_ready' then
    return json_build_object('ok', false, 'error', 'not_draft_ready');
  end if;
  select decrypted_secret into pat from vault.decrypted_secrets where name = 'github_pat';
  if pat is null then return json_build_object('ok', false, 'error', 'no_pat'); end if;
  begin
    perform net.http_post(
      url := 'https://api.github.com/repos/OakStride/oakstride-agent/dispatches',
      body := jsonb_build_object('event_type','publish-change',
                                 'client_payload', jsonb_build_object('request_id', p_request_id)),
      headers := jsonb_build_object('Authorization','Bearer '||pat,'Accept','application/vnd.github+json',
                                    'Content-Type','application/json','User-Agent','oakstride-portal')
    );
  exception when others then null; end;
  return json_build_object('ok', true);
end $function$;

-- Behörigheterna är SNÄVARE än standard i drift (varken PUBLIC eller anon) — uppmätt
-- 2026-08-23. Det ska bevaras, inte skrivas om. `create or replace` behåller befintliga
-- grants, men i en återuppbyggnad skulle funktionen få Postgres standard (EXECUTE till
-- PUBLIC). Därför skrivs det snäva läget ut explicit.
revoke execute on function public.request_publish_change(bigint) from public;
revoke execute on function public.request_publish_change(bigint) from anon;
grant  execute on function public.request_publish_change(bigint) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- VERIFIERING — version 1:s recept var TRASIGT (granskarens fynd 3)
-- ---------------------------------------------------------------------------
-- Det gamla receptet var `grep -r "function <namn>" supabase/*.sql`. Kört ordagrant
-- rapporterade det ALLA fyra funktionerna som saknade direkt efter att de lagts till:
-- grep är skiftlägeskänsligt och filen skriver `CREATE OR REPLACE FUNCTION public.x`.
-- Ett kontrollsteg som ljuger blir brus, och då fångar det inte ett äkta glapp heller.
--
-- Fungerande recept (kört och verifierat 2026-08-23):
--
--   for f in $(psql "$DB_URL" -t -A -c "select p.proname from pg_proc p
--       join pg_namespace n on n.oid=p.pronamespace
--      where n.nspname='public' and p.prokind='f' order by 1"); do
--     grep -rqiE "function +(public\.)?$f *\(" supabase/*.sql || echo "SAKNAS I REPOT: $f"
--   done
--
-- ⚠️ Funktioner är BARA en av fyra sorter. Kontrollera också:
--
--   enum:      select enumlabel from pg_enum e join pg_type t on t.oid=e.enumtypid
--               where t.typname='build_status' order by enumsortorder;
--   kolumner:  select column_name from information_schema.columns
--               where table_schema='public' and table_name='build_jobs';
--   triggers:  select tgname from pg_trigger where not tgisinternal;
--
-- Version 1 tittade bara på funktioner och kallade sig ändå systematisk. Gör inte om det.
