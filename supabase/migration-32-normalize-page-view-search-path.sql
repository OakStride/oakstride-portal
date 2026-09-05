-- Migration 32: normalize_page_view() far sin search_path-klausul i repot
--
-- 📗 DOKUMENTATION AV DRIFT. Filen ska inte andra nagonting i produktion - den
-- skriver ned det som redan kors dar, sa att en ateruppbyggnad ur repot ger
-- samma funktion. Samma sort som migration 29, och medvetet SKILD fran
-- migration 30, som andrade drift med flit. Blanda dem aldrig i samma fil;
-- migration 27 blev underkand tva ganger for just det.
--
-- ⚠️ NUMMER 31 ar hoppat over MED FLIT. En tidigare fil med det numret
-- (`migration-31-notify-email-failed-grenen.sql`) byggdes 2026-09-05 pa en
-- FELAKTIG premiss, underkandes i granskning och stangdes utan merge - se
-- PR #63. Den nadde aldrig main och ar aldrig bokford. Numret ateranvands inte,
-- sa att ingen som laser liggaren i efterhand blandar ihop dem.
--
--
-- VEM SOM BESLUTAT VAD - las det har innan du citerar filen
-- ==========================================================
-- ⚠️ Beslutet att **driftens version galler** ar mitt (Nova), fattat 2026-09-05
-- nar jag stangde issue #58. Det ar **INTE Fredriks beslut** - en tidigare
-- version av det har filhuvudet pastod det, och det var fel. Fredrik har inte
-- tillfragats om den har funktionen. Ratta aldrig tillbaka det: att tillskriva
-- honom ett beslut han inte tagit ar precis den sortens falska pastaende hela
-- det har projektet finns till for att sluta producera.
--
-- 📐 AVSTEG FRAN #58:s ORDALYDELSE, med skalet utskrivet
-- ------------------------------------------------------
-- #58 avslutas med att implementationen hor hemma i **#57, tillsammans med de
-- ovriga saknade objekten - i EN migration, inte i en egen.** Den har filen ar
-- en egen fil. Skalet ar att **premissen foll**: nar #58 skrevs antogs det
-- finnas flera kvarvarande objekt. Ommatningen samma dag visade att det finns
-- **exakt ett**. "En migration i stallet for en per glapp" och "den har filen"
-- ar da samma sak - det finns ingenting att slasa ihop den med.
--
-- Det ar alltsa premissen som andrats, inte regeln. Star det nagon gang harefter
-- att fler objekt saknas: las om #58:s regel, den galler fortfarande.
--
--
-- VAD SOM SKILJER, MATT 2026-09-05
-- =================================
--   Drift : LANGUAGE plpgsql SET search_path TO 'public'
--   Repot : language plpgsql              (ingen klausul, migration-3-stats.sql)
--
-- `driftkartlaggaren` korde om hela jamforelsen efter att migration 29 och 30
-- gatt i drift 07:19. Utfall: 21/21 tabeller, 32/32 funktioner, 55/55 policies
-- och 24/24 triggers stammer mot repot. **Det har ar den enda kvarvarande
-- avvikelsen** - och den siffran ar en matning fran den dagen, inte en
-- evighetssanning. Matt om innan du litar pa den.
--
-- Risken ar LAG och ska inte overdrivas: funktionen ar INTE `security definer`,
-- och den anropar `public.norm_host` schemakvalificerat. Men en ateruppbyggnad
-- ur repot skulle skapa den utan klausulen, och da beskriver repot inte
-- databasen. Det ar hela poangen med det har projektet.
--
--
-- 🔬 KROPPEN AR HAMTAD UR DRIFT, INTE UR REPOT
-- =============================================
-- Driftens `prosrc` saknar kommentarraden `-- interna klick ar inte referrals`
-- som star i migration-3. Kommentarer LAGRAS i prosrc, sa driftens funktion har
-- alltsa aldrig skapats ur migration-3:s text ordagrant - nagon har redefinerat
-- den. Skriver vi in repots kropp har hade vi ANDRAT drift i en fil som utger
-- sig for att vara en no-op.
--
-- Darfor ar kroppen nedan driftens, tecken for tecken. Uppmatt 2026-09-05:
--   md5(prosrc)              = b4786aafa5a1f95a9f5c3dd31b911ae6, 184 tecken
--   md5(pg_get_functiondef)  = 33609944fe0aae8390c66bc6a42b6457, 328 tecken
--   volatile · invoker · cost 100 · parallel unsafe · ej leakproof · en variant

--
-- 🧪 PROVAT INNAN MERGE - och sag inte att en torrkorning racker
-- ==============================================================
-- ⚠️ `dry_run=true` i kor-migrationer.yml skriver bara "SKULLE KORA" och ror
-- ALDRIG psql (rad 157-160). En torrkorning bevisar alltsa INGENTING om den har
-- filens SQL. Det ar samma sort som issue #24 handlar om: ett prov kan ga gront
-- utan att ha provat nagot.
--
-- Vad som verkligen ar provat, 2026-09-05 mot drift:
--   1. Bada `do $$`-blocken kordes skarpt med `create or replace` UTELAMNAD -
--      de laser bara pg_catalog och satter sessions-GUC:er, sa ingenting andrades.
--      I driftlaget ar create-or-replace anda en no-op, sa provet tacker HELA
--      driftvagen. Utfall: laget mattes till `drift`, krav 2 kordes och holl.
--   2. GUC:erna overlevde mellan de tva blocken i samma session - forutsattningen
--      krav 2 vilar pa, matt i stallet for antagen.
--   3. Beslutslogikens FEM grenar provade var for sig pa pahittade varden:
--      klausul finns · klausul pekar fel · ateruppbyggnad · okand kropp ·
--      klausul plus ett extra proconfig-element. Alla fem gav ratt utfall.
--      (PR #47:s lardom: felet satt i den ovanliga grenen, inte den vanliga.)
--
-- Vad som INTE ar provat: sjalva `create or replace` mot en databas som saknar
-- klausulen - alltsa ateruppbyggnadsvagen. Den kraver ett tomt schema, och det
-- ar issue #61.

set client_encoding to 'UTF8';

-- ---------------------------------------------------------------------------
-- FORKRAV - det MATER, det pastar inte
-- ---------------------------------------------------------------------------
-- Lardom fran migration 31 samma dag: ett forkrav som letar efter en strang som
-- star i filens egen kropp kan aldrig ga rott. Det har laser pg_catalog fore
-- skrivningen och sparar utfallet, sa att efterkontrollen har nagot att jamfora
-- mot.
--
-- 🔍 Jamforelsen gors pa `pg_get_functiondef`, inte pa `prosrc`. Skalet ar ett
-- granskningsfynd: `create or replace` satter OM alla attribut som inte anges -
-- volatility, security, cost, parallel, leakproof, proconfig - till sina
-- default. En jamforelse pa enbart kroppen hade bevisat ETT attribut och
-- ANTAGIT sju. `pg_get_functiondef` bar allihop i en strang. Samma konvention
-- som migration 25 och 26 redan anvander.
do $$
declare
  v_oid oid;
  v_def_md5 text;
  v_cfg text;
  v_kropp text;
  v_antal int;
begin
  v_oid := to_regprocedure('public.normalize_page_view()');
  if v_oid is null then
    raise exception 'migration 32 AVBRYTER: normalize_page_view() finns inte i drift. Filen ar skriven mot en funktion som ska finnas - kontrollera vad som hant innan du kor om.';
  end if;

  -- ⚠️ Filtrera pa OID, inte pa proname. En overlagring hade gett tva rader, och
  -- plpgsql `select into` utan `strict` tar da en GODTYCKLIG rad utan att fela -
  -- for- och efterkontrollen hade kunnat mata olika funktioner utan ett ord.
  select md5(pg_get_functiondef(p.oid)), coalesce(array_to_string(p.proconfig, ','), '')
    into v_def_md5, v_cfg
    from pg_proc p
   where p.oid = v_oid;

  select count(*) into v_antal
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'normalize_page_view';
  if v_antal <> 1 then
    raise warning 'migration 32: det finns % varianter av normalize_page_view. Filen ror bara noll-argumentvarianten - kontrollera att det ar avsiktligt.', v_antal;
  end if;

  perform set_config('migration32.def_fore', v_def_md5, false);
  perform set_config('migration32.cfg_fore', v_cfg, false);

  if v_cfg = 'search_path=public' then
    -- Vantat lage i produktion.
    perform set_config('migration32.lage', 'drift', false);
    raise notice 'migration 32: search_path=public finns REDAN. Filen ar en no-op - det ar det vantade laget i produktion.';

  elsif position('search_path' in v_cfg) > 0 then
    -- Klausulen finns men pekar nagon annanstans. Da ANDRAR filen drift, och det
    -- far den inte gora tyst - forkravet var loste an efterkontrollen i en
    -- tidigare version, sa detta fall hade passerat bada kraven och skrivit KLAR.
    raise exception 'migration 32 AVBRYTER: search_path ar satt till "%" och inte till public. Filen skulle da ANDRA drift, och den ar skriven som en no-op. Avgor for hand vad som ska galla innan du kor om.', v_cfg;

  else
    -- Ingen klausul alls. Tva helt olika lagen ser likadana ut har, och de kraver
    -- MOTSATT atgard - darfor skiljs de at i stallet for att bada far en warning.
    -- Diskriminatorn ar kommentarraden: repots kropp har den, driftens saknar den.
    -- Medvetet en textsokning och inte en md5 - en md5 pa repots fil hade brutit
    -- pa CRLF vid en Windows-utcheckning och gett fel diagnos.
    select p.prosrc into v_kropp from pg_proc p where p.oid = v_oid;
    if position('interna klick' in v_kropp) > 0 then
      perform set_config('migration32.lage', 'ateruppbyggnad', false);
      raise warning 'migration 32: search_path saknas och kroppen ar migration-3:s. Det ar en ATERUPPBYGGNAD ur repot - vantat, filen rattar den.';
    else
      raise exception 'migration 32 AVBRYTER: search_path saknas, men kroppen ar varken driftens eller migration-3:s. Laget ar okant och filen vagrar skriva over det. Las ut funktionen med pg_get_functiondef och avgor for hand.';
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Definitionen. Kroppen ar driftens, klausulen den som saknades i repot.
-- ---------------------------------------------------------------------------
create or replace function public.normalize_page_view()
 returns trigger
 language plpgsql
 set search_path to 'public'
as $function$
begin
  new.site := public.norm_host(new.site);
  if new.referrer is not null and public.norm_host(new.referrer) = new.site then
    new.referrer := null;
  end if;
  return new;
end $function$;

-- ---------------------------------------------------------------------------
-- EFTERKONTROLL - tva krav, och det andra kan faktiskt fyra
-- ---------------------------------------------------------------------------
do $$
declare
  v_oid oid;
  v_def_efter text;
  v_cfg text;
  v_def_fore text;
  v_lage text;
begin
  v_oid := to_regprocedure('public.normalize_page_view()');
  select md5(pg_get_functiondef(p.oid)), coalesce(array_to_string(p.proconfig, ','), '')
    into v_def_efter, v_cfg
    from pg_proc p
   where p.oid = v_oid;

  -- Krav 1: klausulen ska finnas. Last ur pg_catalog, inte ur filens egen text.
  if v_cfg <> 'search_path=public' then
    raise exception 'migration 32 AVBRYTER: proconfig ar "%" och inte "search_path=public" efter korningen. Definitionen tog inte.', coalesce(nullif(v_cfg, ''), '(tom)');
  end if;

  -- 🔴 Krav 2 far ALDRIG hoppas over tyst. `current_setting(..., true)` ger NULL
  -- i stallet for att fela nar GUC:en saknas - da hade villkoret nedan blivit
  -- falskt genom NULL i stallet for genom en bedomning, och slutraden hade anda
  -- sagt KLAR. Pa korarens vag (`psql -1 -f`, en session per fil) kan det inte
  -- hanta; kor nagon bara det HAR blocket for hand i SQL-editorn kan det.
  v_lage := current_setting('migration32.lage', true);
  v_def_fore := current_setting('migration32.def_fore', true);
  if v_lage is null or v_def_fore is null then
    raise exception 'migration 32 AVBRYTER: forkravets varden saknas, alltsa har det blocket inte kort i den har sessionen. Kor HELA filen i ett svep - halva filen ger ingen kontroll, bara sken av en.';
  end if;

  if v_lage = 'drift' then
    -- Har ska definitionen vara BYTE-IDENTISK. Det ar det enda som gor
    -- no-op-pastaendet provbart - utan det ar det bara ett pastaende.
    if v_def_fore <> v_def_efter then
      raise exception 'migration 32 AVBRYTER: funktionsdefinitionen ANDRADES i drift (md5 % -> %). 👉 Kontrollera FORST radsluten: kors filen fran en Windows-utcheckning med core.autocrlf=true hamnar CR i kroppen och md5 avviker utan att nagot verkligt skiljer. Stammer radsluten har driftens definition glidit fran den har filens - las ut den med pg_get_functiondef och avgor for hand.', v_def_fore, v_def_efter;
    end if;
    raise notice 'migration 32 KLAR - no-op-kravet KORDES och holl: definitionen ar byte-identisk (md5 %).', v_def_efter;

  else
    -- Ateruppbyggnad: kroppen SKA ha andrats (repots version bar en kommentarrad
    -- som driftens saknar), sa krav 2 galler inte. Slutraden maste saga att det
    -- HOPPADES OVER - annars kan den som laser loggen under en katastrofater-
    -- stallning inte skilja "kontrollerat och oforandrat" fran "aldrig kontrollerat".
    raise notice 'migration 32 KLAR - laget var ATERUPPBYGGNAD, sa no-op-kravet HOPPADES OVER med flit. Definitionen andrades fran md5 % till %, vilket ar meningen har.', v_def_fore, v_def_efter;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- VERIFIERING - kor detta efterat, oberoende av filens egna kontroller
-- ---------------------------------------------------------------------------
--   select array_to_string(proconfig, ',') as cfg,
--          md5(pg_get_functiondef(oid)) as def_md5
--     from pg_proc where oid = to_regprocedure('public.normalize_page_view()');
--   -- ska ge: search_path=public  och  33609944fe0aae8390c66bc6a42b6457
--
-- ⚠️ Anvand inte `like 'migration-3[2]%'` for att kolla liggaren - LIKE kanner
--    inte teckenklasser. Ratt form: `filnamn ~ '^migration-32-'`.
--
-- 📋 OBEKRAFTAT, sag inte att det ar provat: kor-migrationer.yml lyfter WARNING
--    till `::warning::` (rad 205-226) och koden laser ratt - men tystnads-
--    granskaren gick igenom samtliga 8 korningar av workflowet 2026-08-23 till
--    2026-09-05 och INGEN av dem innehaller en enda WARNING-annotering. Vagen ar
--    last, inte sedd fyra. Bygg inget som forutsatter att ett `raise warning`
--    syns for en manniska forran nagon matt att det gor det.
