-- Migration 27: fyra funktioner som fanns i produktion men INTE i repot
--
-- BAKGRUND
-- Upptäckt 2026-08-23 när migration 26 skrevs: `dispatch_publish_site` och
-- `request_publish_change` fanns i den driftsatta databasen men saknade migrationsfil.
-- En systematisk jämförelse av alla 31 funktioner i `public` mot repots migrationer gav
-- fyra, inte två. De hade alltså skapats direkt i SQL-editorn och aldrig skrivits ned.
--
-- VARFÖR DET SPELAR ROLL
-- Repot beskrev inte databasen. En återuppbyggnad från migrationerna hade gett en portal
-- utan förbrukningsmätare, utan två av fyra dispatch-vägar, och — allvarligast — utan det
-- automatiska RLS-skyddet på nya tabeller. Ingenting hade kraschat. Det hade bara saknats.
--
-- Den här filen ändrar INGENTING i drift. Den skriver ned det som redan körs, ordagrant
-- läst med `pg_get_functiondef`, så att repot och databasen säger samma sak. Alla fyra är
-- `create or replace` med exakt nuvarande innehåll och är därför ofarliga att köra.
--
-- ⚠️ INGA HEMLIGHETER I KODEN. Kontrollerat före incheckning: dispatch-funktionerna hämtar
-- sin GitHub-PAT ur `vault.decrypted_secrets` (namn `github_pat`) vid varje anrop. Ingen
-- nyckel står i klartext någonstans i definitionerna.
--
-- 🔴 EN SAK SOM INTE ÄR EN BUGG HÄR MEN SOM MÅSTE BLI ETT EGET ÄRENDE:
-- Båda dispatch-funktionerna avslutar sitt http-anrop med `exception when others then null`.
-- De sväljer alltså VARJE fel, tyst. I kombination med att `pg_net` är fire-and-forget finns
-- det ingen väg alls för ett misslyckat bygge att göra sig hört. Det var precis den risken
-- org-flytten aktualiserade (301 på flyttad repo-sökväg). Adressen är lagad i migration 26 —
-- tystnaden är det inte. Rör den inte här; en ändring av felhanteringen ska granskas för sig.

-- ---------------------------------------------------------------------------
-- 1. ai_usage_this_month — förbrukningsmätaren som avtalet hänvisar till
-- ---------------------------------------------------------------------------
-- Avtalets AI-tak (15 ändringar/mån) visas i portalen via den här RPC:n. Den saknades helt
-- i repot trots att den är kommersiellt bindande — se kunskap-avtal-villkor.md.
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

-- ---------------------------------------------------------------------------
-- 2. rls_auto_enable — slår på RLS automatiskt på varje ny tabell i public
-- ---------------------------------------------------------------------------
-- Detta är ett SÄKERHETSSKYDD som ingen dokumenterat. Utan det får en ny tabell ingen RLS,
-- och en tabell utan RLS är läsbar för varje inloggad kund. Att den saknades i repot är
-- det allvarligaste i den här migrationen: en återuppbyggnad hade tyst tappat skyddet.
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

-- Själva event-triggern saknades också. Utan den är funktionen ovan bara död kod.
-- Verifierad i drift 2026-08-23: heter `ensure_rls`, är påslagen, taggar CREATE TABLE /
-- CREATE TABLE AS / SELECT INTO.
do $ens$
begin
  if not exists (select 1 from pg_event_trigger where evtname = 'ensure_rls') then
    create event trigger ensure_rls
      on ddl_command_end
      when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      execute function public.rls_auto_enable();
    raise notice 'Event-triggern ensure_rls skapad.';
  else
    raise notice 'Event-triggern ensure_rls fanns redan - lamnad orord.';
  end if;
end
$ens$;

-- ---------------------------------------------------------------------------
-- 3. dispatch_publish_site — startar go-live när status blir 'publishing'
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dispatch_publish_site()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare pat text;
begin
  -- Endast vid övergång TILL 'publishing'
  if new.status <> 'publishing' or old.status is not distinct from 'publishing' then
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

-- ---------------------------------------------------------------------------
-- 4. request_publish_change — kundens "publicera min ändring", med behörighetskoll
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- VERIFIERING efter körning — ska ge 0 rader
-- ---------------------------------------------------------------------------
--   Jämför alla funktioner i public mot repots migrationsfiler. Allt som listas saknas
--   i repot och ska då skrivas ned på samma sätt som här.
--
--   select p.proname
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.prokind = 'f'
--    order by p.proname;
--
--   Kör listan mot `grep -r "function <namn>" supabase/*.sql`. Gör om kontrollen med jämna
--   mellanrum — den här migrationen stänger luckan i dag, inte i morgon.
