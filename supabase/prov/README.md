# Prov: bygg databasen ur repot

Issue #60. Kör `supabase/schema.sql` och sedan `supabase/migration-N-*.sql` mot en **tom**
PostgreSQL och underkänner om någon sats faller. Körs av
`.github/workflows/prov-bygg-ur-repot.yml` på varje PR och push till `main` som rör `supabase/`.

```bash
cd supabase/prov
npm ci
node bygg-ur-repot.mjs ..          # grinden: Supabase-plattformen stubbad
node bygg-ur-repot.mjs .. --naket  # ingenting stubbat - annan fråga, inte grinden, faller i dag
```

Databasen är [PGlite](https://pglite.dev) — PostgreSQL kompilerad till WebAssembly, i minnet i
node-processen. Ingen tjänst installeras, ingen port öppnas, drift kontaktas aldrig, inga secrets.

## Hur det körs

- **Ordningen är drifts.** Samma sortering som `kor-migrationer.yml` i `OakStride/oakstride-agent`:
  numeriskt på migrationsnumret (annars kommer 10 före 2), och samma namnkontroll
  (`migration-<siffror>-<gemener-och-bindestreck>.sql`) — ett namn den avbryter på faller här
  också. `schema.sql` körs först; den körs inte av `kor-migrationer.yml`.
- **En transaktion per fil**, som `psql -1` i drift, men med en savepoint per sats. Då faller
  transaktionsbundna fel här precis som i drift (t.ex. ett nytt enum-värde som används i samma
  fil), samtidigt som ett fel i sats 3 inte döljer sats 4–17. En fil med egen
  `begin`/`commit` underkänns, eftersom provet då inte kan efterlikna drift troget.
- **En sats i taget.** Delaren respekterar `'…'`, `"…"`, `$tag$…$tag$`, `--` och `/* */`.
  Satser som bara består av kommentarer räknas inte.
- **`onNotice` sätts per fråga** (`db.exec(sql, { onNotice })`). På konstruktorn tystnar varje
  `raise warning` utan felmeddelande. Varningar skrivs ut och lyfts som `::warning::` men
  underkänner inte — migration 27 varnar legitimt om `ensure_rls`.
- **Tillåtna fel är en namngiven lista** i skriptet, matchad på hela satsen, aldrig på
  felmeddelandet. I dag bara `create extension if not exists pg_net`: pg_net finns inte i PGlite.

Underkänt (exit 1) också om `schema.sql` saknas, om ingen migrationsfil hittas eller om noll
satser kördes — ett prov som inte provade något är inte grönt.

## Vad ett grönt prov bevisar

Att repots SQL går att köra i följd, i drifts ordning, på en tom PostgreSQL **där Supabase-
plattformen redan finns** — och inget mer.

## Vad det INTE bevisar

- **Inte att repot räcker utan plattformen.** Stubbarna (`auth`-schemat, `auth.users`,
  `auth.uid()`, `storage`-schemat och dess funktioner, rollerna `anon`/`authenticated`/
  `service_role`) är **skrivna i skriptet, inte hämtade ur repot**. Utan dem faller provet
  (`--naket`). En riktig Supabase-instans har dem; en vanlig PostgreSQL har det inte.
- **Inte att funktionerna fungerar när de anropas.** PL/pgSQL-kroppar valideras inte när de
  skapas. Ingen funktion, trigger eller policy körs mot data här. `pg_net` saknas helt, så
  inget som skickar webhooks provas alls.
- **`ensure_rls` återskapas inte.** Event-triggern kräver superuser och skapas inte av någon
  fil; migration 27 varnar för det. En databas byggd ur repot saknar alltså skyddet att nya
  tabeller i `public` får RLS automatiskt.
- **Seed-radernas innehåll jämförs inte.** Provet ser att `insert`-satserna går igenom, inte
  att raderna blir desamma som i drift.
- **Ingen jämförelse mot drift görs automatiskt.** Sist skrivs en inventering ut (antal
  funktioner, policies, triggers och kolumner, plus md5 på objekt- och kolumnlistan) med samma
  SQL-uttryck som används mot drift — men att köra dem mot drift och jämföra är en människas
  jobb. Ett grönt prov kan alltså stå bredvid ett repo som saknar en kolumn drift har.
- **Inte samma PostgreSQL som drift.** PGlite är en egen byggd version (skrivs ut i loggen) utan
  Supabases tillägg. Något som beror på version eller tillägg kan skilja.
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
