-- Migration 28: publiceringen går via RPC, statustriggern tas bort
--
-- Fredriks beslut 2026-08-24 11:34, ordagrant:
--   "Bygg om publiceringen så portalen anropar en RPC, som request_publish_change.
--    Statustriggern tas bort."
--
-- Valet stod mellan (A) en markörkolumn `publish_source` och (B) den här vägen. B valdes.
--
-- ============================ VARFÖR ============================
--
-- `build_jobs.status = 'publishing'` var inte en etikett utan ett LÅS MED TRE LÄSARE:
--   1. portalens knappspärr (app.js `canPublish` — knappen försvinner medan det publiceras)
--   2. lägestexten "Publicerar… (GitHub Pages + DNS)" (app.js)
--   3. städverktygets raderingsspärr (agent/.github/workflows/stada-testdata.yml)
-- ...OCH SAMTIDIGT motorn: triggern `build_jobs_publish_dispatch` dispatchade på övergången.
--
-- Den dubbla rollen är hela felet. Loopen 2026-08-23 12:56 (sex körningar på nittio
-- sekunder) gick: körning A sätter `published` -> körning B, redan köad, PATCH:ar
-- `publishing` -> äkta övergång -> triggern dispatchar C -> och runt igen.
--
-- Efter den här migrationen är `status` REN PRESENTATION. Ingenting mekaniskt hänger på den,
-- de tre läsarna fungerar precis som förut, och det som startar en publicering är ett
-- uttryckligt anrop — inte en sidoeffekt av ett tabellskriv.
--
-- ============================ ORDNING — LÄS DETTA ============================
--
-- 🔴 MIGRATION 27 MÅSTE KÖRAS FÖRE DEN HÄR. Skälet är INTE att repohistoriken blir prydlig.
--
-- Migration 27 gör ovillkorligt `create or replace function dispatch_publish_site()` +
-- `create trigger build_jobs_publish_dispatch`. Körs 28 först och 27 därefter — vilket är
-- fullt möjligt, eftersom `kor-migrationer.yml` bara garanterar nummerordning INOM en
-- körning och 27 ligger i en egen omergad PR — då är motorn TILLBAKA i drift samtidigt som
-- portalen anropar RPC:n. Varje publicering ger då två dispatchar, och loopen är återuppväckt.
--
-- Migration 27 har därför fått en vakt som vägrar återskapa triggern om den här filen redan
-- körts (den kontrollerar om `request_publish_site` finns). Vakten är skyddsnätet, inte
-- planen: kör 27 först ändå.
--
-- Beroendet åt andra hållet är också hårt: enumvärdena 'publishing' och 'publish_failed'
-- skapas i repot BARA av migration 27. Utan den kraschar RPC:n nedan på första anropet.
--
-- ⚠️ `drop trigger` tar ACCESS EXCLUSIVE-lås på build_jobs. Kör när inget bygge och ingen
-- publicering är i luften. Uppmätt 2026-08-25: `build_jobs` är tom, noll rader.

-- ---------------------------------------------------------------------------
-- 1. Ny RPC — admin startar go-live
-- ---------------------------------------------------------------------------
create or replace function public.request_publish_site(p_job_id uuid, p_domain text)
 returns json
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_is_admin boolean;
  v_status   public.build_status;
  v_customer uuid;
  v_shared   timestamptz;
  v_domain   text;
  pat        text;
begin
  -- Behörighet. Motsvarar RLS-policyn "build_jobs: admin hanterar" (migration 16), som
  -- annars hade burit kontrollen när portalen skrev i tabellen direkt.
  select coalesce(is_admin, false) into v_is_admin from profiles where id = auth.uid();
  if not coalesce(v_is_admin, false) then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;

  -- Domänen normaliseras och valideras HÄR, inte bara i webbläsaren. Portalens egen
  -- kontroll finns kvar för snabb återkoppling, men den är kosmetisk: en RPC som litar på
  -- klienten skyddar ingenting. Har jobbet redan `brief.domain` satt skickar portalen
  -- dessutom vidare det värdet HELT OVALIDERAT — då är den här grinden den enda som finns.
  --
  -- Mönstret är medvetet IDENTISKT med publish-site.yml:148, inte lösare. Ett lösare
  -- mönster här släpper igenom `kund.123`, `kund.x` och `192.168.1.10` (uppmätt 2026-08-25),
  -- och de tar sig då förbi CNAME-skrivningen i kundens repo innan workflowet avbryter —
  -- kundens Pages-sajt står kvar med fel custom domain tills någon rättar den för hand.
  -- Skrivet med [.] i stället för bakstreck-punkt, så filen överlever varje väg den passerar.
  v_domain := lower(btrim(coalesce(p_domain, '')));
  v_domain := regexp_replace(v_domain, '^https?://', '');
  v_domain := regexp_replace(v_domain, '^www[.]', '');
  v_domain := regexp_replace(v_domain, '/.*$', '');
  v_domain := regexp_replace(v_domain, '[.]$', '');      -- avslutande punkt: giltig, normaliseras bort
  if v_domain !~ '^([a-z0-9]([a-z0-9-]*[a-z0-9])?[.])+[a-z]{2,}$' then
    return json_build_object('ok', false, 'error', 'bad_domain');
  end if;

  -- `for update` låser raden. Utan den kan två samtidiga anrop (två flikar, en dubbelklick
  -- som slinker förbi knappens disabled) båda läsa 'approved', båda passera grinden och
  -- båda dispatcha — två fullständiga publiceringar, inklusive två DNS-skrivningar.
  -- Att flytta grinden till databasen är meningslöst om den inte är atomisk.
  select status, customer_id, shared_at
    into v_status, v_customer, v_shared
    from build_jobs where id = p_job_id
     for update;
  if not found then
    return json_build_object('ok', false, 'error', 'not_found');
  end if;

  -- Samma två villkor som portalens `canPublish`: kunden ska vara kopplad och utkastet delat.
  if v_customer is null or v_shared is null then
    return json_build_object('ok', false, 'error', 'not_shared');
  end if;
  if v_status::text not in ('preview_ready', 'changes_requested', 'approved', 'publish_failed') then
    return json_build_object('ok', false, 'error', 'bad_status', 'status', v_status::text);
  end if;

  select decrypted_secret into pat from vault.decrypted_secrets where name = 'github_pat';
  if pat is null then
    return json_build_object('ok', false, 'error', 'no_pat');
  end if;

  -- Domänen in i briefen. publish-site.yml avbryter om brief.domain saknas.
  update build_jobs
     set brief  = coalesce(brief, '{}'::jsonb) || jsonb_build_object('domain', v_domain),
         status = 'publishing',
         error  = null
   where id = p_job_id;

  -- ⚠️ VAD DET HÄR BLOCKET FÅNGAR — OCH VAD DET INTE FÅNGAR.
  -- `net.http_post` i pg_net är ASYNKRON: anropet lägger en rad i net.http_request_queue,
  -- returnerar ett id och committar. Själva HTTP-anropet görs av en bakgrundsarbetare efter
  -- att transaktionen är klar.
  --   FÅNGAS:      att pg_net saknas, fel argumenttyper, rättighetsfel på schemat net.
  --   FÅNGAS INTE: HTTP 401 (PAT utgången eller fel format), 404 (fel ägare/repo),
  --                403 (rate limit, saknad scope), timeout, eller att arbetaren står still.
  -- I de fallen svarar RPC:n {"ok":true} medan ingenting startade, och svaret hamnar i
  -- net._http_response där ingen läser det. Det är därför `reset_publish_state` nedan finns:
  -- utan den kan ett jobb som fastnat på 'publishing' varken publiceras om (knappen är borta)
  -- eller raderas (städverktyget vägrar) — enda utvägen vore handskriven SQL mot produktion.
  --   Läget 2026-08-25: net._http_response innehåller 20 st 204 och 3 st 200. Noll fel
  --   hittills — men frånvaro av fel i historiken är inte ett skydd.
  begin
    perform net.http_post(
      url  := 'https://api.github.com/repos/OakStride/oakstride-agent/dispatches',
      body := jsonb_build_object(
        'event_type', 'publish-site',
        'client_payload', jsonb_build_object('job_id', p_job_id)
      ),
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || pat,
        'Accept', 'application/vnd.github+json',
        'Content-Type', 'application/json',
        'User-Agent', 'oakstride-portal'
      )
    );
  exception when others then
    -- Felkolumnen är KUNDLÄSBAR: migration 17 ger kunden select på hela raden när
    -- customer_id matchar och shared_at är satt — och RPC:n kräver just det. Rå Postgres-
    -- feltext (schemanamn, signaturer) hör inte hemma där. Detaljen går i svaret i stället,
    -- som bara den anropande adminen ser.
    update build_jobs
       set status = 'publish_failed',
           error  = 'Publiceringen kunde inte startas. Försök igen, eller kontakta OakStride.'
     where id = p_job_id;
    return json_build_object('ok', false, 'error', 'dispatch_failed', 'detail', sqlerrm);
  end;

  return json_build_object('ok', true, 'domain', v_domain);
end $function$;

-- Samma snäva behörighet som request_publish_change: varken PUBLIC eller anon.
-- Kontrollen inuti funktionen är admin-grinden; grant:en är bara ytterdörren.
-- OBS: `service_role` har ingen JWT-sub, så auth.uid() är null och anropet ger alltid
-- 'forbidden'. Grant:en är alltså inert — den står med för att spegla request_publish_change,
-- och den som senare vill låta agenten anropa RPC:n med servicenyckeln ska veta varför det
-- inte fungerar.
revoke execute on function public.request_publish_site(uuid, text) from public;
revoke execute on function public.request_publish_site(uuid, text) from anon;
grant  execute on function public.request_publish_site(uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Vägen ut ur ett fastnat 'publishing'
-- ---------------------------------------------------------------------------
-- Ett jobb kan fastna på 'publishing' utan att någon publicering pågår — se det långa
-- blocket ovan om vad pg_net inte rapporterar. I det läget är jobbet oåtkomligt för
-- ALLA verktyg som finns: knappen är borta (app.js canPublish saknar 'publishing'),
-- kortet visar "Publicerar…" för alltid, och stada-testdata.yml vägrar radera.
-- ⚠️ Funktionen ar admin-JWT-gatad och kan darfor BARA anropas fran portalen. I
-- SQL-editorn, via MCP eller fran psql ar auth.uid() null och svaret blir 'forbidden'.
-- Under fonstret "migration 28 kord -> portal-PR #40 mergad" finns alltsa ingen knapp
-- och ingen anropbar vag: ett jobb som fastnar dar kraver fortfarande handskriven SQL.
-- Hall fonstret kort.
-- Den här funktionen är utvägen, och den är avsiktligt trubbig: den flyttar jobbet till
-- publish_failed, vilket är ett läge portalen redan kan hantera (knappen kommer tillbaka
-- som "Försök publicera igen") och städverktyget redan får radera.
-- ⚠️ TIDSGRINDEN ÄR INTE ADMINISTRATIV. Utan den ar den har funktionen en ny vag till
-- dubbel publicering, och den utlöses av en knapp som är byggd för att tryckas i
-- osäkerhet:
--   1. korning A ar igang, jobbet star pa 'publishing' (fullt normalt i minuter:
--      git clone, Pages-certifikat, HostUp-zon, DNS)
--   2. admin blir otalig och trycker Aterstall -> publish_failed
--   3. 'publish_failed' star i portalens canPublish -> knappen kommer tillbaka som
--      "Forsok publicera igen"
--   4. admin trycker -> korning B dispatchas mot SAMMA kundrepo medan A skriver
--      CNAME och DNS. concurrency har cancel-in-progress: false, sa B koas och kor
--      klart - tva publiceringar, tva DNS-pass mot kundens zon.
--   5. samtidigt ar stadverktygets sparr avvapnad: den vagrar bara radera vid
--      'publishing'. Jobbet kan nu raderas mitt i As korning.
-- `for update` skyddar mot SAMTIDIGA anrop. Det kan inte skydda mot tva anrop i
-- foljd som en manniska sjalv slapper igenom. Darfor aldersgrinden nedan.
--
-- Signalen finns redan: `updated_at` underhalls av triggern build_jobs_touch
-- (migration 16) och satts av request_publish_site egen update. Portalen har samma
-- grind (RESET_EFTER_MIN i app.js) - de tva MASTE folja at, annars visar portalen en
-- knapp som databasen avvisar.
--
-- Skalet skrivs INTE till `error`. Kolumnen ar kundlasbar (samma resonemang som i
-- request_publish_site ovan), och en admin som skriver "kunden svarar inte, PAT:en
-- verkar utgangen" som skal hade publicerat det till kunden. Funktionen tar darfor
-- ingen fritext alls - texten ar fast och kundvand.
create or replace function public.reset_publish_state(p_job_id uuid)
 returns json
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_is_admin boolean;
  v_status   public.build_status;
  v_updated  timestamptz;
  v_alder    interval;
  c_min_alder constant interval := interval '10 minutes';
begin
  select coalesce(is_admin, false) into v_is_admin from profiles where id = auth.uid();
  if not coalesce(v_is_admin, false) then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;

  select status, updated_at into v_status, v_updated
    from build_jobs where id = p_job_id for update;
  if not found then
    return json_build_object('ok', false, 'error', 'not_found');
  end if;

  -- Bara ett fastnat jobb far aterstallas. Att kunna sla om vilken status som helst
  -- vore ett nytt satt att ga runt statusflodet.
  if v_status::text <> 'publishing' then
    return json_build_object('ok', false, 'error', 'not_publishing', 'status', v_status::text);
  end if;

  v_alder := now() - v_updated;
  if v_alder < c_min_alder then
    return json_build_object('ok', false, 'error', 'too_soon',
                             'alder_sekunder', floor(extract(epoch from v_alder))::bigint,
                             'kravs_sekunder', floor(extract(epoch from c_min_alder))::bigint);
  end if;

  update build_jobs
     set status = 'publish_failed',
         error  = 'Publiceringen återställdes manuellt – den hade fastnat utan att starta.'
   where id = p_job_id;

  return json_build_object('ok', true, 'alder_sekunder', floor(extract(epoch from v_alder))::bigint);
end $function$;

revoke execute on function public.reset_publish_state(uuid) from public;
revoke execute on function public.reset_publish_state(uuid) from anon;
grant  execute on function public.reset_publish_state(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Motorn kopplas bort — triggern och dess funktion släpps
-- ---------------------------------------------------------------------------
-- Efter det här är `status` ren presentation. Att workflowet, portalen eller en människa
-- skriver 'publishing' startar ingenting.
-- Ordningen spelar roll: `drop function` utan `cascade` avbryter med beroendefel så länge
-- triggern finns kvar, och med `psql -1` faller då hela filen.
-- Uppmätt 2026-08-25 — kvitto, inte påstående:
--   select t.tgname, t.tgrelid::regclass::text, t.tgenabled from pg_trigger t
--    where t.tgfoid = 'public.dispatch_publish_site'::regproc;
--   -> EN rad: build_jobs_publish_dispatch | build_jobs | O
--   Ingen funktion, vy eller constraint namner den heller (prosrc, pg_views och
--   constraintdef genomsokta). `drop function` utan cascade kan alltsa inte falla
--   filen pa ett beroende vi inte kanner till.
drop trigger if exists build_jobs_publish_dispatch on public.build_jobs;
drop function if exists public.dispatch_publish_site();

-- ---------------------------------------------------------------------------
-- VERIFIERING — kör dessa efter migrationen och jämför
-- ---------------------------------------------------------------------------
-- 1) Triggern ska vara BORTA (0 rader):
--    select tgname from pg_trigger
--     where tgrelid = 'public.build_jobs'::regclass and tgname = 'build_jobs_publish_dispatch';
--
-- 2) Funktionen ska vara BORTA (0 rader):
--    select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public' and p.proname = 'dispatch_publish_site';
--
-- 3) Övriga triggrar på build_jobs ska vara KVAR och påslagna. Uppmätt före migrationen
--    2026-08-25: fem triggrar, alla med tgenabled = 'O'. Efteråt ska fyra vara kvar,
--    fortfarande alla 'O':
--    select tgname, tgenabled from pg_trigger
--     where tgrelid = 'public.build_jobs'::regclass and not tgisinternal order by 1;
--
-- 4) Båda funktionerna ska finnas i ETT exemplar, vara SECURITY DEFINER med satt
--    search_path, och sakna =X (ingen EXECUTE till PUBLIC). Signaturen kontrolleras för att
--    en avvikande signatur skulle ge en ÖVERLAGRING i stället för en ersättning, och
--    PostgREST kan då träffa fel variant:
--    select p.oid::regprocedure::text as signatur, p.prosecdef, p.proconfig,
--           pg_get_userbyid(p.proowner) as owner,
--           coalesce(array_to_string(p.proacl::text[], ' '), 'NULL (PUBLIC har EXECUTE)') as proacl
--      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public'
--       and p.proname in ('request_publish_site', 'reset_publish_state');
--    Uppmätt 2026-08-25, före körning: ingen av dem finns. Ingen överlagringsrisk.
--
-- 5) Rökprov som inte rör ett riktigt jobb:
--    select public.request_publish_site('00000000-0000-0000-0000-000000000000'::uuid, 'exempel.se');
--
--    ⚠️ SVARET BEROR PÅ VEM SOM KÖR, och det är lätt att misstolka:
--      * i SQL-editorn, via MCP eller i `psql` (kor-migrationer.yml) finns ingen JWT.
--        auth.uid() är då NULL, admin-kontrollen fyrar först, och svaret är
--        {"ok":false,"error":"forbidden"}. DET ÄR RÄTT SVAR DÄR — det bevisar att
--        funktionen finns, är anropbar och att grinden stänger för den utan identitet.
--      * {"ok":false,"error":"not_found"} får du bara via PostgREST med en inloggad
--        ADMINS token, alltså från portalen. Det är det anropet som bevisar att
--        admin-kontrollen släpper igenom rätt person.
--    ⛔ Byt INTE ut noll-UUID:n mot ett riktigt job_id för att "prova på riktigt". Det finns
--       ingen torrkörningsflagga — anropet publicerar då en kundsajt.
