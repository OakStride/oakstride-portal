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
-- `publishing` -> äkta övergång -> triggern dispatchar C -> och runt igen. Att villkora
-- triggern hårdare flyttar bara loopen till `publish_failed`-vägen; att ta bort workflowets
-- PATCH stänger loopen men avväpnar alla tre läsarna på den manuella vägen — och den vägen
-- är den enda som skriver DNS (`repository_dispatch` har inga `inputs`, så portalknappen ger
-- alltid APPLY_DNS=false).
--
-- Efter den här migrationen är `status` REN PRESENTATION. Ingenting mekaniskt hänger på den,
-- de tre läsarna fungerar precis som förut, och det som startar en publicering är ett
-- uttryckligt anrop — inte en sidoeffekt av ett tabellskriv.
--
-- Förebilden är `request_publish_change` (kundens "publicera min ändring", migration 27),
-- som redan gör exakt detta för det andra publiceringsflödet.
--
-- ============================ ORDNING ============================
-- ⚠️ Migration 27 skriver ned `dispatch_publish_site` + triggern ur drift och ska mergas
-- FÖRE den här. Annars beskriver `main` en trigger som varken skapas eller släpps.
-- `drop ... if exists` gör filen ofarlig att köra oavsett ordning, men repohistoriken
-- blir bara sann i rätt ordning.
--
-- ⚠️ `drop trigger` tar ACCESS EXCLUSIVE-lås på build_jobs. Kör när inget bygge och ingen
-- publicering är i luften (samma varning som migration 27).

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
  v_brief    jsonb;
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
  -- klienten skyddar ingenting. Mönstren skrivs med [.] i stället för bakstreck-punkt,
  -- så att filen överlever varje väg den kan tänkas passera.
  v_domain := lower(btrim(coalesce(p_domain, '')));
  v_domain := regexp_replace(v_domain, '^https?://', '');
  v_domain := regexp_replace(v_domain, '^www[.]', '');
  v_domain := regexp_replace(v_domain, '/.*$', '');
  if v_domain !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' then
    return json_build_object('ok', false, 'error', 'bad_domain');
  end if;

  select status, brief, customer_id, shared_at
    into v_status, v_brief, v_customer, v_shared
    from build_jobs where id = p_job_id;
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

  -- Felet sväljs INTE tyst här, till skillnad från de gamla dispatch-funktionerna.
  -- En tyst `exception when others then null` gav ett jobb som stod kvar på 'publishing'
  -- utan att någonsin ha startats, och ingen visste varför.
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
    update build_jobs
       set status = 'publish_failed',
           error  = 'dispatch misslyckades: ' || sqlerrm
     where id = p_job_id;
    return json_build_object('ok', false, 'error', 'dispatch_failed', 'detail', sqlerrm);
  end;

  return json_build_object('ok', true, 'domain', v_domain);
end $function$;

-- Samma snäva behörighet som request_publish_change: varken PUBLIC eller anon.
-- Kontrollen inuti funktionen är admin-grinden; grant:en är bara ytterdörren.
revoke execute on function public.request_publish_site(uuid, text) from public;
revoke execute on function public.request_publish_site(uuid, text) from anon;
grant  execute on function public.request_publish_site(uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Motorn kopplas bort — triggern och dess funktion släpps
-- ---------------------------------------------------------------------------
-- Efter det här är `status` ren presentation. Att workflowet, portalen eller en människa
-- skriver 'publishing' startar ingenting.
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
--    2026-08-23: fem triggrar, alla med tgenabled = 'O'. Efteråt ska fyra vara kvar,
--    fortfarande alla 'O':
--    select tgname, tgenabled from pg_trigger
--     where tgrelid = 'public.build_jobs'::regclass and not tgisinternal order by 1;
--
-- 4) RPC:n ska finnas, ägas av postgres, och sakna =X (ingen EXECUTE till PUBLIC):
--    select p.proname, pg_get_userbyid(p.proowner) as owner,
--           coalesce(array_to_string(p.proacl::text[], ' '), 'NULL (PUBLIC har EXECUTE)') as proacl
--      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public' and p.proname = 'request_publish_site';
--
-- 5) Rökprov utan att publicera något: anropet ska svara {"ok":false,"error":"not_found"}
--    på ett id som inte finns — det bevisar att grinden nås och att admin-kontrollen släppt
--    igenom, utan att röra ett riktigt jobb:
--    select public.request_publish_site('00000000-0000-0000-0000-000000000000'::uuid, 'exempel.se');
