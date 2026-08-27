-- Migration 29: skriv ned resten av det som finns i produktion men saknas i repot
--
-- ⚠️ DEN HÄR FILEN ÄNDRAR INGENTING I DRIFT. Varje sats är villkorad på att objektet
-- saknas. Kör den mot produktion och ingenting händer — det är hela poängen. Den finns
-- för att en databas som byggs UR REPOT ska bli densamma som den som körs.
--
-- Migration 27 gjorde samma sak för funktioner, enum, kolumner, trigger och grants, och
-- sa uttryckligen att policies och index INTE var mätta. Den här filen tar resten.
--
-- ============================ VAD SOM ÄR MÄTT, OCH NÄR ============================
-- Uppmätt mot drift 2026-08-27 av Nova, efter att migration 27 och 28 körts:
--   31 funktioner · 21 tabeller · 0 vyer · 54 RLS-policies i public · 4 fristående index
--   Repot beskrev 18 av 21 tabeller och 39 av 54 policies.
--   Index: inga glapp. Vyer: finns inte, varken i drift eller repo.
--
-- Alla fyra tabellerna nedan är i SKARP DRIFT och innehåller data (mätt 2026-08-27):
--   pricing_settings 1 rad · billing_details 1 rad · extra_work_approvals 1 rad
--   consents 8 rader
-- Därför är varje sats skriven som "skapa om den saknas", aldrig som drop-and-recreate.
--
-- 🔴 VARFÖR DET SPELAR ROLL: byggs databasen om ur repot som det ser ut i dag (nytt
--   projekt, återställning efter haveri) saknas fem admin-policies, och då kan admin
--   inte skapa poster åt kund. Portalens adminflöden går sönder, tyst.
--
-- ⛔ VAD SOM INTE LIGGER HÄR — beteendeändringar hör hemma i migration 30:
--   * norm_host() strippar inte www i drift (dubbelt bakstreck i regexet)
--   * notify_email() saknar failed-grenen i repot
--   * policyn "extra-godk: kund hanterar egna" är FOR ALL, så en kund kan radera sitt
--     eget godkännande av extraarbete
--   Migration 27 blev underkänd två gånger för att den blandade "skriva ned" med
--   "ändra". Gör inte om det.
-- =================================================================================

-- ---------------------------------------------------------------------------
-- 1. Tabeller som ingen fil beskriver
-- ---------------------------------------------------------------------------
-- ⚠️ RLS slås på EXPLICIT här. Lita inte på event-triggern ensure_rls: den finns i
-- drift men kan inte återskapas ur repot (kräver superuser — se migration 27). I en
-- återuppbyggnad finns den alltså inte, och då får dessa tabeller ingen RLS alls.

create table if not exists public.billing_details (
  user_id       uuid        not null references public.profiles(id) on delete cascade,
  company       text,
  org_nr        text,
  address       text,
  postal_city   text,
  invoice_email text,
  reference     text,
  updated_at    timestamptz not null default now(),
  constraint billing_details_pkey primary key (user_id)
);
alter table public.billing_details enable row level security;

create table if not exists public.extra_work_approvals (
  user_id      uuid        not null references public.profiles(id) on delete cascade,
  spec_version integer     not null,
  approved_at  timestamptz not null default now(),
  constraint extra_work_approvals_pkey primary key (user_id, spec_version)
);
alter table public.extra_work_approvals enable row level security;

create table if not exists public.pricing_settings (
  id          integer     not null default 1,
  site_price  numeric     not null default 3000,
  drift_month numeric     not null default 150,
  rate_setup  numeric     not null default 1095,
  rate_change numeric     not null default 1095,
  updated_at  timestamptz not null default now(),
  constraint pricing_settings_pkey primary key (id),
  constraint pricing_singleton check (id = 1)
);
alter table public.pricing_settings enable row level security;

-- Portalen laser raden med .eq("id", 1).maybeSingle(). Utan raden far en aterbyggd
-- databas inga priser. Vardena nedan ar EXAKT de som star i drift 2026-08-27 och
-- identiska med kolumndefaulterna. I produktion ar satsen en no-op (raden finns).
insert into public.pricing_settings (id) values (1) on conflict (id) do nothing;

-- consents fanns bara BORTKOMMENTERAD i migration-3-stats.sql rad 90.
create table if not exists public.consents (
  id             bigint      generated always as identity,
  vid            text        not null,
  policy_version text        not null,
  created_at     timestamptz not null default now(),
  constraint consents_pkey primary key (id)
);
alter table public.consents enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Kolumner som ingen fil beskriver
-- ---------------------------------------------------------------------------
alter table public.requests             add column if not exists change_items jsonb;
alter table public.onboarding_checkoffs add column if not exists with_extras  boolean;

-- ---------------------------------------------------------------------------
-- 3. De 15 policies som saknades
-- ---------------------------------------------------------------------------
-- Postgres har ingen "create policy if not exists", darfor DO-blocket. Villkoret ar
-- policyns NAMN pa den tabellen — samma nyckel som pg_policies anvander.
--
-- ⚠️ Ingen av dessa ror en BEFINTLIG policy. Skulle en policy med samma namn redan
-- finnas hoppas den over ororad, aven om dess villkor skiljer sig. Det ar avsiktligt:
-- att tyst skriva om ett RLS-villkor ar precis den sortens andring den har filen inte
-- ska gora. Avviker nagot upptacks det av verifieringen langst ner, inte av en drop.

do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('billing_details',       'faktura: admin läser',             'for select to public using (is_admin())'),
      ('billing_details',       'faktura: admin skapar',            'for insert to authenticated with check (is_admin())'),
      ('billing_details',       'faktura: admin uppdaterar',        'for update to authenticated using (is_admin()) with check (is_admin())'),
      ('billing_details',       'faktura: kund hanterar egna',      'for all to public using (user_id = auth.uid()) with check (user_id = auth.uid())'),
      ('extra_work_approvals',  'extra-godk: admin läser',          'for select to public using (is_admin())'),
      ('extra_work_approvals',  'extra-godk: admin skapar',         'for insert to authenticated with check (is_admin())'),
      ('extra_work_approvals',  'extra-godk: kund hanterar egna',   'for all to public using (user_id = auth.uid()) with check (user_id = auth.uid())'),
      ('pricing_settings',      'priser: admin skriver',            'for all to public using (is_admin()) with check (is_admin())'),
      ('pricing_settings',      'priser: alla läser',               'for select to public using (true)'),
      ('consents',              'consents: öppen insert',           'for insert to anon, authenticated with check (char_length(vid) >= 8 and char_length(vid) <= 64 and char_length(policy_version) >= 4 and char_length(policy_version) <= 20)'),
      ('agreement_acceptances', 'acceptances: admin skapar',        'for insert to authenticated with check (is_admin())'),
      ('onboarding_checkoffs',  'checkoffs: admin bockar av',       'for insert to authenticated with check (is_admin())'),
      ('request_comments',      'comments: admin skapar',           'for insert to authenticated with check (is_admin())'),
      ('requests',              'requests: admin skapar',           'for insert to authenticated with check (is_admin())'),
      ('site_change_proposals', 'proposals: admin agerar som kund', 'for insert to authenticated with check (is_admin())')
    ) as t(tabell, policynamn, villkor)
  loop
    if not exists (
      select 1 from pg_policies
       where schemaname = 'public' and tablename = r.tabell and policyname = r.policynamn
    ) then
      execute format('create policy %I on public.%I %s', r.policynamn, r.tabell, r.villkor);
      raise notice 'migration 29: skapade policy "%" pa %', r.policynamn, r.tabell;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Grants: PUBLIC EXECUTE pa e-postsandaren ar ATERKALLAD i drift
-- ---------------------------------------------------------------------------
-- 🔴 Ingen fil i repot aterkallar den. En ateruppbyggnad ur repot ger alltsa anon och
-- authenticated ratt att anropa oak_send_email direkt. Drift 2026-08-27:
--   proacl = postgres=X/postgres service_role=X/postgres   (inget =X, inget anon)
revoke execute on function public.oak_send_email(text, text, text) from public;
revoke execute on function public.oak_send_email(text, text, text) from anon;
revoke execute on function public.oak_send_email(text, text, text) from authenticated;

-- ---------------------------------------------------------------------------
-- 5. add_customer_spec_version — repot har FEL SIGNATUR
-- ---------------------------------------------------------------------------
-- Drift har treargumentsversionen. Repot (migration-12 rad 30) definierar en
-- ENARGUMENTSVERSION som inte finns i drift. app.js rad 1815 anropar treargumentsvarianten.
--
-- 🔴 Varfor det inte racker att lagga till den ratta: treargumentsversionen har DEFAULT
-- pa argument 2 och 3, sa anropet add_customer_spec_version('x') traffar den. Ligger
-- BADA kvar i en aterbyggd databas blir det anropet TVETYDIGT och faller med fel.
-- Darfor slapps enargumentsversionen har. Matt 2026-08-27: den finns INTE i drift, sa
-- satsen ar en no-op i produktion. Den behovs bara i en ateruppbyggnad, dar migration-12
-- hinner skapa den forst.
drop function if exists public.add_customer_spec_version(text);

-- Kroppen nedan ar Postgres EGEN rendering ur drift (pg_get_functiondef), inte avskriven
-- for hand. md5 av den renderingen 2026-08-27: 9ebea1d75d0296e050f4ecdd13180e3c
CREATE OR REPLACE FUNCTION public.add_customer_spec_version(p_complement text, p_scope text DEFAULT NULL::text, p_user uuid DEFAULT NULL::uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid;
  v_latest requirement_specs;
  v_data jsonb;
  v_note text;
  v_scope text;
  v_page_idx int;
  v_page jsonb;
  v_details jsonb;
  v_new_id bigint;
begin
  if p_complement is null or length(trim(p_complement)) = 0 then
    return null;
  end if;
  v_uid := coalesce(p_user, auth.uid());
  -- Endast admin får skriva åt någon annan än sig själv.
  if v_uid <> auth.uid() and not is_admin() then
    return null;
  end if;
  select * into v_latest from requirement_specs
    where user_id = v_uid order by version desc limit 1;
  if v_latest.id is null then
    return null;
  end if;

  v_scope := nullif(trim(coalesce(p_scope, '')), '');
  v_note := case when v_scope is not null then '[' || v_scope || '] ' else '' end || trim(p_complement);

  if v_latest.source = 'kund' and coalesce(v_latest.change_note, '') = v_note then
    return v_latest.id;
  end if;

  v_data := coalesce(v_latest.data, '{}'::jsonb);
  if v_data->'sections' is null then
    v_data := jsonb_set(v_data, '{sections}', '{}'::jsonb, true);
  end if;

  v_page_idx := null;
  if v_scope is not null and v_scope <> 'Hela siten' then
    select (idx - 1)::int into v_page_idx
    from jsonb_array_elements(coalesce(v_data->'sections'->'sidor', '[]'::jsonb)) with ordinality as t(elem, idx)
    where elem->>'text' = v_scope
    limit 1;
  end if;

  if v_page_idx is not null then
    v_page := v_data->'sections'->'sidor'->v_page_idx;
    v_details := coalesce(v_page->'details', '[]'::jsonb) ||
      jsonb_build_object('text', trim(p_complement), 'tier', 'standard', 'kind', 'change');
    v_page := jsonb_set(v_page, '{details}', v_details, true);
    v_data := jsonb_set(v_data, array['sections', 'sidor', v_page_idx::text], v_page, true);
  else
    v_data := jsonb_set(v_data, '{sections,fortydliganden}',
      coalesce(v_data->'sections'->'fortydliganden', '[]'::jsonb) ||
      jsonb_build_object('text', v_note, 'tier', 'standard'), true);
  end if;

  insert into requirement_specs (user_id, version, data, change_note, source, created_by)
    values (v_uid, v_latest.version + 1, v_data, v_note, 'kund', auth.uid())
    returning id into v_new_id;
  return v_new_id;
end;
$function$;

grant execute on function public.add_customer_spec_version(text, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- VERIFIERING — kor detta EFTER migrationen
-- ---------------------------------------------------------------------------
-- 1. Att filen inte andrade nagot i drift. md5 fore = md5 efter:
--
--   select md5(pg_get_functiondef(p.oid)) from pg_proc p
--     join pg_namespace n on n.oid=p.pronamespace
--    where n.nspname='public' and p.proname='add_customer_spec_version';
--   -- ska ge 9ebea1d75d0296e050f4ecdd13180e3c
--
-- 2. Att antalet policies ar oforandrat i produktion (54) — alla 15 fanns redan:
--
--   select count(*) from pg_policies where schemaname='public';
--
-- 3. ⚠️ Anvand INTE `like 'migration-2[9]%'` for att kolla liggaren. Postgres LIKE
--    kanner bara % och _, sa en teckenklass matchar aldrig och fragan ar alltid tom.
--    Ratt form: `filnamn ~ '^migration-29-'`. Se studio/minne/kunskap-verifiering.md.
--
-- 4. Ta med minst en rad du VET ska ge traff i varje kontrollfraga. Ett kontrollsteg
--    som ljuger blir brus, och da fangar det inte ett akta glapp heller.
