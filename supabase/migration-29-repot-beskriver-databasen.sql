-- Migration 29: skriv ned resten av det som finns i produktion men saknas i repot
--
-- Version 2. Version 1 blev underkänd på fem punkter — de står som "RÄTTAT" nedan, med
-- mätningen som gjordes för att avgöra saken. Läs dem innan du ändrar något här.
--
-- ⚠️ FILEN SKA VARA EN NO-OP MOT PRODUKTION, men den är det inte genom att varje sats är
-- villkorad — det påstod version 1, och det var osant. Följande satser är VILLKORSLÖSA:
--   * `set client_encoding` (rad nedan)          — ofarlig, men körs alltid
--   * `alter table ... enable row level security` ×4 — no-op i innehåll, men tar
--     ACCESS EXCLUSIVE-lås en kort stund på fyra livetabeller
--   * `revoke` ×3 och `grant` ×2                 — idempotenta, men körs alltid
--   * `create or replace function`               — se sektion 5, den har ett FÖRKRAV
--   * inserten i sektion 1                       — villkorad på konflikt, inte på frånvaro
-- Allt annat är villkorat på att objektet saknas. **Och om filen ändå gör något larmar
-- den** — se sektion 6, som jämför läget före och efter och skriker med `raise warning`.
--
-- ============================ KVITTO PÅ MÄTNINGEN ============================
-- Allt nedan är uppmätt mot drift 2026-08-27, efter att migration 27 och 28 körts.
-- Kör om frågorna och jämför — påstå ingenting härifrån utan att ha gjort det.
--
--   select count(*) from pg_policies where schemaname='public';        -> 54
--   select count(*) from pg_tables   where schemaname='public';        -> 21
--
-- 🔢 TABELLRÄKNINGEN, som version 1 fick fel (den påstod "18 av 21"):
--   21 i drift · 16 beskrivna i repots supabase/*.sql (schema.sql inräknad)
--   + 4 som den här filen skriver ned = 20
--   + `applied_migrations`, som skapas av kor-migrationer.yml rad 100 i AGENT-repot,
--     inte av någon migrationsfil = 21. Det går alltså ihop, men bara med den raden.
--
-- 🔒 RLS på de fyra tabellerna, uppmätt (pg_class.relrowsecurity):
--   billing_details t · consents t · extra_work_approvals t · pricing_settings t
--   relforcerowsecurity: false på alla fyra. `enable`-satserna är alltså no-ops i dag.
--
-- 🔁 TRIGGERS på de fyra: INGA (pg_trigger, tgisinternal = false -> tom).
--   `updated_at` sätts av klienten (app.js rad 917 och 2178), inte av en trigger.
--
-- 🔑 FUNKTIONER (pg_proc, 2026-08-27):
--   add_customer_spec_version(text,text,uuid)  md5 9ebea1d75d0296e050f4ecdd13180e3c
--     proacl: =X postgres=X anon=X authenticated=X service_role=X   (PUBLIC har EXECUTE)
--     ENARGUMENTSVERSIONEN FINNS INTE i drift — droppen i sektion 5 är alltså en no-op.
--   oak_send_email(text,text,text)             md5 fc1d6c119bfcc48c03d7bdce8b391462
--     proacl: postgres=X service_role=X        (INGET =X — PUBLIC är återkallad)
--
-- 📦 RADER i tabellerna: pricing_settings 1 · billing_details 1 · extra_work_approvals 1
--   · consents 8. Alla fyra är i skarp drift; därför skapa-om-saknas, aldrig drop.
--
-- ⚠️ TABELL-GRANTS (relacl) är MÄTTA men återges INTE här. Alla fyra har Supabases
--   standard (`anon`, `authenticated`, `service_role` med fulla tabellrättigheter, som
--   RLS sedan begränsar). Det sätts av Supabases default privileges vid tabellskapande,
--   inte av oss. **Jag har inte verifierat att en återuppbyggnad får samma default** —
--   det är ett känt, oprövat antagande, inte ett påstående.
--
-- ============================ ÅTERUPPBYGGNADSVÄGEN ============================
-- 🔴 `kor-migrationer.yml` globbar BARA `migration-*.sql`. **`schema.sql` körs aldrig av
--   den.** Där ligger `profiles`, `requests`, `request_comments` och `is_admin()` — som
--   den här filen är helt beroende av. `migration-1` och `migration-4` finns dessutom
--   inte som filer alls (migration-3 rad 88 hänvisar till en "migration 4, körd
--   2026-07-17"). En återuppbyggnad är alltså: schema.sql för hand FÖRST, sedan
--   migrationerna i nummerordning. Det är inte en väg någon provat.
--
-- ⛔ VAD SOM INTE LIGGER HÄR — beteendeändringar hör hemma i migration 30:
--   norm_host() (dubbelt bakstreck, strippar inte www) · notify_email() (saknar
--   failed-grenen) · policyn "extra-godk: kund hanterar egna" (FOR ALL, så en kund kan
--   radera sitt eget godkännande). Migration 27 blev underkänd två gånger för att den
--   blandade "skriva ned" med "ändra". Gör inte om det.
-- =============================================================================

-- RÄTTAT (granskningsfynd 10): guarden i sektion 3 matchar policynamn med å, ä, ö byte
-- för byte. Körs psql med annan client_encoding mangleras namnen, guarden missar, och
-- filen skapar 15 dubblettpolicyer i produktion. En rad gör antagandet mätt.
set client_encoding to 'UTF8';

-- Fångar läget FÖRE. Sektion 6 jämför mot det och larmar om filen gjorde något.
create temp table _f29_fore on commit drop as
select
  (select count(*) from pg_tables where schemaname = 'public'
     and tablename in ('billing_details','extra_work_approvals','pricing_settings','consents')) as tabeller,
  (select count(*) from information_schema.columns where table_schema = 'public'
     and ((table_name = 'requests'             and column_name in ('change_items','change_note'))
       or (table_name = 'onboarding_checkoffs' and column_name = 'with_extras'))) as kolumner,
  (select count(*) from pg_policies where schemaname = 'public') as policies,
  (select count(*) from public.pricing_settings) as prisrader;

-- ---------------------------------------------------------------------------
-- 1. Tabeller som ingen fil beskriver
-- ---------------------------------------------------------------------------
-- ⚠️ RLS slås på EXPLICIT. Lita inte på event-triggern ensure_rls: den finns i drift men
-- kan inte återskapas ur repot (kräver superuser — se migration 27). I en återuppbyggnad
-- finns den alltså inte, och då får dessa tabeller ingen RLS alls.

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
-- databas inga priser. Vardena ar EXAKT de i drift 2026-08-27 (3000/150/1095/1095) och
-- identiska med kolumndefaulterna. I produktion ar satsen en no-op — raden finns.
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
-- RÄTTAT (granskningsfynd 2): `requests.change_note` saknades i version 1. app.js rad
-- 2101 skriver change_note och change_items i SAMMA update-sats — jag skrev ned den ena
-- och missade den andra. Uppmätt i drift 2026-08-27: text, nullable, ingen default.
alter table public.requests             add column if not exists change_note  text;
alter table public.requests             add column if not exists change_items jsonb;
alter table public.onboarding_checkoffs add column if not exists with_extras  boolean;

-- ---------------------------------------------------------------------------
-- 3. De 15 policies som saknades
-- ---------------------------------------------------------------------------
-- Postgres har ingen "create policy if not exists", darfor DO-blocket. Villkoret ar
-- policyns NAMN pa den tabellen — samma nyckel som pg_policies anvander.
--
-- ⚠️ Ingen av dessa ror en BEFINTLIG policy. Skulle en policy med samma namn redan finnas
-- hoppas den over ororad, aven om dess villkor skiljer sig. Det ar avsiktligt: att tyst
-- skriva om ett RLS-villkor ar precis den sortens andring den har filen inte ska gora.
-- Verifieringen i sektion 7 jamfor qual och with_check per policy — INTE antalet, som
-- version 1 gjorde. En rakning kan per definition inte upptacka att en policy med ratt
-- namn har fel villkor (granskningsfynd 7).

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
      -- RÄTTAT (granskningsfynd 1): var `raise notice`. En NOTICE syns bara som loggtext
      -- och drunknar bland alla "already exists, skipping". kor-migrationer.yml lyfter
      -- BARA WARNING till en annotering — och en ny permissiv policy i produktion får
      -- inte passera tyst, särskilt inte när SHA-låset gör filen omöjlig att köra om.
      raise warning 'migration 29 SKAPADE policy "%" pa %. Filen skulle vara en no-op mot produktion — kontrollera varfor den saknades.', r.policynamn, r.tabell;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Grants: PUBLIC EXECUTE pa e-postsandaren ar ATERKALLAD i drift
-- ---------------------------------------------------------------------------
-- 🔴 Ingen fil i repot aterkallar den. En ateruppbyggnad ur repot ger alltsa anon och
-- authenticated ratt att anropa oak_send_email direkt.
revoke execute on function public.oak_send_email(text, text, text) from public;
revoke execute on function public.oak_send_email(text, text, text) from anon;
revoke execute on function public.oak_send_email(text, text, text) from authenticated;
-- RÄTTAT (granskningsfynd 4): version 1 hade bara de tre revoke:arna. I en
-- återuppbyggnad skapas funktionen av migration-14 som postgres (proacl NULL = ägare +
-- PUBLIC); efter revoke:arna blir den `postgres=X` UTAN `service_role=X`, alltså
-- STRIKTARE än drift — på precis den rad som säger sig återge driftens ACL.
-- Drift 2026-08-27: `postgres=X/postgres service_role=X/postgres`.
grant execute on function public.oak_send_email(text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 5. add_customer_spec_version — repot har FEL SIGNATUR
-- ---------------------------------------------------------------------------
-- Drift har treargumentsversionen. Repot (migration-12 rad 30) definierar en
-- ENARGUMENTSVERSION som inte finns i drift. app.js rad 1815 anropar treargumentsvarianten.
--
-- 🔴 Varfor det inte racker att lagga till den ratta: treargumentsversionen har DEFAULT pa
-- argument 2 och 3. Ligger BADA kvar i en aterbyggd databas finns en tyst gammal kodvag
-- som ignorerar p_scope och alltid skriver pa auth.uid() i stallet for
-- coalesce(p_user, auth.uid()). Matt 2026-08-27: enargumentsversionen finns INTE i drift,
-- sa droppen ar en no-op i produktion. Den behovs bara i en ateruppbyggnad, dar
-- migration-12 hinner skapa den forst. DROP FUNCTION matchar pa exakt argumenttyplista,
-- sa treargumentsversionen ar oatkomlig for satsen.
drop function if exists public.add_customer_spec_version(text);

-- RÄTTAT (granskningsfynd 5): `create or replace` nedan är villkorslös, och version 1 la
-- kontrollen som ska bevisa att inget skrevs över UNDER rubriken "kör detta EFTER".
-- Avviker transkriberingen på ett tecken är funktionen redan överskriven när md5:an
-- avslöjar det, och originalet finns bara som en 32 tecken lång hash. Nu är kontrollen
-- ett FÖRKRAV: avviker drift från det vi tror avbryts hela migrationen. Filen körs i EN
-- transaktion (-1 i kor-migrationer.yml), så ett exception rullar tillbaka allt.
do $$
declare
  v_md5 text;
begin
  select md5(pg_get_functiondef(p.oid)) into v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.oid::regprocedure::text = 'add_customer_spec_version(text,text,uuid)';

  if v_md5 is null then
    -- Finns inte: aterupbyggnad. Skapandet nedan ar da hela poangen.
    raise warning 'migration 29: add_customer_spec_version(text,text,uuid) fanns inte — skapas nu. Vantat i en ateruppbyggnad, ALARMERANDE i produktion.';
  elsif v_md5 <> '9ebea1d75d0296e050f4ecdd13180e3c' then
    raise exception 'migration 29 AVBRYTER: add_customer_spec_version i drift har md5 % men filen ar skriven mot 9ebea1d75d0296e050f4ecdd13180e3c. Nagon har andrat funktionen sedan 2026-08-27. Kor INTE over den — las ut driftversionen med pg_get_functiondef, jamfor, och skriv en ny migration.', v_md5;
  end if;
end $$;

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

-- Drift har PUBLIC EXECUTE (=X) pa funktionen, alltsa racker default vid nyskapande.
-- Granten nedan aterger den explicita raden authenticated=X som ocksa star i drift.
grant execute on function public.add_customer_spec_version(text, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. LARM OM FILEN INTE VAR EN NO-OP
-- ---------------------------------------------------------------------------
-- RÄTTAT (granskningsfynd 1). Hela filens löfte är att ingenting händer i produktion.
-- Händer något ändå ska det INTE gå att missa: kor-migrationer.yml lyfter WARNING till
-- en Actions-annotering, medan en NOTICE drunknar i loggtexten. Efter körningen är filen
-- dessutom bokförd med SHA-lås och kan aldrig köras om — larmet är enda spåret.
do $$
declare
  f  record;
  nt int; nk int; np int; npr int;
begin
  select * into f from _f29_fore;
  select count(*) into nt from pg_tables where schemaname = 'public'
     and tablename in ('billing_details','extra_work_approvals','pricing_settings','consents');
  select count(*) into nk from information_schema.columns where table_schema = 'public'
     and ((table_name = 'requests'             and column_name in ('change_items','change_note'))
       or (table_name = 'onboarding_checkoffs' and column_name = 'with_extras'));
  select count(*) into np  from pg_policies where schemaname = 'public';
  select count(*) into npr from public.pricing_settings;

  if nt <> f.tabeller then
    raise warning 'migration 29 SKAPADE % tabell(er) (% -> %). I produktion ska den siffran vara oforandrad.', nt - f.tabeller, f.tabeller, nt;
  end if;
  if nk <> f.kolumner then
    raise warning 'migration 29 LADE TILL % kolumn(er) (% -> %). I produktion ska den siffran vara oforandrad.', nk - f.kolumner, f.kolumner, nk;
  end if;
  if np <> f.policies then
    raise warning 'migration 29 SKAPADE % policy/policies (% -> %). I produktion ska den siffran vara oforandrad.', np - f.policies, f.policies, np;
  end if;
  if npr <> f.prisrader then
    raise warning 'migration 29 SATTE IN prisraden (% -> %). I produktion ska den redan finnas.', f.prisrader, npr;
  end if;
  if nt = f.tabeller and nk = f.kolumner and np = f.policies and npr = f.prisrader then
    raise notice 'migration 29: no-op bekraftad — inga tabeller, kolumner, policies eller rader tillkom.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. VERIFIERING — kor detta EFTER migrationen
-- ---------------------------------------------------------------------------
-- 1. Att funktionen inte skrevs over. Samma md5 som forkravet i sektion 5 kraver:
--
--   select md5(pg_get_functiondef(p.oid)) from pg_proc p
--     join pg_namespace n on n.oid=p.pronamespace
--    where n.nspname='public' and p.proname='add_customer_spec_version';
--   -- ska ge 9ebea1d75d0296e050f4ecdd13180e3c
--
-- 2. Att policyerna har ratt VILLKOR, inte bara ratt antal. En rakning kan inte upptacka
--    att en policy med ratt namn har fel qual — det var granskningsfynd 7 mot version 1:
--
--   select tablename, policyname, cmd, roles::text, qual, with_check
--     from pg_policies where schemaname='public'
--      and (tablename in ('billing_details','extra_work_approvals','pricing_settings')
--           or policyname in ('consents: öppen insert','acceptances: admin skapar',
--               'checkoffs: admin bockar av','comments: admin skapar',
--               'requests: admin skapar','proposals: admin agerar som kund'))
--    order by tablename, policyname;
--   -- jamfor rad for rad mot sektion 3. Villkoren ska vara identiska.
--
-- 3. Att grants ar oforandrade:
--   select p.oid::regprocedure, array_to_string(p.proacl::text[],' ') from pg_proc p
--     join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
--    and p.proname in ('oak_send_email','add_customer_spec_version');
--   -- oak_send_email ska ge: postgres=X/postgres service_role=X/postgres
--
-- 4. ⚠️ Anvand INTE `like 'migration-2[9]%'` for att kolla liggaren. Postgres LIKE kanner
--    bara % och _, sa en teckenklass matchar aldrig och fragan ar alltid tom.
--    Ratt form: `filnamn ~ '^migration-29-'`. Se studio/minne/kunskap-verifiering.md.
--
-- 5. Ta med minst en rad du VET ska ge traff i varje kontrollfraga. Ett kontrollsteg som
--    ljuger blir brus, och da fangar det inte ett akta glapp heller.
