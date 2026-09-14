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
// Exitkod 1 (underkant) om:
//   * nagon sats faller, utom de uttryckligen tillatna i TILLATNA_FEL nedan,
//   * nagon stubbsats faller,
//   * schema.sql saknas, ingen migrationsfil hittas, eller noll satser kordes,
//   * ett migrationsfilnamn inte foljer monstret kor-migrationer.yml kraver,
//   * en fil innehaller egen transaktionskontroll (se TRANSAKTION nedan),
//   * nagot ovantat kastas.
// `raise warning` och `raise notice` skrivs ut men underkanner inte: migration 27 varnar
// legitimt om ensure_rls, som kraver superuser.

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
function delaSatser(sql) {
  const ut = [];
  let i = 0, start = 0;
  while (i < sql.length) {
    const c = sql[i];
    if (c === '-' && sql[i + 1] === '-') {
      const n = sql.indexOf('\n', i);
      i = n === -1 ? sql.length : n + 1;
      continue;
    }
    if (c === '/' && sql[i + 1] === '*') {
      const n = sql.indexOf('*/', i + 2);
      i = n === -1 ? sql.length : n + 2;
      continue;
    }
    if (c === "'" || c === '"') {
      const q = c;
      i++;
      while (i < sql.length) {
        if (sql[i] === q && sql[i + 1] === q) { i += 2; continue; }
        if (sql[i] === q) { i++; break; }
        i++;
      }
      continue;
    }
    if (c === '$') {
      const m = /^\$[A-Za-z_][A-Za-z_0-9]*\$|^\$\$/.exec(sql.slice(i));
      if (m) {
        const tag = m[0];
        const n = sql.indexOf(tag, i + tag.length);
        i = n === -1 ? sql.length : n + tag.length;
        continue;
      }
    }
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
  return ut.filter(s => utanKommentarer(s) !== '');
}

// Tar bort -- och /* */ utanfor strangar, och normaliserar blanksteg. Anvands for att
// jamfora en sats mot tillatelselistan och for att kanna igen transaktionskontroll.
function utanKommentarer(s) {
  let ut = '', i = 0;
  while (i < s.length) {
    if (s[i] === '-' && s[i + 1] === '-') { const n = s.indexOf('\n', i); i = n === -1 ? s.length : n + 1; ut += ' '; continue; }
    if (s[i] === '/' && s[i + 1] === '*') { const n = s.indexOf('*/', i + 2); i = n === -1 ? s.length : n + 2; ut += ' '; continue; }
    if (s[i] === "'" || s[i] === '"') {
      const q = s[i]; let j = i + 1;
      while (j < s.length) { if (s[j] === q && s[j + 1] === q) { j += 2; continue; } if (s[j] === q) { j++; break; } j++; }
      ut += s.slice(i, j); i = j; continue;
    }
    ut += s[i]; i++;
  }
  return ut.replace(/\s+/g, ' ').trim();
}

// ----------------------------------------------------------------------- tillatna fel
// UTTRYCKLIG, NAMNGIVEN lista. Matchar pa HELA satsen (gemener, kommentarer bort,
// blanksteg normaliserade) - aldrig pa felmeddelandet. Ett generellt monster som
// "extension ... finns inte" hade slappt igenom varje framtida extension-fel.
const TILLATNA_FEL = [
  {
    sats: 'create extension if not exists pg_net',
    skal: 'pg_net finns inte i PGlite. Det ar provmiljons brist, inte repots - pa Supabase finns den.',
  },
  {
    sats: 'create extension pg_net',
    skal: 'Samma som ovan, utan if not exists.',
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
// racker utan plattformen.
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

// ----------------------------------------------------------------- inventering (drift)
// SAMMA uttryck som receptets drift-SQL, tecken for tecken i det som raknas och sorteras,
// sa att en manniska kan kora dem mot drift och jamfora raderna. Jamforelsen gors INTE har.
const SQL_OBJEKT = `select count(*)::int as antal, md5(string_agg(x, '|' order by x collate "C")) as md5 from (
  select 'F '||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' as x
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  union all select 'P '||schemaname||'.'||tablename||'.'||policyname
    from pg_policies where schemaname in ('public','storage')
  union all select 'T '||c.relname||'.'||tgname
    from pg_trigger t join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal and n.nspname='public'
) a`;
const SQL_KOLUMNER = `select count(*)::int as antal, md5(string_agg(x, '|' order by x collate "C")) as md5 from (
  select table_name||'.'||column_name||' '||data_type||' '||is_nullable as x
    from information_schema.columns
   where table_schema='public' and table_name <> 'applied_migrations') a`;

// -------------------------------------------------------------------------------- kor
async function kor() {
  const filer = filordning();
  if (underkant.length) return null;

  const db = await PGlite.create();

  // onNotice ar en PER-FRAGA-option i PGlite, inte en konstruktoroption. Pa konstruktorn
  // tystnar varje raise warning UTAN felmeddelande - en rapport som saknar precis det falt
  // den skulle larma om. Rattas inte "for enkelhets skull".
  const notiser = [];
  const onNotice = n => notiser.push({ niva: n.severity, text: n.message });

  if (!NAKET) {
    for (const s of delaSatser(STUBBAR)) {
      try { await db.exec(s, { onNotice }); }
      catch (e) { underkant.push(`Stubbsats föll: ${utanKommentarer(s).slice(0, 80)} -> ${e.message}`); }
    }
    notiser.splice(0);
    if (underkant.length) return null;
  }

  console.log(`Läge: ${NAKET ? 'naket (inte grinden)' : 'stubbar (grinden)'}`);
  console.log(`PostgreSQL: ${(await db.query('select version() as v')).rows[0].v}`);
  console.log(`Ordning (${filer.length} filer): ${filer.join(', ')}\n`);

  let totalt = 0, gronaTotalt = 0, tillatnaTotalt = 0;
  for (const f of filer) {
    const satser = delaSatser(readFileSync(path.join(SQLDIR, f), 'utf8'));
    let grona = 0;
    const fel = [], tillatna = [];

    await db.exec('begin');
    for (const [idx, s] of satser.entries()) {
      const nr = idx + 1;
      const kort = utanKommentarer(s).slice(0, 110);
      totalt++;
      if (TRANSAKTIONSKONTROLL.test(utanKommentarer(s))) {
        fel.push({ nr, kort, fel: 'egen transaktionskontroll i filen - kor-migrationer.yml kor filen med psql -1 och provet kan inte efterlikna det troget' });
        continue;
      }
      await db.exec('savepoint sats');
      try {
        await db.exec(s, { onNotice });
        await db.exec('release savepoint sats');
        grona++;
      } catch (e) {
        await db.exec('rollback to savepoint sats');
        await db.exec('release savepoint sats');
        const t = tillatet(s);
        if (t) tillatna.push({ nr, kort, fel: e.message.split('\n')[0], skal: t.skal });
        else fel.push({ nr, kort, fel: e.message.split('\n')[0] });
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
    for (const x of tillatna) {
      console.log(`       tillåtet fel sats ${x.nr}: ${x.fel}\n           ${x.kort}\n           skäl: ${x.skal}`);
    }
    for (const n of notiser.splice(0)) {
      console.log(`       ${n.niva}: ${n.text}`);
      if (/^WARNING$/i.test(n.niva)) annotera('warning', f, n.text);
    }
  }

  if (totalt === 0) underkant.push('Noll satser kordes. Ett prov som inte provade nagot ar inte gront.');

  const antal = async q => (await db.query(q)).rows[0].n;
  const inv = {
    funktioner_public: await antal(`select count(*)::int as n from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'`),
    policies_public_storage: await antal(`select count(*)::int as n from pg_policies where schemaname in ('public','storage')`),
    triggers_public: await antal(`select count(*)::int as n from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal and n.nspname='public'`),
    kolumner_public: await antal(`select count(*)::int as n from information_schema.columns where table_schema='public' and table_name <> 'applied_migrations'`),
  };
  const objekt = (await db.query(SQL_OBJEKT)).rows[0];
  const kolumner = (await db.query(SQL_KOLUMNER)).rows[0];

  console.log('\n=== SUMMERING ===');
  console.log(`filer ${filer.length} · satser ${totalt} · gröna ${gronaTotalt} · tillåtna fel ${tillatnaTotalt} · fel ${totalt - gronaTotalt - tillatnaTotalt}`);
  console.log('\n=== INVENTERING (jämför mot drift för hand, se README.md) ===');
  console.log(`funktioner i public:           ${inv.funktioner_public}`);
  console.log(`policies i public+storage:     ${inv.policies_public_storage}`);
  console.log(`triggers i public:             ${inv.triggers_public}`);
  console.log(`kolumner i public:             ${inv.kolumner_public}`);
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
