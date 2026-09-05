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
-- ⚠️ MEN INTE HELT. En granskare jamforde alla fem raderna falt for falt mot
-- kitets mallregister: **26 av 27 falt matchar ordagrant, ett gor det inte.**
--
--   hantverk.extra_fields[0].hint
--     kit   : "...Nytt betongpannetak pa 180 m2 med ny lakt"
--     drift : "...Nytt betongpannetak pa 180 m2"
--
-- Uppmatt i drift 2026-09-06: driften har den KORTA texten, alltsa den som star
-- i den har filen. Det ar allts inte ett avskrivningsfel utan ETT NYTT GLAPP at
-- andra hallet - kitet uppdaterades efter att raden seedades, och tabellen foljde
-- inte med. Filen dokumenterar drift korrekt; den loser inte den skillnaden.
--
-- 👉 Att stalla dem mot varandra hor hemma i issue #60, inte har. Den som gor det
-- ska veta att kitets text bara ar en LEDTRAD i portalens dropdown - den styr
-- ingenting i bygget - sa avvikelsen ar kosmetisk och inte bradskande.
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

  -- 🔴 RATTAT efter granskning. Forsta versionen hade TVA lagen: "stammer" och
  -- "stammer inte", dar det andra bara varnade och sedan skrev over. Effekten var
  -- att en AVSIKTLIG andring i drift - t.ex. att nagon inaktiverat en malltyp -
  -- tyst backades av den har filen, med gron korning och bokforing i liggaren.
  -- Efterkontrollen kunde inte fanga det, eftersom upserten just gjort dess
  -- konstant sann. En kontroll som atgarden sjalv uppfyller ar ingen kontroll.
  --
  -- De tva LEGITIMA lagen ar atskiljbara, sa de skiljs at. Allt annat avbryter.
  if v_md5 = '60de30e057011cc72317c756462ec443' then
    perform set_config('migration33.lage', 'drift', false);
    raise notice 'migration 33: innehallet ar redan driftens (5 rader, md5 stammer). Filen ar en no-op - vantat i produktion.';

  elsif v_md5 = '4387f70c7e7e10a285be70da5e6d9e14' then
    -- Exakt vad migration-20 ENSAM lamnar efter sig: tre rader, gamla etiketter.
    -- Uppmatt 2026-09-06 genom att kora migration-20:s seed i en CTE.
    perform set_config('migration33.lage', 'ateruppbyggnad', false);
    raise warning 'migration 33: tabellen innehaller exakt migration-20:s tre rader. Det ar en ATERUPPBYGGNAD ur repot - filen fyller pa till driftens fem.';

  else
    raise exception 'migration 33 AVBRYTER: innehallet ar varken driftens (md5 60de30e057011cc72317c756462ec443, 5 rader) eller migration-20:s (md5 4387f70c7e7e10a285be70da5e6d9e14, 3 rader). Uppmatt nu: % rader, md5 %. Nagon har ANDRAT mallistan sedan 2026-09-06 - kanske inaktiverat en malltyp eller lagt till en. Filen skulle backa den andringen tyst och sedan bokforas som lyckad. Mat om vad som galler och skriv en NY migration; andra inte den har.', v_antal, coalesce(v_md5, '(tom tabell)');
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

  -- Sag vilket lage det VAR, hamtat ur forkontrollens matning - gissa inte ur
  -- md5:n efterat, for da ser bada lagen likadana ut.
  v_fore := current_setting('migration33.lage', true);
  if v_fore = 'drift' then
    raise notice 'migration 33 KLAR - no-op bekraftad: innehallet var redan driftens och ar oforandrat.';
  elsif v_fore = 'ateruppbyggnad' then
    raise notice 'migration 33 KLAR - ateruppbyggnad: tabellen gick fran migration-20:s tre rader till driftens fem.';
  else
    raise exception 'migration 33 AVBRYTER: forkontrollens lage saknas, alltsa har det blocket inte kort i den har sessionen. Kor HELA filen i ett svep.';
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
