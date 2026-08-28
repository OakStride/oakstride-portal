-- Migration 30: två beteendeändringar, båda medvetna
--
-- ⚠️ DEN HÄR FILEN ÄNDRAR DRIFT MED FLIT. Det är motsatsen till migration 29, som skulle
-- vara en no-op. Blanda dem aldrig i samma fil — migration 27 blev underkänd två gånger
-- för just det.
--
-- Två ändringar, ingen tredje:
--   1. `norm_host()` strippar inte `www.` — ett dubbelt bakstreck i regexet.
--   2. `extra_work_approvals`-policyn låter en kund RADERA sitt eget godkännande.
--
-- ⛔ VAD SOM INTE LIGGER HÄR, och varför:
--   * **`notify_email()`s failed-gren.** Repot saknar den, men **drift HAR den redan**
--     (mätt 2026-08-27: `position('failed' in pg_get_functiondef(...)) > 0`). Att skriva
--     ned den är alltså DOKUMENTATION, inte en beteendeändring — samma sort som migration
--     29. Den hör hemma i en egen fil (31), inte här. Jag skrev själv fel om detta när jag
--     planerade: den stod som "beteendeändring" i lägesfilen tills mätningen visade annat.
--   * **`billing_details`-policyn `faktura: kund hanterar egna`**, som har samma breda
--     FOR ALL-form. Där är det troligen avsiktligt — kunden ska kunna rätta sina egna
--     faktureringsuppgifter, och portalen använder `upsert`, alltså behövs UPDATE. Frågan
--     ställdes till Fredrik 2026-08-26 och är **obesvarad**. Rör den inte förrän den är det.
--
-- 🔴 MERGE APPLICERAR INGENTING. Filen får effekt först när `kor-migrationer.yml` körs, och
--   det är ett eget knapptryck. Ändring 2 väntar dessutom på Fredriks uttryckliga nod —
--   frågan ligger i `2026-08-26-oakstride-studio-databasen-mot-repot.md` och är obesvarad.
--   Kör inte den här filen innan han svarat på den.
--
-- ============================ FÖRKRAV I STÄLLET FÖR KVITTO ============================
-- Migration 29 kontrollerade att den INTE ändrade något. Den här filen ska ändra, så
-- kontrollen är omvänd: den verifierar att **utgångsläget är det jag mätte**, och avbryter
-- annars. Har någon redan lagat något av det nedan, eller ändrat det åt ett tredje håll,
-- ska filen inte köra över det tyst. Filen kör i EN transaktion (`-1`), så ett exception
-- rullar tillbaka allt.
--
-- Förkraven är BETEENDEMÄSSIGA, inte md5. Ett md5 säger att texten är oförändrad; ett
-- beteendeprov säger att felet finns. Det senare är det som betyder något här.
-- =====================================================================================

set client_encoding to 'UTF8';

-- ---------------------------------------------------------------------------
-- 1. norm_host() strippar inte www — dubbelt bakstreck i regexet
-- ---------------------------------------------------------------------------
-- Drift 2026-08-27:
--   regexp_replace(..., '^www\\.|/.*$', '', 'g')
-- Med standard_conforming_strings PÅ är `\\` i en vanlig strängliteral TVÅ tecken, inte
-- ett escape. Regexet blir alltså `^www\\.` = "www, sedan ett bakstreck, sedan valfritt
-- tecken" — vilket aldrig matchar ett värdnamn. Uppmätt:
--   norm_host('https://www.Example.com/nagot') -> 'www.example.com'   (www INTE strippat)
--   norm_host('https://Example.com/nagot')     -> 'example.com'
--
-- Det är samma fälla som står i `globala-principer.md`: bakstreck överlever inte vägen
-- genom skal, heredoc, Python eller JSON. Repots version har rätt regex; det är DRIFT som
-- glidit. Den här filen tar drift tillbaka till repots avsikt.
--
-- 🟡 VAD SOM FAKTISKT ÄNDRAS I VÄRLDEN — TVÅ AXLAR, INTE EN.
--
-- **Axel 1, gruppering.** `normalize_page_view` normaliserar `page_views.site` vid INSERT.
-- Efter fixen hamnar ett besök på `www.kund.se` under `kund.se`. Vilande i dag: noll rader
-- har www-prefix (mätt). Behövs INNAN en kundsajt nås på både apex och www — då delas
-- besöken annars i två och statistiken blir fel utan att larma.
--
-- 🔴 **Axel 2, AUKTORISERING — den missade jag först, granskaren fann den.**
-- `site_stats` är `security definer` och använder `norm_host` som halva sitt behörighetsvillkor
-- (`migration-3-stats.sql` rad 45–56):
--     where id = auth.uid() and (is_admin or public.norm_host(website) = host)
-- `norm_host` avgör alltså **vem som får läsa statistik för vilken sajt**. Efter fixen:
--   * en kund vars `profiles.website` är `www.kund.se` kan anropa `site_stats('kund.se')`
--     och får svar — i dag nekas det;
--   * två profiler vars websites skiljer sig bara på `www.` normaliseras till SAMMA värde
--     och delar därmed statistikomfång.
--
-- **Uppmätt kollisionsyta 2026-08-27, ommätt oförändrad 2026-08-28, före körning:**
--   profiler med `www.` i website ............................. 0
--   kollisionsgrupper under GAMLA normaliseringen ............. 1  (två profiler, båda `oakstride.se`)
--   kollisionsgrupper under NYA normaliseringen ............... 1  (samma två, samma värde)
-- Kollisionen är alltså **pre-existerande och oförändrad av den här filen** — den beror på två
-- identiska värden på vår egen domän, inte på www. **Fixen skapar ingen ny delning.**
--
-- Taket för risken är begränsat men inte absolut: `protect_profile_cols` (migration-24 rad 33)
-- sätter `new.website := old.website` — men bara innanför `if auth.uid() is not null and not
-- public.is_admin()`. **En inloggad kund** kan alltså inte peka sin profil mot någon annans
-- domän. Varje skrivväg UTAN JWT — `service_role`, våra egna workflows och skript — kan
-- fortfarande sätta `website` fritt. Formuleringen i v2 ("måste skapas av admin") var starkare
-- än vad triggern ger. Därför bevakas kollisionen numera vid körning, inte bara i en mätning.
--
-- ✅ Beroenden kontrollerade mot katalogen, inte mot en handskriven lista (granskarens form):
--     select pg_describe_object(classid, objid, objsubid), deptype from pg_depend
--      where refclassid='pg_proc'::regclass
--        and refobjid = to_regprocedure('public.norm_host(text)') and deptype <> 'i';
--   Utfall 2026-08-27, ommätt 2026-08-28: **noll rader.** Inget index, ingen genererad kolumn,
--   ingen constraint,
--   ingen vy, ingen policy, ingen statistik och inget partitionsuttryck hänger på funktionen.
--
-- 🟡 **Axel 3, REFERRER — utskriven efter granskningen, den saknades i v2.**
-- `normalize_page_view` (`migration-3-stats.sql` rad 35) nollar `referrer` när
-- `norm_host(referrer) = new.site`. Efter fixen matchar `https://www.kund.se` mot `kund.se`,
-- så ett besök som i dag bokförs som en **referral från den egna www-adressen** i stället
-- räknas som ett internt klick och referrern kastas. Det är med all sannolikhet den avsedda
-- semantiken — en länk från din egen www-adress *är* intern — men v2 gjorde anspråk på att
-- vara uttömmande om vad som ändras, och nämnde den inte. En odeklarerad beteendeändring
-- bredvid en deklarerad är exakt formen som fällde migration 27 två gånger.
--
-- ℹ️ `set search_path to 'public'` nedan är INTE en tredje ändring: **drift har den redan**
--   (mätt med `pg_get_functiondef` 2026-08-27). Det är repots `migration-3-stats.sql` som
--   saknar klausulen. Den nya definitionen återger alltså drift, inte repot, på den punkten.

do $$
declare
  v_host   text;
  v_gamla  int;
  v_nya    int;
  v_dep    int;
begin
  if to_regprocedure('public.norm_host(text)') is null then
    raise exception 'migration 30 AVBRYTER: norm_host(text) finns inte i drift. Filen ar skriven mot en funktion som ska finnas - kontrollera vad som hant innan du kor om.';
  end if;
  -- Villkoret som gor fixen ofarlig maste galla VID KORNING, inte bara vid matningen.
  -- Dyker en www-rad upp daremellan blir den kundens historik osynlig for site_stats, som
  -- efter fixen slar upp 'kund.se' medan raden lagrats som 'www.kund.se'. Tyst bortfall.
  if exists (select 1 from public.page_views where site like 'www.%') then
    raise exception 'migration 30 AVBRYTER: page_views innehaller rader med www-prefix. Fixen skulle gora dem osynliga for site_stats. Normalisera dem forst, kor sedan om. (Ja - detta stoppar aven andring 2, RLS-fixen, eftersom filen kors i EN transaktion. Ar det laget: normalisera raderna, annars dela filen.)';
  end if;

  -- RATTAT (granskningsfynd mot v2): forra versionen satte en KORTIDSVAKT pa axel 1
  -- (grupperingen, som filen sjalv kallar vilande) men lamnade axel 2 - AUKTORISERINGEN -
  -- som en matning i en kommentar fran 2026-08-27. Fel axel bevakad. Satter mellan matning
  -- och korning en admin en profils website till 'kund.se' och en annans till 'www.kund.se'
  -- delar de tva profilerna statistikomfang efter fixen, och ingenting i filen marker det.
  -- Nu berakas kollisionsgrupperna under BADA normaliseringarna vid korning.
  select count(*) into v_gamla from (
    select public.norm_host(website) h
      from public.profiles
     where website is not null and website <> ''
     group by 1 having count(*) > 1) x;
  select count(*) into v_nya from (
    select regexp_replace(regexp_replace(lower(website), '^https?://', ''), '^www\.|/.*$', '', 'g') h
      from public.profiles
     where website is not null and website <> ''
     group by 1 having count(*) > 1) y;
  if v_nya > v_gamla then
    raise exception 'migration 30 AVBRYTER: fixen skulle skapa nya kollisionsgrupper i profiles.website (% fore, % efter). Tva kunder skulle da dela statistikomfang i site_stats. Uppmatt 2026-08-27 var bada 1 och oforandrade. Gransk profilerna innan du kor om.', v_gamla, v_nya;
  end if;

  -- Samma sak for beroendematningen: den lag ocksa bara som kommentar. Ett index, en vy
  -- eller en policy som skapats pa norm_host efter matningen skulle skrivas om under oss.
  select count(*) into v_dep from pg_depend
   where refclassid = 'pg_proc'::regclass
     and refobjid = to_regprocedure('public.norm_host(text)')
     and deptype <> 'i';
  if v_dep > 0 then
    raise exception 'migration 30 AVBRYTER: % objekt beror pa norm_host (index, vy, policy eller constraint). Uppmatt 2026-08-27: noll. En omdefiniering kan da andra deras innebord tyst - las pg_depend och avgor for hand.', v_dep;
  end if;

  -- Beteendeprov. RATTAT (granskningsfynd mot v2): forra formen avbrot om felet INTE fanns
  -- - alltsa ocksa vid en ateruppbyggnad ur repot, dar migration-3-stats.sql skapar den
  -- REDAN RATTA funktionen (ett bakstreck, kontrollerat byte for byte). Da fyrade forkravet
  -- garanterat, `psql -1` rullade tillbaka, och `set -euo pipefail` i kor-migrationer.yml
  -- stoppade migration 30 OCH varje senare fil. En vakt mot en glidning far inte gora repot
  -- obyggbart - det ar precis vad migration 29 och kunskap-db-mot-repo.md finns for att
  -- undvika. Nu accepteras BADA kanda formerna; bara en tredje avbryter.
  v_host := public.norm_host('https://www.Example.com/nagot');
  if v_host = 'example.com' then
    raise notice 'migration 30: norm_host ar REDAN ratt (ger "example.com"). Andring 1 blir en no-op. Vantat i en ateruppbyggnad ur repot - ALARMERANDE i produktion, dar buggen var uppmatt 2026-08-27.';
  elsif v_host <> 'www.example.com' then
    raise exception 'migration 30 AVBRYTER: norm_host ger "%" - varken den uppmatta buggen ("www.example.com") eller det ratta svaret ("example.com"). Nagon har andrat funktionen at ett tredje hall. Las den med pg_get_functiondef och avgor for hand.', v_host;
  end if;
end $$;

create or replace function public.norm_host(t text)
 returns text
 language sql
 immutable
 set search_path to 'public'
as $function$
  select regexp_replace(regexp_replace(lower(coalesce(t, '')), '^https?://', ''), '^www\.|/.*$', '', 'g')
$function$;

-- ---------------------------------------------------------------------------
-- 2. En kund kan radera sitt eget godkännande av extraarbete
-- ---------------------------------------------------------------------------
-- `extra_work_approvals` är beviset för att en kund godkänt extraarbete: user_id,
-- spec_version, approved_at. Policyn i drift 2026-08-27:
--
--   "extra-godk: kund hanterar egna"  FOR ALL  to public
--     using (user_id = auth.uid())  with check (user_id = auth.uid())
--
-- `FOR ALL` omfattar UPDATE och **DELETE**. En inloggad kund kan alltså radera eller
-- backdatera sitt eget godkännande — alltså underlaget för att vi fick fakturera.
--
-- ✅ Portalen behöver INTE de rättigheterna. Kontrollerat i `portal/app.js`:
--     insert  rad 1728, 1753, 1796
--     select  rad 1478 (kundens egen), 2612 och 2736 (adminvyerna)
--   ⚠️ Rattat: forsta versionen angav rad 2493 som en adminvy. Den raden ror inte tabellen
--   alls — den ar en go-live-prompt — och de tva verkliga admin-selecterna saknades. Bada
--   tacks av "extra-godk: admin laser", sa slutsatsen holl, men listan ar sjalva
--   sakerhetsargumentet och far darfor inte peka pa en oskyldig rad.
--   Ingenting uppdaterar eller raderar en rad. Policyn kan därför smalnas till SELECT +
--   INSERT utan att något slutar fungera.
--
-- ⚠️ NAMNBYTET ÄR AVSIKTLIGT. Den gamla policyn hette "kund hanterar egna", vilket var
-- sant om det den fick göra. De två nya heter vad de gör. I en återuppbyggnad skapar
-- migration 29 först den breda policyn och den här filen ersätter den — nettoresultatet
-- blir rätt, eftersom filerna körs i nummerordning.
--
-- ⚠️ Drop och create ligger i samma transaktion, så det finns inget fönster där tabellen
-- saknar policy.

-- 🔴 FORKRAVET PROVAR HELA DET TILLSTAND SOM FORSTORS, inte bara namnet.
-- Forsta versionen las bara `cmd`. Hade nagon andrat policyns VILLKOR sedan matningen -
-- smalnat det, vidgat det, lagt till ett tidsvillkor - hade forkravet passerat, `drop policy`
-- rivit den, och de tva nya skapats ur den DOKUMENTERADE lydelsen. Den gamla villkorstexten
-- finns ingenstans i repot, sa den hade inte gatt att aterstalla.
--
-- Det ar samma svaghet som granskaren fallde i migration 29 - namnmatchning kan inte upptacka
-- att en policy med ratt namn har fel villkor - men dar var foljden att filen HOPPADE OVER
-- policyn. Har ar foljden att den RADERAS. Samma brist, allvarligare utfall, i en fil vars
-- hela premiss ar att forkraven ska bevisa att utgangslaget ar det som mattes.
--
-- Uppmatt i drift 2026-08-27, och det ar dessa varden forkravet krav:
--   cmd = ALL · permissive = PERMISSIVE · roles = {public}
--   qual       = (user_id = auth.uid())
--   with_check = (user_id = auth.uid())
do $$
declare
  r record;
begin
  select cmd, permissive, roles::text as roles, qual, with_check into r
    from pg_policies
   where schemaname = 'public' and tablename = 'extra_work_approvals'
     and policyname = 'extra-godk: kund hanterar egna';

  if not found then
    raise exception 'migration 30 AVBRYTER: policyn "extra-godk: kund hanterar egna" finns inte pa extra_work_approvals. Den var uppmatt 2026-08-27 - nagon har redan tagit bort eller dopt om den. Las pg_policies och avgor for hand.';
  end if;
  if r.cmd <> 'ALL' then
    raise exception 'migration 30 AVBRYTER: policyn ar redan smalnad (cmd = %, vantat ALL). Ingenting att gora - kontrollera att de tva nya policyerna finns i stallet.', r.cmd;
  end if;
  if r.permissive <> 'PERMISSIVE' or r.roles <> '{public}' then
    raise exception 'migration 30 AVBRYTER: policyn har andrats sedan matningen (permissive = %, roles = %; vantat PERMISSIVE och {public}). Filen river en policy den inte langre kanner igen - las pg_policies och avgor for hand.', r.permissive, r.roles;
  end if;
  if r.qual is distinct from '(user_id = auth.uid())'
     or r.with_check is distinct from '(user_id = auth.uid())' then
    raise exception 'migration 30 AVBRYTER: policyns VILLKOR har andrats sedan 2026-08-27. Drift har nu qual = %, with_check = %. Filen skulle ha rivit det och ersatt det med den dokumenterade lydelsen - alltsa tappat nagon annans andring utan spar. Las villkoret, avgor for hand vad som ska galla, och skriv en ny migration.', coalesce(r.qual,'(null)'), coalesce(r.with_check,'(null)');
  end if;
end $$;

drop policy "extra-godk: kund hanterar egna" on public.extra_work_approvals;

create policy "extra-godk: kund läser egna"
  on public.extra_work_approvals
  for select to public
  using (user_id = auth.uid());

create policy "extra-godk: kund godkänner"
  on public.extra_work_approvals
  for insert to authenticated
  with check (user_id = auth.uid());
-- ⚠️ `to authenticated`, inte `to public` som den gamla. Det ar en AVSIKTLIG atstramning
-- och den andrar ingenting i praktiken: `auth.uid()` ar NULL for `anon`, sa villkoret
-- `user_id = auth.uid()` var redan falskt for en utloggad besokare. Skillnaden ar att
-- rollistan nu sager samma sak som villkoret, i stallet for att forlita sig pa det.
-- ⚠️ Select-policyn behaller `to public` medan insert stramas at. Asymmetrin ar avsiktlig men
-- odramatisk: bada villkoren ar `user_id = auth.uid()`, som ar falskt for `anon` oavsett
-- rollista. Jag lat select sta kvar for att den ar identisk i form med de tva admin-policyerna
-- pa samma tabell, som ocksa ar `to public` - en enda avvikande rollista har varit svarare att
-- lasa an en konsekvent.

-- ---------------------------------------------------------------------------
-- 3. EFTERKONTROLL — bevisa att båda ändringarna tog
-- ---------------------------------------------------------------------------
-- Den här filen SKA ändra. Larmet är därför omvänt mot migration 29: den skriker om
-- ingenting hände, inte om något hände.

do $$
declare
  v_host text;
  v_all  int;
  v_nya  int;
begin
  v_host := public.norm_host('https://www.Example.com/nagot');
  if v_host <> 'example.com' then
    raise exception 'migration 30 AVBRYTER: norm_host ger fortfarande "%" efter fixen, vantat "example.com". Regexet tog inte.', v_host;
  end if;

  -- Invarianten ar "ingen kundnabar UPDATE- eller DELETE-vag finns kvar", inte "ingen FOR ALL
  -- for public". Forsta versionen provade det senare och hade darfor slappt igenom bade en
  -- FOR ALL till authenticated och en ren UPDATE- eller DELETE-policy. Kontrollen kunde alltsa
  -- ga igenom medan halet stod kvar - ett kontrollsteg som ljuger.
  select count(*) into v_all from pg_policies
   where schemaname='public' and tablename='extra_work_approvals'
     and cmd in ('ALL','UPDATE','DELETE');
  if v_all > 0 then
    raise exception 'migration 30 AVBRYTER: det finns fortfarande % policy med cmd ALL, UPDATE eller DELETE pa extra_work_approvals. Nagon kan da alltjamt andra eller radera ett godkannande.', v_all;
  end if;

  select count(*) into v_nya from pg_policies
   where schemaname='public' and tablename='extra_work_approvals'
     and policyname in ('extra-godk: kund läser egna','extra-godk: kund godkänner');
  if v_nya <> 2 then
    raise exception 'migration 30 AVBRYTER: vantade tva nya policyer pa extra_work_approvals, hittade %.', v_nya;
  end if;

  -- RATTAT (granskningsnotering mot v2): var `raise warning`. kor-migrationer.yml lyfter VARJE
  -- warning till en ::warning::-annotering, just for att verkliga varningar annars forsvinner
  -- bakom SHA-laset. En ren framgangsrapport i larmkanalen spader ut den signalen.
  raise notice 'migration 30 KLAR - tva beteendeandringar applicerade: norm_host strippar nu www, och kunden kan inte langre radera sitt eget godkannande av extraarbete. Bada ar AVSIKTLIGA andringar i drift.';
end $$;

-- ---------------------------------------------------------------------------
-- VERIFIERING — kör detta efteråt, oberoende av filens egna kontroller
-- ---------------------------------------------------------------------------
--   select public.norm_host('https://www.Example.com/nagot');   -- ska ge example.com
--   select public.norm_host('https://Example.com/nagot');       -- ska ge example.com
--
--   select policyname, cmd, roles::text, qual, with_check from pg_policies
--    where schemaname='public' and tablename='extra_work_approvals' order by policyname;
--   -- ska ge FYRA rader, ingen med cmd = ALL:
--   --   "extra-godk: admin läser"   SELECT   (fanns forut, ororad)
--   --   "extra-godk: admin skapar"  INSERT   (fanns forut, ororad)
--   --   "extra-godk: kund läser egna" SELECT (ny, ersatter halva den gamla)
--   --   "extra-godk: kund godkänner"  INSERT (ny, ersatter andra halvan)
--
-- ⚠️ MIGRATION 29:s VERIFIERINGSPUNKT 2 GALLER INTE LANGRE FOR DEN HAR TABELLEN.
--    Den sager "jamfor policyerna rad for rad mot sektion 3, villkoren ska vara identiska".
--    Efter den har filen finns "extra-godk: kund hanterar egna" inte kvar - den ar ersatt av
--    tva smalare. Migration 29 ar SHA-last och kan inte rattas; darfor star det har i stallet.
--
-- ⚠️ Anvand inte `like 'migration-3[0]%'` for att kolla liggaren - LIKE kanner inte
--    teckenklasser. Ratt form: `filnamn ~ '^migration-30-'`.
--    Se `studio/minne/kunskap-verifiering.md`.
