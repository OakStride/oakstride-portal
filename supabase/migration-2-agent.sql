-- Migration 2: Claude-agentflöde — frågor, utkast, godkännande
-- Körs i Supabase SQL Editor efter schema.sql.

-- ---------- Nya statusar och kolumner ----------

alter table public.requests drop constraint requests_status_check;
alter table public.requests add constraint requests_status_check
  check (status in ('new','in_progress','questions','draft_ready','approved','waiting_customer','done'));

alter table public.requests add column if not exists preview_url text;
alter table public.profiles add column if not exists github_repo text;

-- Claude-kommentarer har ingen användarprofil — author_id blir null + etikett
alter table public.request_comments alter column author_id drop not null;
alter table public.request_comments add column if not exists author_label text;

-- ---------- Jobbkö: varje rad triggar en Claude-körning i GitHub Actions ----------

create table if not exists public.agent_jobs (
  id bigint generated always as identity primary key,
  request_id bigint not null references public.requests(id) on delete cascade,
  reason text not null default 'draft',
  created_at timestamptz not null default now()
);
alter table public.agent_jobs enable row level security;
create policy "agent_jobs: admin" on public.agent_jobs
  for all using (public.is_admin()) with check (public.is_admin());

create or replace function public.dispatch_agent()
returns trigger language plpgsql security definer set search_path = public as $$
declare pat text;
begin
  select decrypted_secret into pat from vault.decrypted_secrets where name = 'github_pat';
  if pat is null then return new; end if;
  begin
    perform net.http_post(
      url := 'https://api.github.com/repos/OakStride/oakstride-agent/dispatches',
      body := jsonb_build_object(
        'event_type', 'claude-draft',
        'client_payload', jsonb_build_object('request_id', new.request_id, 'reason', new.reason)
      ),
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || pat,
        'Accept', 'application/vnd.github+json',
        'Content-Type', 'application/json',
        'User-Agent', 'oakstride-portal'
      )
    );
  exception when others then null;
  end;
  return new;
end; $$;

create trigger agent_jobs_dispatch after insert on public.agent_jobs
  for each row execute function public.dispatch_agent();

-- Kundsvar under 'questions' eller 'draft_ready' skickar automatiskt tillbaka ärendet till Claude
create or replace function public.on_customer_comment()
returns trigger language plpgsql security definer set search_path = public as $$
declare st text;
begin
  if new.author_id is null then return new; end if;                -- Claude själv
  if (select is_admin from public.profiles where id = new.author_id) then return new; end if;
  select status into st from public.requests where id = new.request_id;
  if st in ('questions','draft_ready') then
    update public.requests set status = 'in_progress' where id = new.request_id;
    insert into public.agent_jobs (request_id, reason)
      values (new.request_id, case when st = 'questions' then 'answers' else 'revision' end);
  end if;
  return new;
end; $$;

create trigger comment_requeues_agent after insert on public.request_comments
  for each row execute function public.on_customer_comment();

-- ---------- Kunden får godkänna utkast (men inget annat) ----------

create policy "requests: kund godkänner utkast" on public.requests
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.protect_request_cols()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    -- Kunder får bara godkänna ett färdigt utkast — allt annat återställs
    if old.status = 'draft_ready' and new.status = 'approved' then
      new := old; new.status := 'approved';
    else
      new := old;
    end if;
  end if;
  return new;
end; $$;

create trigger protect_request_cols before update on public.requests
  for each row execute function public.protect_request_cols();

-- ---------- Utökade mejlaviseringar ----------
-- Kund aviseras: Claude-frågor, förslag klart. Admin aviseras: godkännande (+ befintliga).

create or replace function public.notify_email()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  payload jsonb;
  who record;
  api_key text;
  subj text;
  html text;
  to_addr text := 'info@oakstride.se';
begin
  select decrypted_secret into api_key
    from vault.decrypted_secrets where name = 'resend_api_key';
  if api_key is null then
    return new;
  end if;

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

  elsif tg_table_name = 'profiles' then
    subj := 'Ny registrering i portalen: ' || new.email;
    html := '<h2>Nytt konto väntar på godkännande</h2>'
      || '<p>' || coalesce(public.esc_html(new.full_name), '') || ' &lt;' || public.esc_html(new.email) || '&gt;</p>'
      || '<p><a href="https://portal.oakstride.se">Godkänn i portalen</a></p>';

  elsif tg_table_name = 'request_comments' then
    if new.author_id is null then
      -- Claude ställer frågor → avisera kunden
      select p.email into who from public.requests r
        join public.profiles p on p.id = r.user_id where r.id = new.request_id;
      to_addr := who.email;
      subj := 'Ny fråga om ditt ärende #' || new.request_id;
      html := '<h2>Vi behöver din input</h2>'
        || '<p style="white-space:pre-wrap">' || public.esc_html(new.body) || '</p>'
        || '<p><a href="https://portal.oakstride.se">Svara i portalen</a></p>';
    else
      if (select is_admin from public.profiles where id = new.author_id) then
        return new;
      end if;
      select p.email, p.full_name into who
        from public.profiles p where p.id = new.author_id;
      subj := 'Nytt svar på ärende #' || new.request_id || ' från ' || coalesce(who.full_name, who.email);
      html := '<h2>Ny kommentar från kund</h2>'
        || '<p style="white-space:pre-wrap">' || public.esc_html(new.body) || '</p>'
        || '<p><a href="https://portal.oakstride.se">Svara i portalen</a></p>';
    end if;
  end if;

  payload := jsonb_build_object(
    'from', 'OakStride Portal <portal@oakstride.se>',
    'to', jsonb_build_array(to_addr),
    'subject', subj,
    'html', html
  );

  begin
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      body := payload,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || api_key
      )
    );
  exception when others then
    null;
  end;
  return new;
end;
$$;

create trigger notify_status_change after update of status on public.requests
  for each row when (old.status is distinct from new.status)
  execute function public.notify_email();
