-- Migration 24: skydda profiles.github_repo mot ändring av kunden själv
--
-- BAKGRUND (granskning 2026-08-18, punkt B9)
-- Agentens workflows läser profiles.github_repo och använde värdet i ett run:-block
-- (publish-change.yml rad 55 m.fl.). Kolumnen kunde sättas av kunden själv:
--   * `authenticated` har UPDATE-grant på kolumnen
--   * RLS "profiles: uppdatera egen eller admin" släpper egen rad
--   * protect_profile_cols återställde sju kolumner men INTE github_repo
-- Tillsammans gav det script injection i GitHub Actions med REPO_PAT i miljön.
--
-- Workflow-sidan härdas separat (oakstride-agent, gren fix/actions-script-injection):
-- alla DB-värden går numera via env: i stället för ${{ }} i run:. Den här migrationen
-- är ANDRA spärren: kunden ska aldrig kunna peka om sitt repo, oavsett hur värdet
-- sedan används.
--
-- PÅVERKAR INTE AGENTEN: build-site.yml sätter github_repo med service_role-nyckeln,
-- och då är auth.uid() null → if-satsen nedan hoppas över. Admin påverkas inte heller.
--
-- Basen nedan är prod-definitionen, utläst 2026-08-18 med
--   select pg_get_functiondef('public.protect_profile_cols'::regproc);
-- Enda skillnaden mot prod är den markerade raden.

create or replace function public.protect_profile_cols()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.approved := old.approved;
    new.is_admin := old.is_admin;
    new.website  := old.website;
    new.email    := old.email;
    new.meeting_at := old.meeting_at;
    new.launched_at := old.launched_at;
    new.launch_url := old.launch_url;
    new.github_repo := old.github_repo;   -- NYTT i migration 24
  end if;
  return new;
end;
$function$;

-- VERIFIERING efter körning — ska returnera true:
--   select pg_get_functiondef('public.protect_profile_cols'::regproc)
--          like '%new.github_repo := old.github_repo%';
