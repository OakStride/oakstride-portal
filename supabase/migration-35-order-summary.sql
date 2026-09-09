-- Migration 35: agreement_acceptances.order_summary skrivs ned i repot
--
-- Version 3. Underkänd två gånger: **v1 på fyra punkter** (två blockerande — det osanna
-- no-op-påståendet och radnummer mätta på en omergad gren; två bör-fixas — vakten mätte
-- eftertillståndet, och den enda nåbara kontrollen felade mjukt), **v2 på en** (temptabellen
-- åberopade migration 29:s mönster men tappade dess härdning). 🔴 v2:s huvud sa "tre punkter"
-- och bar fyra rättelsemarkörer — den räkningen är hela poängen med att skriva ned dem, så
-- den är rättad här. Samtliga står som "RÄTTAT" nedan med mätningen som avgjorde saken.
--
-- Fem av fem fynd satt i FILHUVUDET, inte i koden. För en migration vars enda produkt är
-- dokumentation är huvudet leveransen — läs dem innan du ändrar något här.
--
-- Dokumentation, inte en beteendeändring i drift. Samma sort som 29, 32 och 33: kolumnen
-- FINNS i produktion, den saknas bara i repot.
--
-- ⚠️ FILEN ÄR EN NO-OP I INNEHÅLL MOT PRODUKTION — men inte genom att varje sats är
-- villkorad. 🔴 RÄTTAT: version 1 påstod att `set client_encoding` var den enda villkorslösa
-- satsen. Det var osant, och det är exakt det påstående migration 29 underkändes för i sin
-- egen version 1 (se `migration-29-repot-beskriver-databasen.sql:9-13`). Följande körs
-- VILLKORSLÖST:
--   * `set client_encoding`                       — ofarlig, men körs alltid
--   * `create temp table` + `drop table`          — bara i sessionen, men körs alltid
--   * `alter table ... add column if not exists`  — no-op i INNEHÅLL, men Postgres väljer
--     låsnivå ur underkommandot och tar **ACCESS EXCLUSIVE** på `agreement_acceptances`
--     INNAN `if not exists` prövas. Låset hålls till commit, alltså genom hela DO-blocket,
--     eftersom `kor-migrationer.yml` kör filen med `psql -1`.
--
-- Vad det betyder i praktiken: väntar ALTER-satsen på en öppen transaktion mot tabellen
-- ställer sig varje nytt avtalsgodkännande i kö bakom den. Tabellen är liten (1 rad, mätt
-- 2026-09-09), så fönstret är kort — men det är inte noll, och det ska stå här i stället för
-- att låta någon läsa "no-op" som "rör ingenting".
--
-- 📏 UPPMÄTT 2026-09-09, så att det blir en siffra och inte en åsikt
-- (`select setconfig from pg_db_role_setting`):
--   authenticator  statement_timeout=8s, **lock_timeout=8s**   ← PostgREST ansluter som denna
--   authenticated  statement_timeout=8s
--   anon           statement_timeout=3s
--   postgres       inget lock_timeout; statement_timeout = klustrets 2min
-- Kundens avtalsgodkännande går genom PostgREST och möter alltså `lock_timeout=8s`: det
-- **faller med ett fel efter åtta sekunder** i stället för att hänga. Migrationen själv kör
-- som `postgres`, utan lock_timeout, och väntar därför obegränsat på låset. Följden är alltså
-- inte "långsamt för kunden" utan "fel för kunden, om låset hålls längre än åtta sekunder".
--
-- ⚠️ Inget `lock_timeout` sätts i den här filen. Det gör ingen annan fil i `supabase/` heller
-- (grep: noll träffar), och jag inför inte ett nytt mönster ensidigt i en
-- dokumentationsmigration. Ska det finnas hör det hemma i `kor-migrationer.yml`, för alla
-- filer. 👉 Den frågan är Fredriks, och den är ställd — den ligger inte och skräpar här
-- utan ägare.
--
-- ============================ HUR GLAPPET HITTADES ============================
-- Provet 2026-09-09 (Fredriks kort k-20260906-05, "kör provet lokalt"): hela repot byggdes
-- till en databas i PGlite, sats för sats, och jämfördes mot drift. Funktioner, policies och
-- triggers var IDENTISKA — 114 objekt, samma md5. Kolumnerna var det inte:
--
--   drift  151 kolumner i public (utan applied_migrations)
--   repot  150
--   skillnaden: agreement_acceptances.order_summary
--
-- Tidigare kartläggningar missade den för att de jämförde OBJEKT. En kolumn-för-kolumn-diff
-- var uttryckligen inte gjord — det står i `studio/minne/kunskap-db-mot-repo.md`.
--
-- ============================ VARFÖR DET SPELAR ROLL ============================
-- Kolumnen är inte oanvänd. Två ställen råkar ut för den:
--
--   app.js:1725 och :1750   (radnummer på origin/main, kontrollerade där)
--     skriver order_summary vid båda avtalsvägarna — `approveOffer` och `approveUpdatedOffer`.
--   supabase/migration-23-notify-published-email.sql:83 och :90
--     läser new.order_summary i aviseringstriggern.
--
-- 🔴 RÄTTAT: version 1 angav app.js-raderna som 2001 och 2048. De siffrorna är mätta i ett
-- arbetsträd som stod på den OMERGADE grenen `fix/blockera-utan-kontrollsumma` (PR #69), där
-- de stämmer. På main är det 1725 och 1750. Sakpåståendet höll, koordinaterna gjorde det inte.
-- ✅ Kontrollerat efteråt att provet ändå mätte rätt filuppsättning: `git diff origin/main
-- origin/fix/blockera-utan-kontrollsumma -- supabase/` är TOM, så migrationsfilerna som
-- byggdes var main:s. Det är den kontrollen som gör siffrorna nedan giltiga — inte att jag
-- tror det.
--
-- I en återuppbyggnad ur repot hade alltså avtalsgodkännandet fallit på en okänd kolumn, och
-- aviseringen med den. Det är `agreement_acceptances` — tabellen som bär beviset för att
-- kunden godkänt avtalet. Se `studio/minne/kunskap-avtal-villkor.md`.
--
-- ============================ KVITTO PÅ MÄTNINGEN ============================
-- Mot drift (wtekqlkkcomtgizjtqeo) 2026-09-09. Kör om och jämför — påstå ingenting härifrån
-- utan att ha gjort det:
--
--   select column_name, data_type, is_nullable, column_default
--     from information_schema.columns
--    where table_schema='public' and table_name='agreement_acceptances'
--    order by ordinal_position;
--
-- Gav nio rader, den nionde:  order_summary | text | YES | (inget default)
-- Inga kolumn-grants på tabellen (`pg_attribute.attacl` är null överallt), så kolumnen ärver
-- tabellens grants och repot beskriver behörigheterna även efter den här filen.
--
-- 🔴 RÄTTAT (v3): version 2 skrev här *"select count(*) from applied_migrations -> 28, alltså
-- exakt de 28 filer som ligger i repot"* och drog slutsatsen att kolumnen kom in för hand.
-- Slutsatsen håller, men BEVISET var fel — och det är precis `baseline`-fällan som står i
-- `studio/minne/kunskap-supabase-och-agent.md`: en bokföring är inte ett kvitto. Uppmätt:
--
--   select applied_by, count(*) from public.applied_migrations group by 1;
--     baseline              24
--     kor-migrationer.yml    4     (27, 28, 29, 30)
--
-- Tjugofyra av de tjugoåtta är alltså BOKFÖRDA UTAN ATT HA KÖRTS av kedjan. `count(*) = 28`
-- bevisar bara att inget EXTRA har körts — inte att de 28 kördes.
--
-- Det som faktiskt bär slutsatsen är enklare och oberoende av liggaren: **ingen fil i repot
-- skapar kolumnen**, varken bland de baseline-bokförda eller de körda. `grep -rn order_summary`
-- över hela `studio/` ger tre träffar, och alla tre ANVÄNDER den — app.js två gånger och
-- migration 23 en gång. Kolumnen kom alltså in som en lös sats för hand. Den här filen är det
-- som gör kedjan hel igen.
--
-- 📏 Och grenen den finns för används: `select count(*), count(order_summary) from
-- public.agreement_acceptances` gav **1 av 1** — raden har ett order_summary, så
-- migration 23:s gren `if new.order_summary is not null` har gått i drift. Kolumnen är alltså
-- inte bara load-bearing i kod utan bevisat i verkan.
--
-- ⚠️ Ingen `not null`, inget default — med flit. Så ser den ut i drift, och en `not null`
-- hade dessutom fallit på befintliga rader. Skriv inte om den till något "snyggare" än det
-- som faktiskt kör.

set client_encoding to 'UTF8';

-- 🔴 RÄTTAT: version 1 mätte kolumnens existens EFTER `add column` och kunde därför aldrig
-- skilja "fanns redan i drift" från "skapades nu i en återuppbyggnad" — de två lägen huvudet
-- lovade att den skulle skilja. Katalogen ser likadan ut i båda fallen. Både granskaren och
-- tystnadsgranskaren fann samma sak, oberoende av varandra.
-- Mätningen måste alltså ske FÖRE.
--
-- 🔴 RÄTTAT (v3): version 2 skrev `create temp table _m35_fore as select …` och kallade det
-- "samma mönster som `_f29_fore` i migration 29". Det var osant, och skillnaden är precis den
-- härdning 29 blev rättad för — se `migration-29-repot-beskriver-databasen.sql:99-113`. Två
-- saker, båda med skäl:
--   * `if not exists` + `delete from` i stället för ett naket `create` — annars dör filen på
--     `relation "_m35_fore" already exists` vid en OMKÖRNING FÖR HAND, alltså i Supabases
--     SQL-editor. Det är inte ett hypotetiskt läge: det är så 24 av repots migrationer
--     historiskt hamnade i drift, och det är den troliga vägen i en återuppbyggnad — som är
--     hela skälet till att den här filen finns. Felmeddelandet hade dessutom handlat om en
--     temptabell i stället för om det som faktiskt gick fel.
--   * INTE `on commit drop` — körs filen sats för sig commitas `create temp table` för sig,
--     tabellen släpps omedelbart, och DO-blocket dör på "does not exist".
-- Under `kor-migrationer.yml` (`psql -1`) kan inget av detta fyra, eftersom ett fel rullar
-- tillbaka allt. Härdningen är för människan i editorn, inte för CI.
create temp table if not exists _m35_fore (fanns boolean);
delete from _m35_fore;
insert into _m35_fore
  select exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name   = 'agreement_acceptances'
       and column_name  = 'order_summary'
  );

alter table public.agreement_acceptances
  add column if not exists order_summary text;

do $$
declare
  v_fanns_innan boolean;
  v_typ         text;
begin
  select fanns into v_fanns_innan from _m35_fore;

  select data_type into v_typ
    from information_schema.columns
   where table_schema = 'public'
     and table_name   = 'agreement_acceptances'
     and column_name  = 'order_summary';

  if v_typ is null then
    -- Kan bara inträffa om ALTER-satsen ovan tystnade, vilket den inte kan i samma
    -- transaktion. Står här ändå: en vakt som bara kontrollerar det förväntade larmar
    -- aldrig om det oväntade.
    raise exception 'migration 35: order_summary saknas EFTER add column. Något har stoppat satsen.';
  end if;

  if v_typ <> 'text' then
    -- 🔴 RÄTTAT: version 1 hade `raise warning` här. Det var fel kanal för ett fel som inte
    -- går att komma tillbaka till: `add column if not exists` tiger om kolumnen finns med FEL
    -- typ, en varning låter psql avsluta med 0, och då bokförs filen och SHA-låses. Den kan
    -- aldrig köras om automatiskt (`kor-migrationer.yml`), och liggaren skulle påstå att
    -- glappet är stängt medan repot och drift beskriver olika kolumner — permanent. Samma
    -- val som `migration-34-kontrollsumma-check.sql` gör för sin efterkontroll.
    raise exception 'migration 35: order_summary är "%", inte text. Repot och drift beskriver då olika kolumner, och en varning här hade bokfört filen som klar.', v_typ;
  end if;

  -- Två giltiga lägen, och NU går de att skilja åt. Warning i återuppbyggnadsfallet, för att
  -- `kor-migrationer.yml` lyfter WARNING till en annotering men låter NOTICE stanna i loggen
  -- — och "filen gjorde något mot en databas som skulle ha haft kolumnen" är det läge som
  -- förtjänar att synas.
  if v_fanns_innan then
    raise notice 'migration 35: order_summary fanns redan (typ text). No-op, som väntat mot produktion.';
  else
    raise warning 'migration 35: order_summary SAKNADES och skapades nu. Väntat i en återuppbyggnad ur repot — ALARMERANDE mot produktion, där den var uppmätt som befintlig 2026-09-09.';
  end if;
end $$;

drop table _m35_fore;
