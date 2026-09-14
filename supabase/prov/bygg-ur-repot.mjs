// Prov: gar portalens databas att bygga ur repot? (issue #60)
//
// Kor schema.sql och sedan migration-N-*.sql, i SAMMA ordning som kor-migrationer.yml i
// OakStride/oakstride-agent kor dem mot drift, mot en TOM PostgreSQL (PGlite - Postgres
// kompilerad till WebAssembly, i minnet i den har processen). Ingen tjanst, ingen port,
// drift kontaktas aldrig.
//
// Anvandning:  node bygg-ur-repot.mjs <supabase-mappen> [--naket]
//
//   standard  = Supabase-plattformen stubbad forst (auth, storage, rollerna). Det ar grinden.
//               Det som gar igenom bevisar att REPOTS sql ar korbar i foljd - inte att repot
//               racker utan plattformen. Stubbarna ar skrivna har, inte hamtade ur repot.
//   --naket   = ingenting forutsatt utover tom Postgres. Svarar pa en annan fraga och ar
//               inte grinden - den faller i dag, och det ar ett kant lage.
//
// VEM SOM KOR: PGlite startar som superuser. Drift gor det inte - migrationerna kors dar som
// rollen postgres, som ar NOSUPERUSER (matt 2026-09-14). Stubbarna skapas darfor som
// superuser, och varje fil kors sedan under `set session authorization` till en roll som
// efterliknar drifts postgres (se DRIFTROLL nedan). Efter varje sats kontrolleras att vi
// fortfarande ar den rollen och att is_superuser ar off - annars hade provet tyst kunnat
// falla tillbaka till superuser och godkant sadant som faller i drift. En medveten flykt
// inuti en DO-kropp som aterstaller sig sjalv fangas INTE (se rollbytet nedan och README).
//
// Exitkod 1 (underkant) om:
//   * nagon sats faller, utom exakt de satser som star i TILLATNA_FEL nedan,
//   * nagon stubbsats faller, eller rollbytet inte gar att bekrafta,
//   * schema.sql saknas eller ingen migrationsfil hittas,
//   * en fil ger noll satser (t.ex. tomd till en kommentar),
//   * en fil slutar inuti en blockkommentar, strang, citerad identifierare eller dollar-tagg,
//   * ett migrationsfilnamn inte foljer monstret kor-migrationer.yml kraver,
//   * en fil innehaller egen transaktionskontroll (se TRANSAKTION nedan),
//   * en sats byter roll eller blir superuser,
//   * nagot ovantat kastas.
// `raise warning` och `raise notice` skrivs ut men underkanner inte: migration 27 varnar
// legitimt om ensure_rls, som kraver superuser. En warning om ett verkligt problem blir
// alltsa gron har - precis som i drift.

import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import path from 'node:path';

const argv = process.argv.slice(2);
const NAKET = argv.includes('--naket');
const SQLDIR = argv.find(a => !a.startsWith('--'));
const I_ACTIONS = process.env.GITHUB_ACTIONS === 'true';

// Ett prov som inte provade nagot far inte bli gront. Allt som gar fel samlas har, och
// exitkoden avgors av den har listan och ingenting annat.
const underkant = [];

// GitHub-annotering. Filnamnet forst, sa att en text som sjalv innehaller :: aldrig
// hamnar i borjan av raden (Actions tolkar bara radens borjan som kommando).
function annotera(niva, fil, text) {
  const ren = String(text).replace(/\r?\n/g, ' ');
  if (I_ACTIONS) console.log(`::${niva}::${fil}: ${ren}`);
}

// ---------------------------------------------------------------------------- satsdelning
// Respekterar '...', "...", $tag$...$tag$, -- rad och /* block */. En naiv split pa ';'
// hade delat mitt i varje funktionskropp.
// Returnerar ocksa `oavslutat`: slutar filen inuti en blockkommentar, strang, citerad
// identifierare eller dollar-tagg ar resten av filen uppslukad - en glomd */ gor annars
// allt efter den till kommentar, som sedan filtreras bort, och provet blir gront pa en fil
// som i praktiken ar tom.
// Lexikala regler som PostgreSQL:s egen lexer, for det som avgor var en sats slutar:
//   * '...'   vanlig strang. standard_conforming_strings ar pa (default sedan PG 9.1), sa
//             bakstreck ar ett vanligt tecken; '' ar en apostrof.
//   * E'...'  escape-strang (E eller e direkt fore apostrofen, och inte sist i ett langre
//             ord). Bakstreck escapar nasta tecken, sa bakstreck+apostrof avslutar INTE
//             strangen. Utan den regeln slogs flera satser ihop till en bit - och en bit som
//             borjar som en supautils-policy kordes da hel som superuser.
//   * "..."   citerad identifierare; "" ar ett citattecken.
//   * $tag$   dollar-citat. Inte direkt efter ett identifierartecken (a$b$ ar ett ord).
//   * /* */   blockkommentarer NASTLAR i PostgreSQL.
const ORDTECKEN = { test: ch => /[A-Za-z0-9_$]/.test(ch) || ch.charCodeAt(0) >= 128 };
// Returnerar index direkt efter det citerade/kommenterade som borjar pa i, -1 om det aldrig
// avslutas, eller null om inget sadant borjar pa i.
function hoppaOver(sql, i) {
  const c = sql[i];
  if (c === '-' && sql[i + 1] === '-') {
    const n = sql.indexOf('\n', i);
    return n === -1 ? sql.length : n + 1;
  }
  if (c === '/' && sql[i + 1] === '*') {
    let djup = 1, j = i + 2;
    while (j < sql.length) {
      if (sql[j] === '/' && sql[j + 1] === '*') { djup++; j += 2; continue; }
      if (sql[j] === '*' && sql[j + 1] === '/') { djup--; j += 2; if (djup === 0) return j; continue; }
      j++;
    }
    return -1;
  }
  if (c === "'" || c === '"') {
    const escape = c === "'" && i > 0 && (sql[i - 1] === 'E' || sql[i - 1] === 'e') &&
      !(i > 1 && ORDTECKEN.test(sql[i - 2]));
    let j = i + 1;
    while (j < sql.length) {
      if (escape && sql[j] === '\\') { j += 2; continue; }
      if (sql[j] === c && sql[j + 1] === c) { j += 2; continue; }
      if (sql[j] === c) return j + 1;
      j++;
    }
    return -1;
  }
  if (c === '$' && !(i > 0 && ORDTECKEN.test(sql[i - 1]))) {
    const m = /^\$[A-Za-z_][A-Za-z_0-9]*\$|^\$\$/.exec(sql.slice(i));
    if (m) {
      const n = sql.indexOf(m[0], i + m[0].length);
      return n === -1 ? -1 : n + m[0].length;
    }
  }
  return null;
}
function vadBorjar(sql, i) {
  const c = sql[i];
  if (c === '/') return 'blockkommentar /*';
  if (c === '"') return 'citerad identifierare "';
  if (c === "'") return 'strang \'';
  return `dollar-tagg ${/^\$[A-Za-z_0-9]*\$/.exec(sql.slice(i))?.[0] ?? '$'}`;
}

function delaSatser(sql) {
  const ut = [];
  let i = 0, start = 0, oavslutat = null;
  const rad = pos => sql.slice(0, pos).split('\n').length;
  while (i < sql.length) {
    const c = sql[i];
    const hopp = hoppaOver(sql, i);
    if (hopp === -1) { oavslutat = `${vadBorjar(sql, i)} fran rad ${rad(i)} avslutas aldrig`; i = sql.length; break; }
    if (hopp !== null) { i = hopp; continue; }
    if (c === ';') {
      const s = sql.slice(start, i).trim();
      if (s) ut.push(s);
      i++; start = i;
      continue;
    }
    i++;
  }
  const rest = sql.slice(start).trim();
  if (rest) ut.push(rest);
  // En "sats" som bara bestar av kommentarer ar ingen sats.
  return { satser: ut.filter(s => utanKommentarer(s) !== ''), oavslutat };
}

// Tar bort -- och /* */ utanfor strangar, och normaliserar blanksteg. Anvands for att
// jamfora en sats mot tillatelselistan och for att kanna igen transaktionskontroll.
function utanKommentarer(s) {
  let ut = '', i = 0;
  while (i < s.length) {
    const hopp = hoppaOver(s, i);
    if (hopp === null) { ut += s[i]; i++; continue; }
    const slut = hopp === -1 ? s.length : hopp;
    const kommentar = (s[i] === '-' && s[i + 1] === '-') || (s[i] === '/' && s[i + 1] === '*');
    ut += kommentar ? ' ' : s.slice(i, slut);
    i = slut;
  }
  return ut.replace(/\s+/g, ' ').trim();
}

// ----------------------------------------------------------------------- tillatna fel
// UTTRYCKLIG, NAMNGIVEN lista. Matchar pa HELA satsen (gemener, kommentarer bort,
// blanksteg normaliserade) - aldrig pa felmeddelandet. Ett generellt monster som
// "extension ... finns inte" hade slappt igenom varje framtida extension-fel.
// Bara EXAKT den sats som star i schema.sql. `create extension pg_net` utan if not exists
// finns inte har med flit: den faller i drift, dar pg_net redan finns.
const TILLATNA_FEL = [
  {
    sats: 'create extension if not exists pg_net',
    skal: 'pg_net finns inte i PGlite. Det ar provmiljons brist, inte repots - pa Supabase finns den.',
  },
];
function tillatet(sats) {
  const norm = utanKommentarer(sats).toLowerCase();
  return TILLATNA_FEL.find(t => t.sats === norm) || null;
}

// ---------------------------------------------------------------------- transaktion
// kor-migrationer.yml kor varje fil med `psql -1` = hela filen i EN transaktion. Provet
// gor detsamma: BEGIN per fil, en SAVEPOINT per sats. Sa lever transaktionsbundna fel
// kvar (t.ex. ett nytt enum-varde som anvands i samma transaktion, eller CREATE INDEX
// CONCURRENTLY), samtidigt som ett fel i sats 3 inte doljer sats 4-17.
// En fil med EGEN transaktionskontroll gar inte att prova troget pa det sattet - dess
// COMMIT hade brutit savepoint-kedjan och provet hade svarat pa en annan fraga. Da
// underkanns den i stallet for att tyst ge ett missvisande svar.
const TRANSAKTIONSKONTROLL = /^(begin|commit|end|rollback|abort|start transaction|savepoint|release)\b/i;

// ------------------------------------------------------------------------- filordning
// Exakt samma ordning som kor-migrationer.yml:
//   ls portal/supabase/migration-*.sql | sed -E 's|.*/migration-([0-9]+)-|\1\t&|' | sort -n | cut -f2-
// = numeriskt pa migrationsnumret; lika nummer faller tillbaka pa hela raden, i praktiken
// filnamnet bytevis. Och samma namnkontroll: ett namn utanfor monstret avbryter drift-
// korningen, sa det ska falla har ocksa - pa PR:en, inte efter merge.
// schema.sql kors forst. Den kors inte av kor-migrationer.yml (drift byggdes med den for
// hand), men utan den finns inga tabeller for migrationerna att andra.
const NAMNMONSTER = /^migration-[0-9]+-[a-z0-9-]+\.sql$/;
function filordning() {
  if (!SQLDIR || !existsSync(SQLDIR)) {
    underkant.push(`SQL-mappen finns inte: ${SQLDIR ?? '(ingen angiven)'}`);
    return [];
  }
  const alla = readdirSync(SQLDIR);
  const migr = alla.filter(f => f.startsWith('migration-') && f.endsWith('.sql'));
  for (const f of migr) {
    if (!NAMNMONSTER.test(f)) {
      underkant.push(`Ovantat migrationsfilnamn '${f}' - kor-migrationer.yml avbryter pa det. Monster: migration-<siffror>-<gemener-och-bindestreck>.sql`);
    }
  }
  const nummer = f => { const m = /^migration-([0-9]+)-/.exec(f); return m ? Number(m[1]) : 0; };
  const sorterade = migr.filter(f => NAMNMONSTER.test(f)).sort((a, b) => {
    const d = nummer(a) - nummer(b);
    if (d !== 0) return d;
    return a < b ? -1 : a > b ? 1 : 0;
  });
  if (sorterade.length === 0) underkant.push('Ingen migrationsfil hittades. Ett prov som inte provade nagot ar inte gront.');
  const ut = [];
  if (alla.includes('schema.sql')) ut.push('schema.sql');
  else underkant.push('schema.sql saknas.');
  return ut.concat(sorterade);
}

// ---------------------------------------------------------------------------- stubbar
// VARA EGNA, inte hamtade ur repot. De ersatter det Supabase-plattformen har pa plats innan
// en enda av repots filer kors. Att repot gar igenom med dem bevisar alltsa inte att repot
// racker utan plattformen. Skapas som SUPERUSER, som plattformen gor.
const STUBBAR = `
create schema if not exists auth;
create schema if not exists storage;
create schema if not exists extensions;
create schema if not exists net;
do $x$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
  if not exists (select 1 from pg_roles where rolname='supabase_auth_admin') then create role supabase_auth_admin nologin; end if;
  if not exists (select 1 from pg_roles where rolname='supabase_storage_admin') then create role supabase_storage_admin nologin; end if;
end $x$;
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);
create or replace function auth.uid() returns uuid language sql stable as $x$ select null::uuid $x$;
create or replace function auth.role() returns text language sql stable as $x$ select null::text $x$;
create or replace function auth.email() returns text language sql stable as $x$ select null::text $x$;
create or replace function auth.jwt() returns jsonb language sql stable as $x$ select '{}'::jsonb $x$;
create table if not exists storage.buckets (
  id text primary key, name text, public boolean default false, created_at timestamptz default now()
);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text, owner uuid, created_at timestamptz default now(), metadata jsonb
);
create or replace function storage.foldername(name text) returns text[]
  language sql immutable as $x$ select string_to_array(name, '/') $x$;
create or replace function storage.filename(name text) returns text
  language sql immutable as $x$ select (string_to_array(name, '/'))[array_length(string_to_array(name,'/'),1)] $x$;
create or replace function storage.extension(name text) returns text
  language sql immutable as $x$ select nullif(split_part(name, '.', 2), '') $x$;
`;

// ------------------------------------------------------------------------- driftroll
// Efterliknar rollen postgres i drift, matt 2026-09-14:
//   rolsuper=false, rolcreaterole=true, rolcreatedb=true, rolbypassrls=true, rolreplication=true
//   medlem i anon, authenticated, service_role (m.fl.)
//   schemat public ags av pg_database_owner; databasen ags av postgres; tabeller och
//   funktioner i public ags av postgres.
// Varje rattighet utover attributen star har med sitt skal. En rattighet som bara finns for
// att fa gront, utan motivering mot drift, hor inte hemma har.
const DRIFTROLL = 'prov_drift_postgres';
const DRIFTROLL_SQL = `
create role ${DRIFTROLL} nosuperuser createrole createdb bypassrls replication nologin;
-- Drift: databasen ags av postgres och schemat public av pg_database_owner (bada matta
-- 2026-09-14). Databasagaren ar implicit medlem i pg_database_owner och kan darfor skapa i
-- public. Samma mekanism har: provrollen far aga databasen. Utan raden faller forsta
-- create table i schema.sql.
alter database postgres owner to ${DRIFTROLL};
`;
const DRIFTROLL_STUBB_SQL = `
-- Drift: postgres ar medlem i anon, authenticated och service_role (matt 2026-09-14).
-- Behovs for att postgres ska kunna ge rattigheter till och agera som dem.
grant anon, authenticated, service_role to ${DRIFTROLL};

-- Agare som i Supabase: auth.users ags av supabase_auth_admin (supabase/postgres
-- init-scripts/00000000000001-auth-schema.sql).
alter table auth.users owner to supabase_auth_admin;

-- Drift: storage.objects ags av supabase_storage_admin, och postgres ar INTE medlem i den
-- rollen (pg_has_role(...,'MEMBER') = false, matt 2026-09-14). Samma har: provrollen far
-- inte grant supabase_storage_admin. Att migration 19 anda kan skapa policies pa
-- storage.objects i drift beror pa supautils - se SUPAUTILS_TABELLER nedan.
alter table storage.buckets owner to supabase_storage_admin;
alter table storage.objects owner to supabase_storage_admin;

-- Tabellrattigheterna ar MATTA I DRIFT 2026-09-14 (has_table_privilege, alla sju: SELECT,
-- INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER) for postgres pa auth.users,
-- storage.objects, storage.buckets och ovriga auth- och storage-tabeller. Undantagen i drift
-- - auth.schema_migrations, storage.migrations, storage.buckets_vectors och
-- storage.vector_indexes, som bara har SELECT - finns inte i stubben. Samma rattigheter
-- delas ut av Supabases egna skript: supabase/postgres 10000000000000_demote-postgres.sql
-- och supabase/storage migrations/tenant/0046 och 0049.
-- Repot behover dem for: foreign key mot auth.users (REFERENCES) och triggern
-- on_auth_user_created pa auth.users (TRIGGER) i schema.sql, samt insert i storage.buckets
-- i migration 19. TRIGGER pa storage.objects innebar att "create trigger ... on
-- storage.objects" gar igenom har - som i drift.
grant all on schema auth, extensions, storage to ${DRIFTROLL};
grant all on all tables in schema auth, extensions, storage to ${DRIFTROLL};
grant all on all sequences in schema auth, extensions, storage to ${DRIFTROLL};
grant all on all routines in schema auth, extensions, storage to ${DRIFTROLL};
`;

// ------------------------------------------------------------------- supautils-grants
// Drift har tillagget supautils, som later postgres skapa, andra och ta bort POLICY - och ta
// bort TRIGGER - pa vissa plattformstabeller utan att aga dem. Listan ar ORDAGRANT
// installningarna supautils.policy_grants och supautils.drop_trigger_grants for "postgres",
// matta i drift 2026-09-14 (de tva listorna var identiska). Allt ANNAT mot tabellerna -
// alter table ... add column, create trigger, enable rls - faller i drift, och ska falla har.
//
// Efterlikningen: en sats vars form sakert ar create/alter/drop policy ... on <schema>.<tabell>
// (eller drop trigger ... on <schema>.<tabell>) med tabellen i listan kors av skriptet som
// superuser (set session authorization), och rollen sats tillbaka direkt efter, aven om
// satsen faller. Satsen kors med db.query, som vagrar mer an ett kommando per anrop.
// Tolkningen ar KONSERVATIV: tabellen maste vara schemakvalificerad och satsen maste matcha
// formen exakt. Kan den inte avgoras kors satsen som provrollen - ett onodigt rott ar battre
// an ett falskt gront.
const SUPAUTILS_TABELLER = [
  'auth.audit_log_entries', 'auth.flow_state', 'auth.identities', 'auth.instances',
  'auth.mfa_amr_claims', 'auth.mfa_challenges', 'auth.mfa_factors', 'auth.oauth_clients',
  'auth.one_time_tokens', 'auth.refresh_tokens', 'auth.saml_providers', 'auth.saml_relay_states',
  'auth.sessions', 'auth.sso_domains', 'auth.sso_providers', 'auth.users',
  'realtime.messages', 'realtime.subscription',
  'storage.buckets', 'storage.buckets_analytics', 'storage.objects', 'storage.prefixes',
  'storage.s3_multipart_uploads', 'storage.s3_multipart_uploads_parts',
];
const POLICY_GRANTS = new Set(SUPAUTILS_TABELLER);
const DROP_TRIGGER_GRANTS = new Set(SUPAUTILS_TABELLER);

const IDENT = String.raw`(?:"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_$]*)`;
const POLICY_FORM = new RegExp(String.raw`^(?:create|alter|drop)\s+policy\s+(?:if\s+exists\s+)?${IDENT}\s+on\s+(${IDENT})\s*\.\s*(${IDENT})(?:\s|$)`, 'i');
const DROP_TRIGGER_FORM = new RegExp(String.raw`^drop\s+trigger\s+(?:if\s+exists\s+)?${IDENT}\s+on\s+(${IDENT})\s*\.\s*(${IDENT})(?:\s+(?:cascade|restrict))?$`, 'i');
function namn(id) {
  return id.startsWith('"') ? id.slice(1, -1).replace(/""/g, '"') : id.toLowerCase();
}
// Returnerar tabellen om satsen far koras med supautils-rattighet, annars null.
function supautilsGrant(sats) {
  const norm = utanKommentarer(sats);
  let m = POLICY_FORM.exec(norm);
  if (m) { const t = `${namn(m[1])}.${namn(m[2])}`; return POLICY_GRANTS.has(t) ? t : null; }
  m = DROP_TRIGGER_FORM.exec(norm);
  if (m) { const t = `${namn(m[1])}.${namn(m[2])}`; return DROP_TRIGGER_GRANTS.has(t) ? t : null; }
  return null;
}

// ----------------------------------------------------------------- inventering (drift)
// SAMMA uttryck som receptets drift-SQL i det som raknas och sorteras, sa att en manniska kan
// kora README:s version mot drift och jamfora raderna. Har ar funktioner och katalogtabeller
// schemakvalificerade (pg_catalog.) - det andrar inte resultatet, bara att en migration inte
// kan skugga dem. Jamforelsen gors INTE har.
const SQL_OBJEKT = `select pg_catalog.count(*)::int as antal, pg_catalog.md5(pg_catalog.string_agg(x, '|' order by x collate "C")) as md5 from (
  select 'F '||p.proname||'('||pg_catalog.pg_get_function_identity_arguments(p.oid)||')' as x
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  union all select 'P '||schemaname||'.'||tablename||'.'||policyname
    from pg_catalog.pg_policies where schemaname in ('public','storage')
  union all select 'T '||c.relname||'.'||tgname
    from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid
    join pg_catalog.pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal and n.nspname='public'
) a`;
const SQL_KOLUMNER = `select pg_catalog.count(*)::int as antal, pg_catalog.md5(pg_catalog.string_agg(x, '|' order by x collate "C")) as md5 from (
  select table_name||'.'||column_name||' '||data_type||' '||is_nullable as x
    from information_schema.columns
   where table_schema='public' and table_name <> 'applied_migrations') a`;

// -------------------------------------------------------------------------------- kor
// Vaktfragan. Allt schemakvalificerat, aven operatorn: en migration kan skapa
// public.current_setting(text) och satta search_path = public, pg_catalog, och en
// okvalificerad fraga hade da kunnat svara 'off'. session_user och current_user ar SQL-
// nyckelord och gar inte att skugga. rolsuper mats dessutom oberoende av GUC:en.
async function vemArJag(db) {
  return (await db.query(`select session_user as s, current_user as u,
      pg_catalog.current_setting('is_superuser') as su,
      (select r.rolsuper from pg_catalog.pg_roles r where r.rolname OPERATOR(pg_catalog.=) current_user) as rs`)).rows[0];
}
const arDriftrollen = v => v.s === DRIFTROLL && v.u === DRIFTROLL && v.su === 'off' && v.rs === false;

async function kor() {
  const filer = filordning();
  if (underkant.length) return null;

  const db = await PGlite.create();

  // onNotice ar en PER-FRAGA-option i PGlite, inte en konstruktoroption. Pa konstruktorn
  // tystnar varje raise warning UTAN felmeddelande - en rapport som saknar precis det falt
  // den skulle larma om. Rattas inte "for enkelhets skull".
  const notiser = [];
  const onNotice = n => notiser.push({ niva: n.severity, text: n.message });

  // Plattformen: som superuser.
  const plattform = (NAKET ? '' : STUBBAR) + DRIFTROLL_SQL + (NAKET ? '' : DRIFTROLL_STUBB_SQL);
  for (const s of delaSatser(plattform).satser) {
    try { await db.exec(s, { onNotice }); }
    catch (e) { underkant.push(`Plattformssats föll: ${utanKommentarer(s).slice(0, 80)} -> ${e.message}`); }
  }
  notiser.splice(0);
  if (underkant.length) return null;

  // Byt till driftrollen och BEKRAFTA det. Ett rollbyte som inte gick igenom hade annars
  // latit hela provet kora som superuser utan att nagot sa till.
  //
  // SET SESSION AUTHORIZATION, inte SET ROLE. Med set role ar sessionsanvandaren kvar som
  // superuser, och en `reset role` - aven inuti en DO-kropp - gor en till superuser igen.
  // Efter set session authorization ar aven sessionsanvandaren driftrollen, och reset role
  // leder tillbaka till den. PGlite kan inte starta med en annan sessionsanvandare: optionen
  // `username` gor bara SET ROLE (matt 2026-09-14: session_user forblev postgres).
  // KVARSTAENDE LUCKA: den AUTENTISERADE anvandaren ar fortfarande superuser, sa en medveten
  // `set session authorization <superuser>` inuti en DO-kropp som sedan byter tillbaka fangas
  // inte - vakten mater bara efter satsen. Se README.
  const SUPERUSER = (await db.query('select session_user as s')).rows[0].s;
  await db.exec(`set session authorization ${DRIFTROLL}`);
  const jag = await vemArJag(db);
  if (!arDriftrollen(jag)) {
    underkant.push(`Rollbytet gick inte att bekrafta: ${JSON.stringify(jag)}`);
    return null;
  }

  console.log(`Läge: ${NAKET ? 'naket (inte grinden)' : 'stubbar (grinden)'}`);
  console.log(`PostgreSQL: ${(await db.query('select version() as v')).rows[0].v}`);
  console.log(`Kör som: session_user=${jag.s}, current_user=${jag.u} (is_superuser=${jag.su}, rolsuper=${jag.rs})`);
  console.log(`Ordning (${filer.length} filer): ${filer.join(', ')}\n`);

  let totalt = 0, gronaTotalt = 0, tillatnaTotalt = 0, supautilsSatser = 0;
  for (const f of filer) {
    const { satser, oavslutat } = delaSatser(readFileSync(path.join(SQLDIR, f), 'utf8'));
    let grona = 0;
    const fel = [], tillatna = [], medGrant = [];
    if (oavslutat) fel.push({ nr: 'filslut', kort: '(hela filen)', fel: oavslutat });
    if (satser.length === 0) fel.push({ nr: '-', kort: '(hela filen)', fel: 'filen ger noll satser - ett prov som inte provade nagot ar inte gront' });

    // Drift kor varje fil i en egen psql-session. En `set search_path` eller annan
    // installning i en fil ska darfor inte folja med till nasta. RESET ALL ror inte
    // session authorization.
    await db.exec('reset all');
    await db.exec('begin');
    for (const [idx, s] of satser.entries()) {
      const nr = idx + 1;
      const kort = utanKommentarer(s).slice(0, 110);
      totalt++;
      if (TRANSAKTIONSKONTROLL.test(utanKommentarer(s))) {
        fel.push({ nr, kort, fel: 'egen transaktionskontroll i filen - kor-migrationer.yml kor filen med psql -1 och provet kan inte efterlikna det troget' });
        continue;
      }
      // Skriptets EGEN rollvaxling for supautils-satser. Tillbaka till provrollen direkt efter
      // satsen, fore vakten - sa att vakten bara kan se en vaxling som filen sjalv gjort.
      const grant = NAKET ? null : supautilsGrant(s);
      if (grant) { supautilsSatser++; medGrant.push(`sats ${nr} (${grant})`); }
      await db.exec('savepoint sats');
      try {
        if (grant) {
          await db.exec(`set session authorization ${SUPERUSER}`);
          try {
            // db.query = extended protocol, som VAGRAR mer an ett kommando i ett anrop
            // ("cannot insert multiple commands into a prepared statement"). Har delaren
            // nagonsin slagit ihop tva satser till en bit kors alltsa ingenting som superuser.
            await db.query(s, [], { onNotice });
          } finally {
            // Faller satsen ar transaktionen avbruten och kommandot gar inte - da aterstaller
            // rollback to savepoint rollen, och bytet kors igen efter den nedan.
            try { await db.exec(`set session authorization ${DRIFTROLL}`); } catch { /* se ovan */ }
          }
        } else {
          await db.exec(s, { onNotice });
        }
        await db.exec('release savepoint sats');
        grona++;
      } catch (e) {
        await db.exec('rollback to savepoint sats');
        await db.exec('release savepoint sats');
        if (grant) await db.exec(`set session authorization ${DRIFTROLL}`);
        const t = tillatet(s);
        if (t) tillatna.push({ nr, kort, fel: e.message.split('\n')[0], skal: t.skal });
        else fel.push({ nr, kort, fel: e.message.split('\n')[0] });
      }
      // Vakten: efter VARJE sats ska vi fortfarande vara driftrollen, utan superuser.
      const v = await vemArJag(db);
      if (!arDriftrollen(v)) {
        fel.push({ nr, kort, fel: `satsen lamnade provet som session_user=${v.s}, current_user=${v.u}, is_superuser=${v.su}, rolsuper=${v.rs} - drift kor aldrig som superuser` });
        await db.exec(`set session authorization ${SUPERUSER}`);
        await db.exec(`set session authorization ${DRIFTROLL}`);
      }
    }
    // COMMIT kan sjalv falla (t.ex. uppskjutna constraints). Det ar ett fel i filen.
    try { await db.exec('commit'); }
    catch (e) { fel.push({ nr: 'COMMIT', kort: '(filens transaktion)', fel: e.message.split('\n')[0] }); }

    gronaTotalt += grona;
    tillatnaTotalt += tillatna.length;
    const flagga = fel.length ? 'FEL ' : tillatna.length ? 'OK* ' : 'OK  ';
    console.log(`${flagga} ${f.padEnd(44)} satser ${String(satser.length).padStart(3)}  gröna ${String(grona).padStart(3)}  fel ${fel.length}${tillatna.length ? `  tillåtna fel ${tillatna.length}` : ''}`);
    for (const x of fel) {
      console.log(`       FEL sats ${x.nr}: ${x.fel}\n           ${x.kort}`);
      annotera('error', f, `sats ${x.nr}: ${x.fel} -- ${x.kort}`);
      underkant.push(`${f} sats ${x.nr}: ${x.fel}`);
    }
    if (medGrant.length) console.log(`       supautils-grant (körd som superuser, som i drift): ${medGrant.join(', ')}`);
    for (const x of tillatna) {
      console.log(`       tillåtet fel sats ${x.nr}: ${x.fel}\n           ${x.kort}\n           skäl: ${x.skal}`);
    }
    for (const n of notiser.splice(0)) {
      console.log(`       ${n.niva}: ${n.text}`);
      if (/^WARNING$/i.test(n.niva)) annotera('warning', f, n.text);
    }
  }

  if (totalt === 0) underkant.push('Noll satser kordes. Ett prov som inte provade nagot ar inte gront.');

  // Inventeringen som superuser, med search_path = bara pg_catalog, sa att ingen funktion
  // eller operator som en migration lagt i public kan skugga det som raknas. Funktionerna ar
  // dessutom schemakvalificerade.
  await db.exec(`set session authorization ${SUPERUSER}`);
  await db.exec('reset all');
  await db.exec('set search_path to pg_catalog');
  const antal = async q => (await db.query(q)).rows[0].n;
  const inv = {
    funktioner_public: await antal(`select pg_catalog.count(*)::int as n from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public'`),
    policies_public_storage: await antal(`select pg_catalog.count(*)::int as n from pg_catalog.pg_policies where schemaname in ('public','storage')`),
    triggers_public: await antal(`select pg_catalog.count(*)::int as n from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal and n.nspname='public'`),
    kolumner_public: await antal(`select pg_catalog.count(*)::int as n from information_schema.columns where table_schema='public' and table_name <> 'applied_migrations'`),
    event_triggers: await antal(`select pg_catalog.count(*)::int as n from pg_catalog.pg_event_trigger`),
  };
  const objekt = (await db.query(SQL_OBJEKT)).rows[0];
  const kolumner = (await db.query(SQL_KOLUMNER)).rows[0];

  console.log('\n=== SUMMERING ===');
  console.log(`filer ${filer.length} · satser ${totalt} · gröna ${gronaTotalt} · tillåtna fel ${tillatnaTotalt} · fel ${totalt - gronaTotalt - tillatnaTotalt} · körda med supautils-grant ${supautilsSatser}`);
  console.log('\n=== INVENTERING (jämför mot drift för hand, se README.md) ===');
  console.log(`funktioner i public:           ${inv.funktioner_public}`);
  console.log(`policies i public+storage:     ${inv.policies_public_storage}`);
  console.log(`triggers i public:             ${inv.triggers_public}`);
  console.log(`kolumner i public:             ${inv.kolumner_public}`);
  console.log(`event triggers:                ${inv.event_triggers}`);
  console.log(`objektlistan (F+P+T):          ${objekt.antal} objekt, md5 ${objekt.md5}`);
  console.log(`kolumnlistan:                  ${kolumner.antal} kolumner, md5 ${kolumner.md5}`);
  await db.close();
  return true;
}

try {
  await kor();
} catch (e) {
  underkant.push(`Ovantat fel i provet: ${e && e.stack ? e.stack : e}`);
}

if (underkant.length) {
  console.log(`\nUNDERKÄNT (${underkant.length}):`);
  for (const u of underkant) {
    console.log(`  - ${u}`);
  }
  if (I_ACTIONS) console.log(`::error::bygg-ur-repot: underkant, ${underkant.length} fel - se loggen ovan.`);
  process.exitCode = 1;
} else {
  console.log('\nGODKÄNT: varje sats gick igenom, utom de uttryckligen tillåtna.');
  process.exitCode = 0;
}
