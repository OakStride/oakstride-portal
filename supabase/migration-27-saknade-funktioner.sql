-- Migration 27: skriv ned det som fanns i produktion men saknades i repot
--
-- ⚠️ LÄS DETTA FÖRST: den här filen ändrar INGENTING i drift — och den gången är det mätt.
--
-- Version 1 påstod samma sak utan belägg. Version 2 lade till en loopfix och kallade den
-- "den enda avsiktliga beteendeändringen". Granskaren underkände båda. Version 2 hade
-- dessutom TVÅ oavsiktliga ändringar som jag inte sett:
--   * triggern skrevs `after update OF STATUS` — drift har `after update` utan kolumnlista
--   * loopfixen fixade inte loopen (se nedan)
--
-- Uppmätt mot drift 2026-08-23 innan v3 skrevs:
--   pg_get_triggerdef('build_jobs_publish_dispatch') -> AFTER UPDATE ON public.build_jobs
--                                                       FOR EACH ROW EXECUTE FUNCTION
--                                                       dispatch_publish_site()
--   proowner for ALLA FYRA funktionerna -> postgres  (create or replace fungerar pa samtliga)
--   rolsuper(current_user)       -> FALSE     (create event trigger gar INTE)
--
-- 🔴 LOOPFIXEN LIGGER INTE HÄR, och min förklaring av loopen var FEL i v3. Rättad:
--
-- Jag skrev att triggern "inte kan skilja portalen från workflowet, båda skriver samma
-- värde". Det är osant, och granskaren fångade det. Funktionens FÖRSTA rad gör precis den
-- skillnaden: workflowets redundanta PATCH ger `old = new = 'publishing'`, och
-- `old.status is not distinct from 'publishing'` stoppar den. Samma körning kan inte fyra
-- två gånger.
--
-- Den VERKLIGA loopen är en annan: körning A avslutar och sätter `published`. Körning B —
-- redan köad — PATCH:ar `publishing`. Det ÄR en äkta övergång (`published → publishing`),
-- triggern dispatchar C, och kedjan går runt.
--
-- Varför det ändå inte fixas här: villkoret måste då utesluta `published` som utgångsstatus,
-- och v2 visade att varje sådan mängd läcker — `publish_failed` står med i portalens egen
-- `canPublish`, och workflowets felväg sätter just `publish_failed`. Fixen hör hemma där
-- den redundanta PATCH:en finns: i `publish-site.yml`, som egen PR.
--
-- ⚠️ RÖR INTE villkoret `old.status is not distinct from 'publishing'` i
-- `dispatch_publish_site` (sektion 5). Det är det som hindrar samma körning från att fyra
-- två gånger. Den felaktiga historien ovan hade kunnat användas för att motivera bort det.
--
--
-- ============================ KVITTO PA MATNINGEN ============================
-- Granskaren underkande v1, v2 och v3 delvis for att "ordagrant ur drift" var ett
-- pastaende utan bifogat belagg. Har ar belagget. Kor om det sjalv och jamfor.
--
--   select p.proname, p.proowner::regrole as owner,
--          md5(pg_get_functiondef(p.oid)) as md5,
--          coalesce(array_to_string(p.proacl::text[],' '),'NULL (PUBLIC har EXECUTE)') as proacl
--     from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--    where n.nspname='public' and p.proname in ('ai_usage_this_month','rls_auto_enable',
--          'dispatch_publish_site','request_publish_change') order by 1;
--
-- Utfall 2026-08-23 (efter att migration 26 kordes 12:00 - se nedan):
--   ai_usage_this_month     md5 ce9e0e33982bb9a8b1b3cc0f9c80df33  owner postgres
--                           proacl: =X postgres=X anon=X authenticated=X service_role=X
--   dispatch_publish_site   md5 77a3bc523635798ba379248cef459c32  owner postgres
--                           proacl: =X postgres=X anon=X authenticated=X service_role=X
--   request_publish_change  md5 19ba45353deef8a17c0af3b6e1ac9bca  owner postgres
--                           proacl: postgres=X authenticated=X service_role=X   <- INGET =X
--   rls_auto_enable         md5 6998ea6b4c2480f5d2e34b5dcf3f8d36  owner postgres
--                           proacl: =X postgres=X anon=X authenticated=X service_role=X
--
--   select tgname, tgenabled from pg_trigger
--    where tgrelid='public.build_jobs'::regclass and not tgisinternal order by 1;
--   Utfall 2026-08-23: samtliga FEM triggrar pa build_jobs har tgenabled = 'O'
--   (O = paslagen, sessionens default). Ingen ar manuellt avstangd.
--
--   select evtname, evtenabled, evtevent, evttags
--     from pg_event_trigger where evtname='ensure_rls';
--   Utfall 2026-08-23: evtenabled 'O', evtevent 'ddl_command_end',
--   evttags = {CREATE TABLE, CREATE TABLE AS, SELECT INTO}  (alla tre)
--
-- ⚠️ TIDSORDNINGEN SPELAR ROLL, och granskaren hade ratt att fraga.
-- Bada dispatch-funktionerna innehaller URL:en OakStride/oakstride-agent. Det vardet satte
-- MIGRATION 26 i drift. Avlasningen ovan gjordes DAREFTER - matt i samma fraga:
--   (pg_get_functiondef like '%OakStride/oakstride-agent%') -> true for bada.
-- Filen aterger alltsa driften som den ser ut EFTER 26, inte fore. Den gor inte 26:s jobb.
--
-- ⚠️ VAD SOM INTE AR MATT: policies (pg_policies) och index. Filen gor darfor INGET
-- fullstandighetsansprak pa dem. Rubriken galler funktioner, enum, kolumner, trigger och
-- grants - inget mer. Granskarens fynd 6.
-- ============================================================================
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
-- Servern är uppmätt PG 17.6 (2026-08-23). `alter type ... add value` är därmed
-- tillåtet i en transaktion (gäller från PG12), men det nya värdet får
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

-- ⚠️ INGEN revoke har, till skillnad fran request_publish_change nedan - och det ar matt,
-- inte slarv. Driftens proacl innehaller `=X` (PUBLIC har EXECUTE). En revoke hade alltsa
-- ANDRAT drift, vilket den har filen inte ska gora. Granskarens fynd 4 utgar darmed, men
-- konsekvensen ska sta utskriven: i en ateruppbyggnad far anon EXECUTE pa en SECURITY
-- DEFINER-funktion. Den grenar pa auth.uid() och ger anon {used:0, cap:15} - ofarligt, men
-- det ar ett medvetet accepterat lage och inte en lucka.
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
-- rätt taggar. Avviker något LARMAR vakten med `raise warning` och låter filen gå
-- igenom - skälet står i vaktens egen kommentar nedan. Den HAVERERAR alltså INTE
-- (ändrat från v3).
-- Mot drift 2026-08-23 tar vakten ELSE-grenen: alla fyra kontrollerna passerar. Varje
-- warning i loggen ar darfor en FORANDRING sedan dess, inte ett kant lage.
do $ens$
declare r record;
begin
  select e.evtfoid, e.evtenabled, e.evtevent, e.evttags into r
    from pg_event_trigger e where e.evtname = 'ensure_rls';

  -- ⚠️ VARNING, INTE EXCEPTION - och det ar ett medvetet byte fran v3.
  -- kor-migrationer.yml kor filen med `psql -1`. Ett raise exception NAGONSTANS i filen
  -- sanker da HELA filen, inklusive enum, kolumner, funktioner och triggerbindningen -
  -- alltsa precis det den finns till for. I en ateruppbyggnad, dar ensure_rls inte finns,
  -- hade v3 darfor blivit ett permanent stopp: migrationen kunde aldrig appliceras, och
  -- tillstandet gick inte att laga inifran (rolsuper = false, matt).
  -- Darfor larmar vakten hogljutt och later filen ga igenom. En hard assertion hor hemma i
  -- en EGEN kontroll utanfor migrationskedjan, inte i en fil som maste appliceras.
  if not found then
    raise warning E'ensure_rls SAKNAS. Nya tabeller i public far INGEN RLS och ar da lasbara
'
      'for varje inloggad kund. Den kan inte skapas harifran - det kraver superuser.
'
      'Kor detta i Supabases SQL-editor:
'
      '  create event trigger ensure_rls on ddl_command_end
'
      '    when tag in (''CREATE TABLE'', ''CREATE TABLE AS'', ''SELECT INTO'')
'
      '    execute function public.rls_auto_enable();';
    return;
  end if;

  if r.evtfoid <> 'public.rls_auto_enable'::regproc then
    raise warning 'ensure_rls pekar pa %, inte public.rls_auto_enable. RLS-skyddet ar inte det vi tror.',
      r.evtfoid::regproc;
  elsif r.evtenabled in ('D', 'R') then   -- D = disabled, R = replica (fyrar inte pa primaren)
    raise warning 'ensure_rls ar AVSTANGD (%). Sla pa: alter event trigger ensure_rls enable;', r.evtenabled;
  elsif r.evtevent <> 'ddl_command_end' then
    -- v3 hamtade evtevent men ANVANDE det aldrig. En trigger pa fel event passerade da
    -- alla kontroller och fyrade anda aldrig. Granskarens fynd 5.
    raise warning 'ensure_rls ligger pa event %, inte ddl_command_end. Den fyrar aldrig pa CREATE TABLE.',
      r.evtevent;
  elsif r.evttags is not null and not ('CREATE TABLE' = any(r.evttags)) then
    -- evttags NULL = ingen taggfiltrering = fyrar pa allt, vilket ar ratt. Utan det
    -- explicita null-testet vilar det pa att NULL i en if-sats beter sig som falskt -
    -- ratt utfall av fel skal, och nasta person "fixar" det med coalesce och far falsklarm.
    raise warning 'ensure_rls taggar inte CREATE TABLE (taggar: %).', r.evttags;
  else
    raise notice 'ensure_rls: finns, pekar ratt, paslagen, ratt event, taggar CREATE TABLE.';
  end if;
end
$ens$;

-- ---------------------------------------------------------------------------
-- 5. dispatch_publish_site — startar go-live nar status blir 'publishing'
-- ---------------------------------------------------------------------------
-- Ordagrant ur drift (pg_get_functiondef 2026-08-23). OFORANDRAD.
--
-- ⚠️ TIDSBEGRANSAD. Fredrik beslutade 2026-08-24 att publiceringen gar via en RPC
-- fran portalen och att triggern `build_jobs_publish_dispatch` TAS BORT i migration
-- 28. Den har sektionen dokumenterar driften som den sag ut 2026-08-23; den beskriver
-- INTE hur publicering fungerar efter att 28 kort. Loopen upphor med triggern.
--
-- 🔴 Den observerade publiceringsloopen fixas INTE har.
-- Funktionens forsta rad skiljer redan avsandarna at: workflowets redundanta PATCH
-- ger `old = new = 'publishing'` och stoppas av det andra ledet i villkoret nedan.
-- Samma korning kan alltsa inte fyra tva ganger. Den verkliga loopen ar NASTA
-- kornings `published -> publishing`, vilket ar en akta overgang. Den fixas inte i
-- DB-lagret.
-- ⚠️ TA INTE BORT villkoret nedan. Motiveringen "villkoret kan anda inte skilja
-- portalen fran workflowet, bada skriver samma varde" stod har till 2026-08-23
-- och ar MATT FALSK.
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
-- ⚠️ `pg_get_triggerdef` visar INTE `tgenabled`. Ett drop+create satter alltid
-- tillbaka 'O'. Matt 2026-08-23: alla fem triggrar pa build_jobs star pa 'O', sa
-- aterskapandet ar en no-op. MEN: har nagon slagit AV triggern som akutatgard mot
-- publiceringsloopen efter den matningen, sla PA den igen ar precis vad den har
-- filen gor. Kontrollera tgenabled omedelbart fore korning, inte bara vid
-- granskningen.
-- ⚠️ `drop trigger` + `create trigger` tar ACCESS EXCLUSIVE-las pa build_jobs, och med
-- `psql -1` halls laset till commit. Kors migrationen medan ett bygge eller en publicering
-- ar i luften blockeras workflowets PATCH:ar, och PostgREST:s statement timeout kan gora
-- det till ett byggfel utan uppenbar orsak. Kor nar inget jobb ar igang. Granskarens fynd 7.
-- 🔴 VAKT (tillagd 2026-08-25). Ateskapa INTE triggern om migration 28 redan kort.
--
-- Migration 28 slapper den har triggern med flit (Fredriks beslut 2026-08-24). Kors 28
-- forst och 27 darefter - fullt mojligt, eftersom kor-migrationer.yml bara garanterar
-- nummerordning INOM en korning och de tva ligger i olika PR:er - da vore motorn
-- tillbaka i drift OVANPA den nya RPC-vagen. Varje publicering hade gett tva
-- dispatchar, och loopen fran 2026-08-23 vore ateruppvackt.
--
-- Vakten kanner igen 28 pa att `request_publish_site` finns. Den ar skyddsnatet, inte
-- planen: ratt ordning ar 27 fore 28. Funktionen ovan aterskapas daremot alltid - utan
-- trigger ar den inert, och filens uppgift ar att dokumentera vad som fanns i drift.
do $vakt$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'request_publish_site') then
    raise warning 'Migration 28 ar redan kord (request_publish_site finns). Triggern build_jobs_publish_dispatch ateskapas INTE - den ar avsiktligt borttagen. Detta ar ratt beteende, inte ett fel.';
  else
    drop trigger if exists build_jobs_publish_dispatch on public.build_jobs;
    create trigger build_jobs_publish_dispatch
      after update on public.build_jobs
      for each row execute function public.dispatch_publish_site();
  end if;
end
$vakt$;

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
-- Matt: driftens proacl saknar `=X` helt, alltsa har PUBLIC redan INGEN EXECUTE. Revoken
-- nedan ar darfor en NO-OP mot dagens drift och far betydelse forst vid en ateruppbyggnad,
-- dar Postgres standard annars ger PUBLIC EXECUTE.
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
--     grep -rqiE "(create or replace|create) +function +(public\.)?$f *\(" supabase/*.sql || echo "SAKNAS I REPOT: $f"
--   done
--
-- ⚠️ Funktioner är BARA en av fyra sorter. Kontrollera också:
--
--   enum:      select enumlabel from pg_enum e join pg_type t on t.oid=e.enumtypid
--               where t.typname='build_status' order by enumsortorder;
--   kolumner:  select column_name from information_schema.columns
--               where table_schema='public' and table_name='build_jobs';
--   triggers:  select tgname, tgenabled, pg_get_triggerdef(oid) from pg_trigger
--               where not tgisinternal;
--   grants:    select proname, proacl from pg_proc p join pg_namespace n
--               on n.oid=p.pronamespace where n.nspname='public';
--   policies:  select tablename, policyname from pg_policies where schemaname='public';
--
-- Och matcha pa SIGNATUR, inte bara namn: repot har request_ai_draft(bigint, text),
-- men en aldre overlagring kan ligga kvar i drift utan att synas i namnjamforelsen.
--
-- Version 1 tittade bara på funktioner och kallade sig ändå systematisk. Gör inte om det.
--
-- ⚠️ KVITTOT I FILHUVUDET BEVISAR ATT DRIFTEN INTE ÄNDRATS — INTE ATT FILEN
--   ÅTERGER DEN. Kvittot sparar md5, inte definitionstexten. Avviker en av filens
--   fyra kroppar fran drift skriver `create or replace` over drift TYST, och
--   originalet gar inte att aterstalla ur ett md5.
--   Efterkontroll som faktiskt bevisar att FILEN aterger driften: kor
--   frisksedelsfragan i huvudet EN gang till EFTER att migrationen kort. Samma
--   fyra md5 = filens kroppar ar identiska med drift och ingenting skrevs over.
--   Avvikande md5 = filen andrade drift.
