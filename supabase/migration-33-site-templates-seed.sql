-- Migration 33: site_templates-seeden skrivs ned som den FAKTISKT ser ut i drift
--
-- 📗 DOKUMENTATION AV DRIFT. Filen ska inte andra nagonting i produktion - den
-- skriver ned det som redan star dar. Samma sort som migration 29 och 32, och
-- medvetet SKILD fran migration 30, som andrade drift med flit.
--
--
-- VARFOR: ETT GLAPP INGEN KARTLAGGNING HAR LETAT EFTER
-- ====================================================
-- 🔴 `driftkartlaggaren` jamforde 2026-09-05 tabeller, funktioner, policyer,
-- triggers, enum, index och grants - och rapporterade att allt stammer utom EN
-- klausul. **Den jamforde aldrig RADINNEHALL.**
--
-- `site_templates` styr vilka grundmallar som gar att valja i portalens
-- "Bygg sajt"-formular. Tabellen finns i bada; den ar bara FYLLD OLIKA:
--
--   migration-20 (repot) : 3 rader - generisk, restaurang, frisor
--   drift                : 5 rader - de tre plus hantverk och konsult
--
-- Och de tre som finns pa bada stallen har OCKSA glidit. Alla fem rader skiljer
-- sig alltsa fran repot:
--
--   generisk    label lika, men description "Standardlayout for alla segment."
--               mot driftens "Ren standardmall: hero, tjanster, om, ..."
--   restaurang  "Restaurang (meny..." mot "Restaurang & Cafe (meny..."
--   frisor      "...boka tid)" mot "...boka online)"
--   hantverk    saknas helt i repot
--   konsult     saknas helt i repot
--
-- 👉 En ateruppbyggnad ur repot hade gett en portal dar **hantverk och konsult
-- inte gar att valja**, och dar de ovriga tre har foraldrade etiketter. Schemat
-- hade stamt perfekt. Sajten hade startat. Tva av fem malltyper hade bara varit
-- borta.
--
-- ⚠️ **Detta hittades av en SLUMP** - under en kodgranskning i studio-kit, nar en
-- granskare bad mig mata om mallnycklarna fanns i drift innan en ny grind
-- mergades. Ingen kontroll letade efter det. Fler seed-tabeller kan skilja sig
-- utan att nagon vet. Atgardsforslag och uppfoljning: portal-repots issue #60.
--
-- 📌 FOLJD FOR ATERUPPBYGGNADSPROVET (issue #61): ett prov som bara jamfor
-- SCHEMA hade gett falskt godkant har. Det ar vart att veta innan provet byggs.
--
--
-- VILKEN SIDA GALLER
-- ==================
-- Driftens. Etiketterna dar matchar vad Studio Kit faktiskt bygger - kitets egen
-- utdata sager "Grundmall: Restaurang & Cafe (meny + bordsbokning)", alltsa
-- driftens formulering och inte repots. Repot ar efter, inte fore.
--
-- Uppmatt 2026-09-06: 5 rader, innehalls-md5 60de30e057011cc72317c756462ec443.
-- VARDENA NEDAN AR FORMATERADE AV DATABASEN sjalv med `format('%L', ...)`, inte
-- avskrivna for hand - avskrift av fem rader svensk prosa och inbaddad JSON ar
-- precis den sortens moment dar ett tecken forsvinner utan att nagon ser det.

set client_encoding to 'UTF8';

-- ---------------------------------------------------------------------------
-- FORKRAV - laser pg, pastar ingenting
-- ---------------------------------------------------------------------------
do $$
declare
  v_antal int;
  v_md5 text;
begin
  if to_regclass('public.site_templates') is null then
    raise exception 'migration 33 AVBRYTER: site_templates finns inte. Kor migration 20 forst.';
  end if;

  select count(*),
         md5(string_agg(key || '|' || label || '|' || coalesce(description, '') || '|' ||
                        sort::text || '|' || extra_fields::text || '|' || active::text,
                        E'\n' order by key))
    into v_antal, v_md5
    from public.site_templates;

  perform set_config('migration33.md5_fore', coalesce(v_md5, '(tom tabell)'), false);

  if v_md5 = '60de30e057011cc72317c756462ec443' then
    raise notice 'migration 33: innehallet ar redan driftens (5 rader, md5 stammer). Filen ar en no-op - vantat i produktion.';
  else
    -- WARNING och inte notice: vid en ateruppbyggnad ar det har normalt, men i
    -- PRODUKTION betyder det att nagon andrat mallistan sedan matningen.
    raise warning 'migration 33: innehallet skiljer sig fran matningen 2026-09-06 (% rader, md5 %). Vantat vid en ateruppbyggnad. Ser du det i produktion har nagon andrat mallistan - kontrollera att overskrivningen nedan ar onskad.', v_antal, coalesce(v_md5, '(tom)');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Seeden. `on conflict do update` gor filen idempotent och ofarlig att kora om.
-- ⚠️ Restaurangraden bar ett bakstreck (JSON-radbrytning i hint-texten). Databasens
-- egen `format()` gav en E-strang for den; jag skriver den som en VANLIG strang i
-- stallet. Med standard_conforming_strings pa - default sedan lange - ar bakstrecket
-- da literalt, precis som JSON vill ha det. En E-strang hade krävt dubblade bakstreck
-- och ar exakt det lager dar ett tecken forsvinner utan att nagon ser det.
-- ---------------------------------------------------------------------------
insert into public.site_templates (key, label, description, sort, extra_fields, active) values
  ('generisk', 'Generisk', 'Ren standardmall: hero, tjänster, om, galleri, omdömen, kontakt.', 10, '[]'::jsonb, true),
  ('hantverk', 'Hantverk & Bygg (offert + referensprojekt)', 'Bygg/hantverk: hero, trygghetssiffror, tjänster, referensprojekt, så-går-det-till, om, omdömen, FAQ, offert.', 15, '[{"key": "projectsText", "hint": "Ex: Takbyte villa, Ekerö | Nytt betongpannetak på 180 m²", "type": "lines", "label": "Referensprojekt (en rad per projekt: Titel | kort beskrivning)"}]'::jsonb, true),
  ('restaurang', 'Restaurang & Café (meny + bordsbokning)', 'Restaurang/café: hero, boka bord + öppettider, meny med kategorier, om/koncept, galleri, omdömen, FAQ, kontakt.', 20, '[{"key": "menu", "hint": "Ex:\n## Förrätter\nToast Skagen | 165 kr | Handskalade räkor, dill, löjrom", "type": "lines", "label": "Meny (kategori: ## Förrätter · rätt: Rätt | pris | beskrivning)"}]'::jsonb, true),
  ('frisor', 'Frisör & Skönhet (prislista + boka online)', 'Skönhet/friskvård: hero, behandlingar, prislista, boka online, om/teamet, galleri, omdömen, FAQ, kontakt.', 30, '[{"key": "priceList", "hint": "Ex: Klippning dam | från 595 kr | Inkl. tvätt & föning", "type": "lines", "label": "Prislista (en rad per tjänst: Tjänst | pris | ev. notering)"}]'::jsonb, true),
  ('konsult', 'Konsult & B2B (case + boka möte)', 'Konsult/tjänsteföretag: hero, siffror, tjänster, så-vi-jobbar, kundcase, om/expertis, omdömen, FAQ, boka möte.', 40, '[{"key": "casesText", "hint": "Ex: Tillverkningsbolag, 40 anställda | Manuell orderhantering gav förseningar | Ledtiden minskade 35 %", "type": "lines", "label": "Kundcase (en rad per case: Rubrik | utmaning | resultat)"}]'::jsonb, true)
on conflict (key) do update set
  label        = excluded.label,
  description  = excluded.description,
  sort         = excluded.sort,
  extra_fields = excluded.extra_fields,
  active       = excluded.active;

-- ---------------------------------------------------------------------------
-- EFTERKONTROLL - samma krav i BADA lagen, och det kan ga rott
-- ---------------------------------------------------------------------------
-- Efter korningen ska innehallet vara identiskt med matningen, oavsett om vi
-- startade fran drift (da andrades ingenting) eller fran en ateruppbyggnad (da
-- fylldes tabellen). Ett enda krav som taeker bada vagarna, och som fyrar pa
-- allt fran ett tappt tecken i prosan till en rad som inte skrevs.
do $$
declare
  v_antal int;
  v_md5 text;
  v_fore text;
begin
  select count(*),
         md5(string_agg(key || '|' || label || '|' || coalesce(description, '') || '|' ||
                        sort::text || '|' || extra_fields::text || '|' || active::text,
                        E'\n' order by key))
    into v_antal, v_md5
    from public.site_templates;

  if v_antal <> 5 then
    raise exception 'migration 33 AVBRYTER: % rader i site_templates efter korningen, vantat 5. Insert:en tog inte, eller nagot annat skriver i tabellen.', v_antal;
  end if;

  if v_md5 is distinct from '60de30e057011cc72317c756462ec443' then
    raise exception 'migration 33 AVBRYTER: innehalls-md5 ar % efter korningen, vantat 60de30e057011cc72317c756462ec443 (uppmatt i drift 2026-09-06). Nagon rad skiljer sig - jamfor key, label, description, sort, extra_fields och active mot filen ovan.', coalesce(v_md5, '(tom)');
  end if;

  v_fore := current_setting('migration33.md5_fore', true);
  if v_fore = '60de30e057011cc72317c756462ec443' then
    raise notice 'migration 33 KLAR - no-op bekraftad: innehallet var redan driftens och ar oforandrat.';
  else
    raise notice 'migration 33 KLAR - tabellen fylldes till driftens innehall (md5 % -> %). Det ar meningen vid en ateruppbyggnad.', coalesce(v_fore, '(okant)'), v_md5;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- VERIFIERING - kor detta efterat, oberoende av filens egna kontroller
-- ---------------------------------------------------------------------------
--   select count(*),
--          md5(string_agg(key||'|'||label||'|'||coalesce(description,'')||'|'||
--                         sort::text||'|'||extra_fields::text||'|'||active::text,
--                         E'\n' order by key))
--     from public.site_templates;
--   -- ska ge: 5  och  60de30e057011cc72317c756462ec443
--
-- ⚠️ Anvand `filnamn ~ '^migration-33-'` mot liggaren, inte LIKE med teckenklass.
