-- Migration 23 (2026-08-16): BUGFIX kundmejl vid systemkommentar.
-- notify_email() skickade ALLA kommentarer med author_id is null (= agentens/systemets
-- kommentarer) som "Ny fråga om ditt ärende #N" / "<h2>Vi behöver din input</h2>",
-- även när texten var "🎉 Din ändring är nu live". Hittat i E2E-testet av Lansera direkt
-- 2026-08-15/16 (ärende #8).
--
-- Ändring, enbart i grenen tg_table_name = 'request_comments' / author_id is null:
--   1. Ärendets status hämtas med (publish-change.yml PATCH:ar status FÖRE kommentaren).
--   2. status = 'published'   → eget ämne + rubrik om att ändringen är live.
--   3. status = 'draft_ready' → INGET mejl härifrån: requests-UPDATE-triggern har redan
--      skickat "Ditt förslag är klart att granska" (annars får kunden två mejl om samma sak).
--   4. Övriga statusar → oförändrat "Ny fråga om ditt ärende".
-- Resten av funktionen är identisk med tidigare version.

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
