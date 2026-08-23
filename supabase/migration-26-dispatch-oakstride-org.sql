-- Migration 26: dispatch-URL:erna pekar på gamla ägaren efter GitHub-org-flytten
--
-- BAKGRUND
-- Alla åtta repon flyttades till orgen `OakStride` 2026-08-23. Portalens dispatch-funktioner
-- postar till `https://api.github.com/repos/Lifewaver/oakstride-agent/dispatches`, alltså den
-- gamla sökvägen.
--
-- VARFÖR DET INTE SYNS NÄR DET GÅR SÖNDER — läs detta innan du bedömer brådskan:
--   * GitHub svarar 301 på en flyttad repo-sökväg.
--   * `pg_net` följer som regel inte omdirigering på en POST, och en POST som får 301 återsänds
--     inte automatiskt.
--   * `pg_net` är fire-and-forget. Det finns INGEN felväg som larmar.
-- Bygget skulle alltså tystna utan att någonstans säga ifrån. Ingen kund drabbas i dag — portalen
-- har ingen betalande kund — men felet infaller tyst, första gången någon faktiskt köper.
--
-- ⚠️ OPRÖVAT: att `pg_net` faktiskt fallerar på 301 är INTE bevisat. Att bevisa det kräver en
-- skarp dispatch, vilket startar ett riktigt bygge. Statuskoden går att läsa i `net._http_response`
-- efter första riktiga dispatchen — gör det, och skriv in utfallet.
-- (Kontrollerat 2026-08-23: tabellen innehöll fyra rader, alla från 2026-08-16 med 204 och 200.
--  Ingen dispatch hade alltså avfyrats sedan flytten.)
--
-- ⚠️ DET ÄR FYRA FUNKTIONER, INTE TVÅ. Migrationsfilerna `migration-2-agent.sql` och
-- `migration-16-build-jobs.sql` innehåller bara två av dem. Läst i drift med `pg_get_functiondef`
-- över `pg_proc` 2026-08-23 finns fyra: `dispatch_agent`, `dispatch_build_site`,
-- `dispatch_publish_site`, `request_publish_change`. En migration skriven efter filerna hade lagat
-- hälften och lämnat två vägar trasiga — tyst, vilket är exakt felmodet ovan.
--
-- 🚫 RÖR INTE `Lifewaver/jarvis`. Hubbens repo ligger kvar hos Lifewaver. Ersättningen nedan är
-- avgränsad till den exakta strängen `Lifewaver/oakstride-agent` och kan därför inte träffa den.
-- Kontrollerat 2026-08-23: ingen funktion i `public` refererar `Lifewaver/jarvis` — samtliga fyra
-- träffar på `Lifewaver` är `Lifewaver/oakstride-agent`.
--
-- ⚠️ TVÅ AV DE FYRA HAR INGEN MIGRATIONSFIL ÖVER HUVUD TAGET.
-- `dispatch_agent` definieras i `migration-2-agent.sql`, `dispatch_build_site` i
-- `migration-16-build-jobs.sql`. `dispatch_publish_site` och `request_publish_change` finns i
-- produktionsdatabasen men saknas i repot — de har skapats utanför migrationsflödet, sannolikt
-- direkt i SQL-editorn. **Repot beskriver alltså inte databasen fullständigt**, och en
-- återuppbyggnad från migrationerna skulle sakna två funktioner. Det är ett eget problem som
-- överlever den här migrationen; den lagar adressen, inte luckan.
-- Just därför läser migrationen ur databasen i stället för ur filerna: hade den utgått från
-- filerna hade den inte ens kunnat se två av de fyra.
--
-- METOD
-- Funktionerna skrivs INTE om för hand. De bär villkorslogik, nyckelhämtning och payloads som
-- inte får gå förlorade. I stället läses varje funktions nuvarande definition ut ur databasen och
-- enbart ägarsegmentet byts. Samma mönster som migration 25 använder på `notify_email`.
--
-- Migrationen är idempotent, och den HAVERERAR hellre än att tyst göra ingenting: hittas varken
-- gamla eller nya adressen kastas ett fel i stället för att lämna databasen orörd medan alla tror
-- att den ändrats.

do $mig$
declare
  r          record;
  def        text;
  ny         text;
  bytta      int := 0;
  redan_ratt int := 0;
begin
  -- Räkna först dem som redan pekar rätt, så en andra körning kan skilja
  -- "redan gjort" från "hittade ingenting alls".
  select count(*) into redan_ratt
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind = 'f'
    and pg_get_functiondef(p.oid) like '%api.github.com/repos/OakStride/oakstride-agent%';

  for r in
    select p.oid, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and pg_get_functiondef(p.oid) like '%Lifewaver/oakstride-agent%'
    order by p.proname
  loop
    def := pg_get_functiondef(r.oid);
    ny  := replace(def, 'Lifewaver/oakstride-agent', 'OakStride/oakstride-agent');

    if ny = def then
      raise exception
        'Migration 26: funktionen %() matchade sökningen men ersättningen gav ingen ändring. '
        'Inget har ändrats i den. Läs ut den med pg_get_functiondef och gör bytet för hand.',
        r.proname;
    end if;

    execute ny;
    bytta := bytta + 1;
    raise notice 'Migration 26: %() pekar nu på OakStride.', r.proname;
  end loop;

  if bytta = 0 then
    if redan_ratt > 0 then
      raise notice 'Migration 26: redan körd — % funktion(er) pekar på OakStride. Hoppar över.',
        redan_ratt;
    else
      raise exception
        'Migration 26: hittade INGEN funktion i public som refererar Lifewaver/oakstride-agent, '
        'och ingen som refererar OakStride/oakstride-agent heller. Något stämmer inte — '
        'kontrollera schemat innan du kör om. Inget har ändrats.';
    end if;
  else
    raise notice 'Migration 26: % funktion(er) omskrivna. Förväntat antal 2026-08-23 var 4.', bytta;
  end if;
end
$mig$;

-- ---------------------------------------------------------------------------
-- VERIFIERING efter körning
-- ---------------------------------------------------------------------------
-- 1. Ska ge 4 rader, alla med OakStride/oakstride-agent:
--
--   select p.proname,
--          substring(pg_get_functiondef(p.oid) from 'api\.github\.com/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+')
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and p.prokind = 'f'
--     and pg_get_functiondef(p.oid) like '%api.github.com%'
--   order by p.proname;
--
-- 2. Ska ge NOLL rader (inget får peka på gamla ägaren längre):
--
--   select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and p.prokind = 'f'
--     and pg_get_functiondef(p.oid) like '%Lifewaver/oakstride-agent%';
--
-- 3. Det riktiga provet — efter nästa skarpa dispatch, läs statuskoden:
--
--   select id, status_code, error_msg, created from net._http_response order by id desc limit 5;
--
--   204 = dispatchen togs emot. 301 = adressen är fortfarande fel. Ingen ny rad alls = anropet
--   gick aldrig iväg, och då är felet någon annanstans än här.
