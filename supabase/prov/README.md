# Prov: bygg databasen ur repot

Issue #60. Kör `supabase/schema.sql` och sedan `supabase/migration-N-*.sql` mot en **tom**
PostgreSQL och underkänner om någon sats faller. Körs av
`.github/workflows/prov-bygg-ur-repot.yml` (check-namn `bygg-databasen-ur-repot`) på **varje** PR
och push till `main` — utan `paths`-filter, se kommentaren i workflowfilen.

```bash
cd supabase/prov
npm ci
node bygg-ur-repot.mjs ..          # grinden: Supabase-plattformen stubbad
node bygg-ur-repot.mjs .. --naket  # ingenting stubbat - annan fråga, inte grinden, faller i dag
```

Databasen är [PGlite](https://pglite.dev) — PostgreSQL kompilerad till WebAssembly, i minnet i
node-processen. Ingen tjänst installeras, ingen port öppnas, drift kontaktas aldrig, inga secrets.

## Hur det körs

- **PostgreSQL 17, som drift.** PGlite är pinnad till `0.4.6`, som ger `PostgreSQL 17.5`
  (mätt med `select version()`). Drift kör 17.6. PGlite 0.5.x är PostgreSQL 18.3 och godkände
  PG18-syntax (t.ex. `generated always as (...) virtual`) som faller i drift — uppgradera inte
  PGlite förrän drift kör samma huvudversion.
- **Inte som superuser.** PGlite startar som superuser; drift kör migrationerna som `postgres`,
  som är `NOSUPERUSER CREATEROLE CREATEDB BYPASSRLS REPLICATION` (mätt 2026-09-14). Stubbarna
  skapas som superuser, sedan körs varje fil under `set role` till en roll med samma attribut.
  Efter **varje sats** kontrolleras att rollen är kvar och att `is_superuser` är `off`. Varje
  rättighet står med sitt skäl i skriptet (`DRIFTROLL_SQL`, `DRIFTROLL_STUBB_SQL`):
  - **Mätt i drift 2026-09-14:** attributen; medlemskap i `anon`/`authenticated`/`service_role`;
    rollen äger databasen (och kan därför skapa i `public`, som ägs av `pg_database_owner`);
    `auth.users` ägs av `supabase_auth_admin` och `storage.buckets`/`storage.objects` av
    `supabase_storage_admin`, som rollen **inte** är medlem i.
  - **Ur Supabases källkod, inte mätt:** `all` på schema, tabeller, sekvenser och rutiner i
    `auth`, `extensions`, `storage` (`demote-postgres.sql`), och `all` på `storage.buckets` och
    `storage.objects` (storage-api `0046`/`0049`). `all` innefattar `TRIGGER`, så
    `create trigger` på `storage.objects` blir grönt här — kontrollfrågan mot drift står i skriptet.
- **supautils efterliknas.** Drift låter `postgres` köra `create/alter/drop policy` och
  `drop trigger` på plattformstabeller den inte äger (`supautils.policy_grants` och
  `drop_trigger_grants`, mätta 2026-09-14; listan står i skriptet). En sats med exakt den
  formen, schemakvalificerad och mot en tabell i listan, körs av skriptet som superuser och
  rollen sätts tillbaka direkt efter, även om satsen faller. Allt annat mot de tabellerna —
  `alter table ... add column`, `enable row level security` — körs som rollen och faller, som i
  drift. Kan formen inte avgöras säkert körs satsen som rollen: hellre ett onödigt rött än ett
  falskt grönt. Loggen visar varje sats som fått grant. En `reset role` i själva filen fångas
  fortfarande av vakten.
- **Ordningen är drifts.** Samma sortering som `kor-migrationer.yml` i `OakStride/oakstride-agent`:
  numeriskt på migrationsnumret (annars kommer 10 före 2), och samma namnkontroll
  (`migration-<siffror>-<gemener-och-bindestreck>.sql`) — ett namn den avbryter på faller här
  också. `schema.sql` körs först; den körs inte av `kor-migrationer.yml`.
- **En transaktion per fil**, som `psql -1` i drift, men med en savepoint per sats. Då faller
  transaktionsbundna fel här precis som i drift (t.ex. ett nytt enum-värde som används i samma
  fil), samtidigt som ett fel i sats 3 inte döljer sats 4–17. En fil med egen
  `begin`/`commit` underkänns, eftersom provet då inte kan efterlikna drift troget.
- **En sats i taget.** Delaren respekterar `'…'`, `"…"`, `$tag$…$tag$`, `--` och `/* */`.
  Satser som bara består av kommentarer räknas inte. Slutar en fil inuti en oavslutad
  blockkommentar, sträng, citerad identifierare eller dollar-tagg underkänns filen — annars
  hade en glömd `*/` gjort resten av filen till en kommentar som tyst filtrerats bort.
- **`onNotice` sätts per fråga** (`db.exec(sql, { onNotice })`). På konstruktorn tystnar varje
  `raise warning` utan felmeddelande. Varningar skrivs ut och lyfts som `::warning::` men
  underkänner inte — migration 27 varnar legitimt om `ensure_rls`.
- **Tillåtna fel är en namngiven lista** i skriptet, matchad på hela satsen, aldrig på
  felmeddelandet. Den har exakt en post: `create extension if not exists pg_net`, precis som
  satsen står i `schema.sql` — pg_net finns inte i PGlite. `create extension pg_net` utan
  `if not exists` är **inte** tillåten: den faller i drift, där pg_net redan finns.

Underkänt (exit 1) också om `schema.sql` saknas, om ingen migrationsfil hittas, eller om **en
enskild fil** ger noll satser — ett prov som inte provade något är inte grönt.

## Vad ett grönt prov bevisar

Att repots SQL går att köra i följd, i drifts ordning, på en tom PostgreSQL 17 som en roll
utan superuser, **där Supabase-plattformen redan finns** — och inget mer.

## Vad det INTE bevisar

- **Inte att en merge stoppas.** `main` saknar grenskydd. Ett rött prov larmar på PR:en men
  hindrar ingen från att merga. Att göra provet till en obligatorisk check är Fredriks beslut.
- **Inte att repot räcker utan plattformen.** Stubbarna (`auth`-schemat, `auth.users`,
  `auth.uid()`, `storage`-schemat och dess funktioner, rollerna `anon`/`authenticated`/
  `service_role`) är **skrivna i skriptet, inte hämtade ur repot**. Utan dem faller provet
  (`--naket`). En riktig Supabase-instans har dem; en vanlig PostgreSQL har det inte.
- **Inte att rollen är exakt drifts.** Attribut, medlemskap, ägare och supautils-listan är
  mätta; tabellrättigheterna är hämtade ur Supabases källkod. En rättighet drift saknar men
  stubben har ger ett grönt prov på något som faller i drift.
- **Inte att funktionerna fungerar när de anropas.** PL/pgSQL-kroppar kontrolleras bara
  syntaktiskt när de skapas — en felstavad tabell i en funktion syns först vid anrop. Ingen
  funktion, trigger eller policy körs mot data här. `pg_net` och `vault` saknas helt, så inget
  som skickar webhooks eller läser hemligheter provas alls.
- **`ensure_rls` återskapas inte.** Event-triggern kräver superuser och skapas inte av någon
  fil; migration 27 varnar för det. En databas byggd ur repot saknar alltså skyddet att nya
  tabeller i `public` får RLS automatiskt.
- **En `raise warning` om ett verkligt problem blir grön** — här och i drift. Varningar
  underkänner aldrig; någon måste läsa dem.
- **Filer som inte heter `migration-*.sql` syns aldrig**, varken här eller i drift. En fil som
  heter `Migration-31-x.sql` (versal M) eller `migrering-31.sql` körs inte och ger inget fel.
- **Seed-radernas innehåll jämförs inte.** Provet ser att `insert`-satserna går igenom, inte
  att raderna blir desamma som i drift.
- **Ingen jämförelse mot drift görs automatiskt.** Sist skrivs en inventering ut (antal
  funktioner, policies, triggers, kolumner och event triggers, plus md5 på objekt- och
  kolumnlistan) med samma SQL-uttryck som används mot drift — men att köra dem mot drift och
  jämföra är en människas jobb. Ett grönt prov kan stå bredvid ett repo som saknar en kolumn
  drift har.
- **Inte exakt samma PostgreSQL som drift.** 17.5 här, 17.6 i drift, och PGlite saknar
  Supabases tillägg. Något som beror på mindre version eller tillägg kan skilja.
- **Inte att migrationerna fungerar mot drifts befintliga data** — bara mot en tom databas.

## Jämföra mot drift för hand

Kör uttrycken nedan mot drift och jämför mot raderna `objektlistan` och `kolumnlistan` i loggen.
Skiljer hashen: jämför per tabell först (`group by table_name`) för att hitta var.

```sql
select count(*), md5(string_agg(x, '|' order by x collate "C")) from (
  select 'F '||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' as x
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  union all select 'P '||schemaname||'.'||tablename||'.'||policyname
    from pg_policies where schemaname in ('public','storage')
  union all select 'T '||c.relname||'.'||tgname
    from pg_trigger t join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal and n.nspname='public'
) a;

select count(*), md5(string_agg(x, '|' order by x collate "C")) from (
  select table_name||'.'||column_name||' '||data_type||' '||is_nullable as x
    from information_schema.columns
   where table_schema='public' and table_name <> 'applied_migrations') a;
```
