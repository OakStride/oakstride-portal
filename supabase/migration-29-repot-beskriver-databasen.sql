-- Migration 29: skriv ned resten av det som finns i produktion men saknas i repot
--
-- Version 4. Underkänd tre gånger: v1 på fem punkter, v2 på två, v3 på en — alla står
-- som "RÄTTAT" nedan, med mätningen som avgjorde saken. Läs dem innan du ändrar något här.
-- Det ena fyndet mot v2 var en regression jag själv införde när jag lagade v1: larmet i
-- sektion 6 gjorde filen omöjlig att köra i en återuppbyggnad, alltså i det enda scenario
-- den finns för. En fix kan gå sönder på ett nytt sätt; granska varje version för sig.
--
-- ⚠️ FILEN SKA VARA EN NO-OP MOT PRODUKTION, men den är det inte genom att varje sats är
-- villkorad — det påstod version 1, och det var osant. Följande satser är VILLKORSLÖSA:
--   * `set client_encoding` (rad nedan)          — ofarlig, men körs alltid
--   * `alter table ... enable row level security` ×4 — no-op i innehåll, men tar
--     ACCESS EXCLUSIVE-lås en kort stund på fyra livetabeller
--   * `revoke` ×3 och `grant` ×2                 — idempotenta, men körs alltid
--   * `create or replace function`               — se sektion 5, den har ett FÖRKRAV
--   * inserten i sektion 1                       — villkorad på konflikt, inte på frånvaro
-- Allt annat är villkorat på att objektet saknas. **Gör filen ändå något larmar den** —
-- men var noga med VAD som bevakar vad. Fullständig lista, så att ingen tar bort en vakt
-- i tron att den är överflödig:
--   tabeller · kolumner · prisraden · RLS-läget · funktionens md5 → sektion 6
--   de 15 policyerna                                            → sektion 3, en per policy
--   droppen av enargumentsversionen                             → egen vakt före droppen
--   grants (revoke ×3, grant ×2)                                → INGEN vakt
-- Grants är alltså det enda otäckta, med flit: de är mätta som no-ops (se kvittot nedan),
-- och det är ett antagande om drift snarare än en kontroll. Säg det, dölj det inte.
-- ⚠️ Md5-larmet i sektion 6 är ett `raise exception`, inte en varning — det är det enda
-- läget filen inte kan ångra i efterhand, och transaktionen är öppen när det upptäcks.
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
--   inte som filer alls (migration-3 rad 89 hänvisar till en "migration 4, körd
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
--
-- 🔴 RÄTTAT (granskningsfynd mot v2, en regression jag själv införde): detta var förut
-- `create temp table _f29_fore on commit drop as select ... from public.pricing_settings`.
-- Den tabellen skapas först längre ned i DEN HÄR filen. `CREATE TABLE AS SELECT` planerar
-- sin SELECT innan den kör, så i en tom databas byggd ur repot avbryts satsen med
-- `relation "public.pricing_settings" does not exist`, ON_ERROR_STOP fyrar, -1 rullar
-- tillbaka — och migration 29 kör aldrig. Filen fungerade alltså mot produktion men inte
-- i det enda scenario den finns för. `case when to_regclass(...)` hjälper inte:
-- relationsreferenser slås upp vid parsning även i en gren som aldrig körs. Dynamisk SQL
-- i ett DO-block är det som fungerar.
--
-- ⚠️ `on commit preserve rows` + explicit drop sist, inte `on commit drop`. Under
-- kor-migrationer.yml körs filen som `psql -1 -f` och skillnaden är noll. Körs den för
-- hand statement-för-statement commitas `create temp table` för sig, `on commit drop`
-- släpper tabellen omedelbart, och sektion 6 dör på "relation _f29_fore does not exist"
-- EFTER att allt annat redan är applicerat. Filen har körts för hand förut.
-- `if not exists` + `delete`: avbryts en HANDKORNING efter den har raden men fore
-- `drop table` sist, overlever tabellen sessionen (preserve rows) och nasta forsok hade
-- dott pa "relation _f29_fore already exists" — vid filens forsta riktiga sats. Hogljutt
-- och sakert, men onodigt. (Granskningsfynd 4 mot v3.)
create temp table if not exists _f29_fore (
  tabeller  int,
  kolumner  int,
  prisrader bigint,
  fn_md5    text,
  rls_pa    int
) on commit preserve rows;
delete from _f29_fore;

do $$
declare
  v_pris bigint;
begin
  if to_regclass('public.pricing_settings') is not null then
    execute 'select count(*) from public.pricing_settings' into v_pris;
  else
    v_pris := -1;   -- tabellen fanns inte alls: ateruppbyggnad, inte produktion
  end if;

  insert into _f29_fore (tabeller, kolumner, prisrader, fn_md5, rls_pa)
  select
    (select count(*) from pg_tables where schemaname = 'public'
       and tablename in ('billing_details','extra_work_approvals','pricing_settings','consents')),
    (select count(*) from information_schema.columns where table_schema = 'public'
       and ((table_name = 'requests'             and column_name in ('change_items','change_note'))
         or (table_name = 'onboarding_checkoffs' and column_name = 'with_extras'))),
    v_pris,
    (select md5(pg_get_functiondef(oid)) from pg_proc
      where oid = to_regprocedure('public.add_customer_spec_version(text,text,uuid)')),
    -- Granskningsfynd 2 mot v3: `enable row level security` ×4 var filens sista
    -- tillstandsandring UTAN vakt. Matningen 2026-08-27 sager att alla fyra redan har RLS,
    -- men korningen sker senare an matningen. Andras det daremellan slar filen pa RLS pa en
    -- livetabell utan ett ord — och `consents` har bara en INSERT-policy, sa dar tystnar
    -- ALL lasning via API:t i samma sekund.
    (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relrowsecurity
        and c.relname in ('billing_details','extra_work_approvals','pricing_settings','consents'));
end $$;

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
-- RÄTTAT (granskningsfynd 3 mot v2): droppen ar filens ENDA oaterkalleliga sats, och den
-- var den enda utan vakt och utan larm. Sektion 6 tittar inte pa funktioner. Andrades
-- tillstandet mellan matningen 2026-08-27 och korningen forsvinner en funktion utan ett ord.
do $$
begin
  if to_regprocedure('public.add_customer_spec_version(text)') is not null then
    raise warning 'migration 29 DROPPAR enargumentsversionen av add_customer_spec_version. Den var uppmatt som FRANVARANDE i drift 2026-08-27 - i produktion ska den har raden inte fyra.';
  end if;
end $$;

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
  -- 🔴 RÄTTAT (granskningsfynd 2 mot v2): stod förut
  -- `p.oid::regprocedure::text = 'add_customer_spec_version(text,text,uuid)'`.
  -- `regprocedure`s rendering utelämnar schemat ENDAST när funktionen är synlig i
  -- sessionens search_path. Ligger inte `public` där renderas den som
  -- `public.add_customer_spec_version(...)`, villkoret matchar aldrig, v_md5 blir NULL —
  -- och blocket faller i "fanns inte, skapas nu"-grenen och SLÄPPER IGENOM
  -- överskrivningen. En vakt vars felläge är "släpp igenom" tar tillbaka precis den flytt
  -- av kontrollen till före skadan som den finns för. Filen pinnar client_encoding av
  -- samma skäl men lämnade search_path fritt. `to_regprocedure` är schemaexplicit,
  -- oberoende av search_path, och ger NULL i stället för att kasta när funktionen saknas.
  select md5(pg_get_functiondef(oid)) into v_md5
    from pg_proc
   where oid = to_regprocedure('public.add_customer_spec_version(text,text,uuid)');

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
-- RÄTTAT (granskningsfynd 5 mot v2): policyräknaren är BORTTAGEN. Den räknade alla 54
-- policies i public, inte bara mina 15 — en nettosiffra över en supermängd. Skapar filen
-- en av sina 15 samtidigt som något annat tar bort en orelaterad policy blir differensen
-- noll och larmet fyrar aldrig (READ COMMITTED, så efter-frågan ser andra sessioners
-- commits). Den kunde alltså både falsklarma och maskera. Policy-blocket i sektion 3
-- larmar redan PER SKAPAD POLICY, med namn och tabell — strängt mer information.
--
-- RÄTTAT (granskningsfynd 4 mot v2): funktionskroppens md5 jämförs nu här också. Förut
-- gates den bara av förkravet i sektion 5, och rubriken lovade mer än sektionen höll.
do $$
declare
  f  record;
  nt int; nk int; npr bigint; nfn text; nrls int;
begin
  select * into f from _f29_fore;
  if not found then
    raise warning 'migration 29: snapshot-raden saknas — sektion 6 kan inte jamfora nagot. Filen har korts pa ett satt den inte forutser; kontrollera i drift for hand.';
    return;
  end if;
  select count(*) into nt from pg_tables where schemaname = 'public'
     and tablename in ('billing_details','extra_work_approvals','pricing_settings','consents');
  select count(*) into nk from information_schema.columns where table_schema = 'public'
     and ((table_name = 'requests'             and column_name in ('change_items','change_note'))
       or (table_name = 'onboarding_checkoffs' and column_name = 'with_extras'));
  select count(*) into npr from public.pricing_settings;
  select md5(pg_get_functiondef(oid)) into nfn from pg_proc
   where oid = to_regprocedure('public.add_customer_spec_version(text,text,uuid)');
  select count(*) into nrls from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relrowsecurity
     and c.relname in ('billing_details','extra_work_approvals','pricing_settings','consents');

  if nt <> f.tabeller then
    raise warning 'migration 29 SKAPADE % tabell(er) (% -> %). I produktion ska den siffran vara oforandrad.', nt - f.tabeller, f.tabeller, nt;
  end if;
  if nk <> f.kolumner then
    raise warning 'migration 29 LADE TILL % kolumn(er) (% -> %). I produktion ska den siffran vara oforandrad.', nk - f.kolumner, f.kolumner, nk;
  end if;
  if f.prisrader >= 0 and npr <> f.prisrader then
    raise warning 'migration 29 SATTE IN prisraden (% -> %). I produktion ska den redan finnas.', f.prisrader, npr;
  end if;
  -- ⚠️ `is not null` har (och `is null` i no-op-kvittot nedan) ar DEFENSIV SYMMETRI med
  -- fn_md5, inte ett verkligt NULL-fall: `count(*)` over en filtrerad join ger alltid en
  -- rad. Grinden ar alltsa inert. Den star kvar for att de fem jamforelserna ska se
  -- likadana ut, men las den inte som att ett NULL-fall ar hanterat — det finns inget.
  if f.rls_pa is not null and nrls <> f.rls_pa then
    raise warning 'migration 29 SLOG PA RLS pa % tabell(er) (% -> % av 4). I produktion ska alla fyra redan ha RLS. Kontrollera att de har policies - en tabell med RLS men utan SELECT-policy ar tyst for API:t.', nrls - f.rls_pa, f.rls_pa, nrls;
  end if;

  -- 🔴 EXCEPTION, inte warning (granskningsfynd 1 mot v3). Forkravet i sektion 5
  -- kontrollerar att DRIFT matchar den vantade md5:an — inte att FILEN gor det. Glider
  -- transkriberingen (dalig merge, editor som normaliserar blanktecken, nagon som "stadar"
  -- indenteringen) passerar forkravet, `create or replace` skriver den andrade kroppen, och
  -- det ar HAR det upptacks. Filen kor med `-1`, alltsa ar transaktionen fortfarande oppen:
  -- ett exception rullar tillbaka overskrivningen fullstandigt. Att i stallet varna och
  -- commita vore att lamna ifran sig en aterstallning som ligger en rad bort — och
  -- originalkroppen finns da bara som en 32 tecken lang hash.
  --
  -- ⚠️ De andra larmen i sektionen ska FORBLI varningar: tabeller, kolumner, prisraden och
  -- RLS ar additiva och FORVANTAS skilja sig i en ateruppbyggnad. Ett avbrott dar hade
  -- brutit rebuild-vagen igen. Md5-fallet ar av annan art: i en ateruppbyggnad ar f.fn_md5
  -- NULL och grenen hoppas over, sa detta exception kan inte traffa den vagen.
  if f.fn_md5 is not null and nfn is distinct from f.fn_md5 then
    raise exception 'migration 29 AVBRYTER: add_customer_spec_version andrades av den har filen (md5 % -> %). Forkravet i sektion 5 sag att DRIFT var orord, sa det ar FILENS kropp som glidit. Allt rullas tillbaka. Jamfor filen mot pg_get_functiondef innan du forsoker igen.', f.fn_md5, nfn;
  end if;

  if nt = f.tabeller and nk = f.kolumner and (f.prisrader < 0 or npr = f.prisrader)
     and (f.fn_md5 is null or nfn is not distinct from f.fn_md5)
     and (f.rls_pa is null or nrls = f.rls_pa) then
    raise notice 'migration 29: no-op bekraftad — inga tabeller, kolumner eller rader tillkom, RLS oforandrad, funktionen oforandrad. Policies larmar var for sig i sektion 3.';
  end if;
end $$;

drop table _f29_fore;

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
--
-- 6. ⚠️ TVA LITTERALER STAR PA TRE STALLEN VAR. Andrar du den ena men inte de andra far du
--    ett kontrollsteg som ljuger — precis det punkt 5 varnar for:
--      * signaturen 'public.add_customer_spec_version(text,text,uuid)'
--        (snapshot-blocket, forkravet i sektion 5, efterkontrollen i sektion 6)
--      * md5:an '9ebea1d75d0296e050f4ecdd13180e3c'
--        (kvittot i huvudet, forkravet i sektion 5, kommentaren ovanfor funktionskroppen)
--    Ren SQL har inga variabler att binda dem till. Andra alla tre, varje gang.
