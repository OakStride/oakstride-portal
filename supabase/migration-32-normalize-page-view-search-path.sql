-- Migration 32: normalize_page_view() far sin search_path-klausul i repot
--
-- 📗 DOKUMENTATION AV DRIFT. Filen andrar ingenting i produktion - den skriver
-- ned det som redan kors dar, sa att en ateruppbyggnad ur repot ger samma
-- funktion. Samma sort som migration 29, och medvetet SKILD fran migration 30,
-- som andrade drift med flit. Blanda dem aldrig i samma fil; migration 27 blev
-- underkand tva ganger for just det.
--
-- ⚠️ NUMMER 31 ar hoppat over MED FLIT. En tidigare fil med det numret
-- (`migration-31-notify-email-failed-grenen.sql`) byggdes 2026-09-05 pa en
-- FELAKTIG premiss, underkandes i granskning och stangdes utan merge - se
-- PR #63. Den nadde aldrig main och ar aldrig bokford. Numret ateranvands inte,
-- sa att ingen som laser liggaren i efterhand blandar ihop dem.
--
-- VAD SOM SKILJER, MATT 2026-09-05
-- =================================
--   Drift : LANGUAGE plpgsql SET search_path TO 'public'
--   Repot : language plpgsql              (ingen klausul, migration-3-stats.sql)
--
-- Driftkartlaggaren korde om hela jamforelsen 2026-09-05 efter att migration 29
-- och 30 gatt i drift. Utfall: 21 av 21 tabeller, 32 av 32 funktioner och 55 av
-- 55 policies stammer mot repot. **Det har ar den enda kvarvarande avvikelsen.**
--
-- Risken ar LAG och ska inte overdrivas: funktionen ar INTE `security definer`,
-- och den anropar `public.norm_host` schemakvalificerat. Men en ateruppbyggnad
-- ur repot skulle skapa den utan klausulen, och da beskriver repot inte
-- databasen. Det ar hela poangen med det har projektet.
--
-- Fredriks beslut 2026-09-05 (issue #58): **driftens version galler.**
--
-- 🔬 KROPPEN AR HAMTAD UR DRIFT, INTE UR REPOT
-- =============================================
-- Driftens `prosrc` saknar kommentarraden `-- interna klick ar inte referrals`
-- som star i migration-3. Kommentarer LAGRAS i prosrc, sa driftens funktion har
-- alltsa aldrig skapats ur migration-3:s text ordagrant - nagon har redefinerat
-- den. Skriver vi in repots kropp har hade vi ANDRAT drift (lagt tillbaka
-- kommentaren) i en fil som utger sig for att vara en no-op.
--
-- Darfor ar kroppen nedan driftens, tecken for tecken. Uppmatt:
--   md5(prosrc) = b4786aafa5a1f95a9f5c3dd31b911ae6, 184 tecken, inga kommentarer.

set client_encoding to 'UTF8';

-- ---------------------------------------------------------------------------
-- FORKRAV - och det MATER, det pastar inte
-- ---------------------------------------------------------------------------
-- Lardom fran samma dag: ett forkrav som letar efter en strang som star i filens
-- egen kropp kan aldrig ga rott. Det har laser pg_catalog fore skrivningen och
-- sparar utfallet, sa att efterkontrollen har nagot ATT JAMFORA MOT.
do $$
declare
  v_md5 text;
  v_cfg text;
begin
  if to_regprocedure('public.normalize_page_view()') is null then
    raise exception 'migration 32 AVBRYTER: normalize_page_view() finns inte i drift. Filen ar skriven mot en funktion som ska finnas - kontrollera vad som hant innan du kor om.';
  end if;

  select md5(p.prosrc), coalesce(array_to_string(p.proconfig, ','), '')
    into v_md5, v_cfg
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'normalize_page_view';

  perform set_config('migration32.prosrc_fore', v_md5, false);
  perform set_config('migration32.hade_search_path',
                     case when position('search_path' in v_cfg) > 0 then 'ja' else 'nej' end,
                     false);

  if position('search_path' in v_cfg) > 0 then
    raise notice 'migration 32: search_path finns REDAN (%). Filen ar en no-op - det ar det vantade laget i produktion.', v_cfg;
  else
    -- WARNING och inte notice: kor-migrationer.yml lyfter bara WARNING till en
    -- annotering. Vid en ateruppbyggnad ar det har normalt; i PRODUKTION betyder
    -- det att klausulen forsvunnit sedan matningen, och det vill vi se.
    raise warning 'migration 32: search_path SAKNAS och satts av den har filen. Vantat vid en ateruppbyggnad ur repot - kontrollera varfor om du ser det i produktion.';
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
  v_md5_efter text;
  v_cfg text;
  v_fore text;
  v_hade text;
begin
  select md5(p.prosrc), coalesce(array_to_string(p.proconfig, ','), '')
    into v_md5_efter, v_cfg
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'normalize_page_view';

  -- Krav 1: klausulen ska finnas. Last ur pg_catalog, inte ur filens egen text.
  if position('search_path=public' in v_cfg) = 0 then
    raise exception 'migration 32 AVBRYTER: search_path saknas fortfarande efter korningen (proconfig = %). Definitionen tog inte.', coalesce(nullif(v_cfg, ''), '(tom)');
  end if;

  -- Krav 2: i DRIFT far kroppen inte ha andrats. Det ar det enda som gor
  -- "no-op"-pastaendet provbart - utan det ar det bara ett pastaende.
  -- Vid en ateruppbyggnad SKA kroppen andras (repots version har en kommentarrad
  -- som driftens saknar), sa kravet galler bara nar klausulen redan fanns.
  v_fore := current_setting('migration32.prosrc_fore', true);
  v_hade := current_setting('migration32.hade_search_path', true);
  if v_hade = 'ja' and v_fore is not null and v_fore <> v_md5_efter then
    raise exception 'migration 32 AVBRYTER: funktionskroppen ANDRADES i drift (md5 % -> %). Filen skulle bara lagga till en klausul, alltsa har driftens kropp glidit fran den har filens. Las ut den med pg_get_functiondef och avgor for hand vad som ska galla.', v_fore, v_md5_efter;
  end if;

  raise notice 'migration 32 KLAR - normalize_page_view har search_path=public och en oforandrad kropp.';
end $$;

-- ---------------------------------------------------------------------------
-- VERIFIERING - kor detta efterat, oberoende av filens egna kontroller
-- ---------------------------------------------------------------------------
--   select proname, array_to_string(proconfig, ','), md5(prosrc)
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname='public' and proname='normalize_page_view';
--   -- ska ge: search_path=public  och  b4786aafa5a1f95a9f5c3dd31b911ae6
--
-- ⚠️ Anvand inte `like 'migration-3[2]%'` for att kolla liggaren - LIKE kanner
--    inte teckenklasser. Ratt form: `filnamn ~ '^migration-32-'`.
