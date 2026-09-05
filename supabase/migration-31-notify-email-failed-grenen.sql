-- Migration 31: notify_email:s failed-gren skrivs ned i repot
--
-- 📗 DOKUMENTATION, INTE EN BETEENDEANDRING. Samma sort som migration 29, och
-- medvetet SKILD fran migration 30, som andrade drift med flit. Blanda dem
-- aldrig i samma fil - migration 27 blev underkand tva ganger for just det.
--
-- VAD SOM SAKNAS OCH VARFOR DET AR FARLIGT
-- ========================================
-- Drift HAR en gren for `who.status = 'failed'` i notify_email. Repot har den
-- inte. Migration-23:s eget filhuvud varnar om saken, ordagrant:
--
--     "en gren för statusvärdet `failed` som INTE finns här. Körs den här
--      filen om försvinner den"
--
-- Det ar alltsa en KAND lucka som lag och vantade pa att nagon skulle kora om
-- migration 23 vid en ateruppbyggnad. Da hade kunden slutat fa besked nar ett
-- arende gar fel - tyst, for ingenting i koden hade larmat om att en gren
-- forsvunnit. En funktion som skickar farre mejl an forut ser likadan ut som en
-- som fungerar.
--
-- Matt i drift 2026-09-05 med `position('failed' in pg_get_functiondef(...))`:
-- grenen finns. Grentexten nedan ar HAMTAD ur drift, inte skriven for hand.
-- Resten av funktionen ar repots egen text ur migration 23, orord.
--
-- FORKRAVET ACCEPTERAR BADA LAGEN, med flit
-- ==========================================
-- I DRIFT ar filen en no-op: grenen finns redan, och en `create or replace` med
-- samma innehall andrar ingenting. VID EN ATERUPPBYGGNAD ur repot skapar
-- migration 23 funktionen UTAN grenen, och da ar det har filen som lagger dit
-- den. Bada ar ratt. Ett forkrav som bara accepterade det ena hade gjort repot
-- obyggbart - precis det migration 29 och kunskap-db-mot-repo.md finns for att
-- undvika.

set client_encoding to 'UTF8';

do $$
declare
  v_def text;
begin
  if to_regprocedure('public.notify_email()') is null then
    raise exception 'migration 31 AVBRYTER: notify_email() finns inte i drift. Filen ar skriven mot en funktion som ska finnas - kontrollera vad som hant innan du kor om.';
  end if;
  v_def := pg_get_functiondef(to_regprocedure('public.notify_email()'));
  if position('who.status = ''failed''' in v_def) > 0 then
    raise notice 'migration 31: failed-grenen finns REDAN i drift. Filen ar en no-op - det ar det vantade laget i produktion.';
  else
    -- Warning, inte notice: kor-migrationer.yml lyfter bara WARNING till en
    -- annotering. I en ateruppbyggnad ar det har normalt; i PRODUKTION betyder
    -- det att grenen forsvunnit sedan matningen, och det vill vi se.
    raise warning 'migration 31: failed-grenen SAKNAS i drift och laggs till av den har filen. Vantat vid en ateruppbyggnad ur repot - kontrollera varfor om du ser det i produktion.';
  end if;
end $$;

create or replace function public.notify_email()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  payload jsonb;
  who record;
  api_key text;
  subj text;
  html text;
  to_addr text := 'info@oakstride.se';
  to_arr jsonb := null;
begin
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'resend_api_key';
  if api_key is null then return new; end if;

  if tg_table_name = 'requests' and tg_op = 'INSERT' then
    select email, full_name, company into who from public.profiles where id = new.user_id;
    subj := 'Nytt ärende #' || new.id || ': ' || new.title;
    html := '<h2>Nytt ärende i portalen</h2>'
      || '<p><strong>Kund:</strong> ' || public.esc_html(coalesce(who.full_name, who.email))
      || coalesce(' (' || public.esc_html(who.company) || ')', '') || '<br>'
      || '<strong>Prioritet:</strong> ' || public.esc_html(new.priority)
      || coalesce('<br><strong>Sida:</strong> ' || public.esc_html(new.page_url), '') || '</p>'
      || '<p style="white-space:pre-wrap">' || public.esc_html(new.description) || '</p>'
      || '<p><a href="https://portal.oakstride.se">Öppna portalen</a></p>';

  elsif tg_table_name = 'requests' and tg_op = 'UPDATE' then
    select email, full_name into who from public.profiles where id = new.user_id;
    if new.status = 'draft_ready' then
      to_addr := who.email;
      subj := 'Ditt förslag är klart att granska — ärende #' || new.id;
      html := '<h2>Förslaget för "' || public.esc_html(new.title) || '" är klart!</h2>'
        || coalesce('<p><a href="' || public.esc_html(new.preview_url) || '">Se förhandsvisningen här</a></p>', '')
        || '<p>Logga in i <a href="https://portal.oakstride.se">portalen</a> för att godkänna eller begära ändringar.</p>';
    elsif new.status = 'questions' then
      to_addr := who.email;
      subj := 'Vi har frågor om ditt ärende #' || new.id;
      html := '<h2>Några frågor innan vi bygger vidare</h2>'
        || '<p>Ärendet "' || public.esc_html(new.title) || '" har fått frågor som väntar på dina svar.</p>'
        || '<p><a href="https://portal.oakstride.se">Svara i portalen</a></p>';
    elsif new.status = 'approved' then
      subj := 'Kund har godkänt förslag — ärende #' || new.id;
      html := '<h2>Godkänt av kund</h2>'
        || '<p>' || public.esc_html(coalesce(who.full_name, who.email)) || ' har godkänt förslaget för "'
        || public.esc_html(new.title) || '". Dags att publicera!</p>'
        || coalesce('<p><a href="' || public.esc_html(new.preview_url) || '">Förhandsvisning</a></p>', '')
        || '<p><a href="https://portal.oakstride.se">Öppna portalen</a></p>';
    else
      return new;
    end if;

  elsif tg_table_name = 'agreement_acceptances' then
    select email, full_name into who from public.profiles where id = new.user_id;
    to_arr := jsonb_build_array(who.email, 'info@oakstride.se');
    if new.order_summary is not null then
      subj := 'Orderbekräftelse — OakStride (villkor ' || new.agreement_version || ')';
      html := '<h2>Tack för din beställning!</h2>'
        || '<p>' || public.esc_html(coalesce(who.full_name, who.email)) || ' godkände offerten och <strong>'
        || public.esc_html(new.document_title) || '</strong> (version ' || public.esc_html(new.agreement_version)
        || ') den ' || to_char(new.accepted_at, 'YYYY-MM-DD" kl. "HH24:MI') || '.</p>'
        || '<div style="background:#f4f6f4;border-radius:8px;padding:12px 16px;margin:12px 0"><h3 style="margin:0 0 8px">Din order</h3>'
        || '<pre style="white-space:pre-wrap;font-family:inherit;margin:0">' || public.esc_html(new.order_summary) || '</pre></div>'
        || '<p>De fullständiga villkoren finns alltid i <a href="https://portal.oakstride.se">kundportalen</a>.</p>'
        || '<p style="color:#888;font-size:12px">Verifiering (dokument-hash): ' || public.esc_html(new.document_hash) || '</p>';
    else
      subj := 'Bekräftelse: avtal godkänt (' || new.agreement_version || ')';
      html := '<h2>Tack! Ditt avtal är godkänt</h2>'
        || '<p>' || public.esc_html(coalesce(who.full_name, who.email))
        || ' godkände <strong>' || public.esc_html(new.document_title)
        || '</strong> (version ' || public.esc_html(new.agreement_version) || ') den '
        || to_char(new.accepted_at, 'YYYY-MM-DD" kl. "HH24:MI') || '.</p>'
        || '<p>Detta mejl är din bekräftelse på godkännandet. De fullständiga villkoren finns alltid tillgängliga i <a href="https://portal.oakstride.se">kundportalen</a>.</p>'
        || '<p style="color:#888;font-size:12px">Verifiering (dokument-hash): ' || public.esc_html(new.document_hash) || '</p>';
    end if;

  elsif tg_table_name = 'profiles' then
    subj := 'Ny registrering i portalen: ' || new.email;
    html := '<h2>Nytt konto väntar på godkännande</h2>'
      || '<p>' || coalesce(public.esc_html(new.full_name), '') || ' &lt;' || public.esc_html(new.email) || '&gt;</p>'
      || '<p><a href="https://portal.oakstride.se">Godkänn i portalen</a></p>';

  elsif tg_table_name = 'request_comments' then
    if new.author_id is null then
      -- ÄNDRAT: hämta även ärendets status så systemkommentaren får rätt ämne.
      select p.email as email, r.status as status into who
      from public.requests r join public.profiles p on p.id = r.user_id
      where r.id = new.request_id;
      to_addr := who.email;
      if who.status = 'published' then
        subj := 'Din ändring är nu live — ärende #' || new.request_id;
        html := '<h2>🎉 Ändringen är publicerad</h2>'
          || '<p style="white-space:pre-wrap">' || public.esc_html(new.body) || '</p>'
          || '<p><a href="https://portal.oakstride.se">Se ärendet i portalen</a></p>';
      elsif who.status = 'failed' then
        subj := 'Vi tittar på ditt ärende #' || new.request_id;
        html := '<h2>Något gick inte som det skulle</h2>'
          || '<p style="white-space:pre-wrap">' || public.esc_html(new.body) || '</p>'
          || '<p>Du behöver inte göra något — OakStride har fått besked och tittar på det.</p>'
          || '<p><a href="https://portal.oakstride.se">Följ ärendet i portalen</a></p>';
      elsif who.status = 'draft_ready' then
        -- Kunden har redan fått "Ditt förslag är klart att granska" från requests-triggern.
        return new;
      else
        subj := 'Ny fråga om ditt ärende #' || new.request_id;
        html := '<h2>Vi behöver din input</h2>'
          || '<p style="white-space:pre-wrap">' || public.esc_html(new.body) || '</p>'
          || '<p><a href="https://portal.oakstride.se">Svara i portalen</a></p>';
      end if;
    else
      if (select is_admin from public.profiles where id = new.author_id) then return new; end if;
      select p.email, p.full_name into who from public.profiles p where p.id = new.author_id;
      subj := 'Nytt svar på ärende #' || new.request_id || ' från ' || coalesce(who.full_name, who.email);
      html := '<h2>Ny kommentar från kund</h2>'
        || '<p style="white-space:pre-wrap">' || public.esc_html(new.body) || '</p>'
        || '<p><a href="https://portal.oakstride.se">Svara i portalen</a></p>';
    end if;
  end if;

  payload := jsonb_build_object(
    'from', 'OakStride Portal <portal@oakstride.se>',
    'to', coalesce(to_arr, jsonb_build_array(to_addr)),
    'subject', subj,
    'html', html
  );
  begin
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      body := payload,
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || api_key)
    );
  exception when others then null;
  end;
  return new;
end;
$function$;

-- ---------------------------------------------------------------------------
-- EFTERKONTROLL - grenen ska finnas oavsett vilket lage vi startade fran
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
begin
  v_def := pg_get_functiondef(to_regprocedure('public.notify_email()'));
  if position('who.status = ''failed''' in v_def) = 0 then
    raise exception 'migration 31 AVBRYTER: failed-grenen finns INTE i notify_email efter korningen. Definitionen tog inte.';
  end if;
  if position('published' in v_def) = 0 then
    raise exception 'migration 31 AVBRYTER: published-grenen ar borta ur notify_email. Filen har skrivit over mer an den skulle - rulla tillbaka och jamfor mot migration 23.';
  end if;
  raise notice 'migration 31 KLAR - notify_email har bade published- och failed-grenen. Ingen beteendeandring i drift.';
end $$;

-- ---------------------------------------------------------------------------
-- VERIFIERING - kor detta efterat, oberoende av filens egna kontroller
-- ---------------------------------------------------------------------------
--   select position('who.status = ''failed''' in pg_get_functiondef(
--            to_regprocedure('public.notify_email()'))) > 0;   -- ska ge true
--
-- ⚠️ Anvand inte `like 'migration-3[1]%'` for att kolla liggaren - LIKE kanner
--    inte teckenklasser. Ratt form: `filnamn ~ '^migration-31-'`.
