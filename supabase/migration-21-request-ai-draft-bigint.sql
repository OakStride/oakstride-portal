-- Migration 21 (2026-08-15): BUGFIX request_ai_draft — fel parametertyp.
-- requests.id är bigint, men RPC:n deklarerades med uuid (migration ai_chat_request_draft_rpc,
-- 2026-07-28). PostgREST kunde därför aldrig anropa den från portalens AI-chatt
-- ("invalid input syntax for type uuid") → kundens AI-ändringar startade aldrig agenten,
-- och app.js svalde felet (kunden såg "AI:n arbetar…" för evigt). Hittat vid E2E-test 2026-08-15.
drop function if exists public.request_ai_draft(uuid, text);

create or replace function public.request_ai_draft(p_request_id bigint, p_reason text default 'draft')
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_owner uuid; v_is_admin boolean; v_count int; v_cap int := 15;
begin
  select user_id into v_owner from requests where id = p_request_id;
  if v_owner is null then return json_build_object('ok', false, 'error', 'not_found'); end if;
  select coalesce(is_admin,false) into v_is_admin from profiles where id = auth.uid();
  if v_owner <> auth.uid() and not v_is_admin then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  if not v_is_admin then
    select count(*) into v_count from agent_jobs aj
      join requests r on r.id = aj.request_id
      where r.user_id = v_owner and aj.created_at >= date_trunc('month', now());
    if v_count >= v_cap then
      return json_build_object('ok', false, 'error', 'monthly_cap', 'cap', v_cap);
    end if;
  end if;
  insert into agent_jobs(request_id, reason) values (p_request_id, coalesce(p_reason, 'draft'));
  return json_build_object('ok', true);
end $function$;
grant execute on function public.request_ai_draft(bigint, text) to authenticated;
