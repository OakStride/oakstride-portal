-- Migration 25: statusvärdet `failed` — något gick fel, OakStride tar över
--
-- BAKGRUND
-- Fredriks beslut 2026-08-21 09:00: "Markera ärendet misslyckat — kunden får besked att vi
-- fixar det manuellt." Och 21:36: "Lägg ett ärende i inkorgen så det syns i panelen."
--
-- Problemet i dag är att `draft_ready` används som BÅDE "utkast klart" och "publicering
-- misslyckades". Det gör två fel oundvikliga, båda verifierade direkt mot prod 2026-08-21:
--
--   1. Statusgrenen i notify_email() tittar bara på new.status, aldrig old.status. En
--      misslyckad publicering går publishing -> draft_ready och kunden får därför
--      "Ditt förslag är klart att granska" — motsatt budskap.
--   2. Kommentarsgrenen tystar draft_ready helt (med flit, för att slippa dubbelmejl när ett
--      utkast blir klart). Agentens felnotis postas efter statusbytet och mejlas därför aldrig.
--
-- OBS: requests.status är en CHECK-CONSTRAINT, inte en enum. Nya värden läggs alltså genom att
-- bygga om constrainten — inte med `alter type ... add value`, som gäller build_jobs.status.

-- ---------------------------------------------------------------------------
-- 1. Tillåt det nya värdet
-- ---------------------------------------------------------------------------
alter table public.requests drop constraint if exists requests_status_check;
alter table public.requests add constraint requests_status_check
  check (status = any (array[
    'new', 'in_progress', 'questions', 'draft_ready', 'approved',
    'waiting_customer', 'done', 'publishing', 'published',
    'failed'                                    -- NYTT i migration 25
  ]));

-- ---------------------------------------------------------------------------
-- 2. Beskedet läggs i KOMMENTARSGRENEN, inte i statusgrenen
-- ---------------------------------------------------------------------------
-- Detta är ett medvetet val och det viktigaste i hela migrationen.
--
-- Den uppenbara lösningen — att lägga mejlet på statusbytet — går sönder på andra försöket:
-- `notify_status_change` fyrar bara `when (old.status is distinct from new.status)`. Ett ärende
-- som redan står på `failed` och misslyckas igen byter inte status, triggern fyrar inte, och
-- kunden får INGENTING. Det är samma tystnad som migrationen ska bygga bort, i ny skepnad.
--
-- Kommentarsgrenen har inte det problemet: agenten postar alltid en kommentar när något går fel,
-- oavsett om statusen råkade ändras. Därför bär den beskedet, och statusgrenen lämnas orörd
-- (`failed` faller där i `else return new` och mejlar inget — vilket är precis rätt).
--
-- notify_email() är EN funktion som bär tre ansvar och hänger på fyra triggers. Den är 7 000+
-- tecken och innehåller grenar (orderbekräftelser m.m.) som inte får gå förlorade. Därför
-- skrivs den INTE om för hand här — i stället läses den nuvarande definitionen ut ur databasen
-- och en gren fogas in på ett känt ankare.
--
-- Migrationen är idempotent, och den HAVERERAR hellre än att tyst göra ingenting: hittas inte
-- ankaret kastas ett fel i stället för att lämna funktionen oförändrad medan alla tror att den
-- ändrats. Det är den fällan som gör en migration farlig.

do $mig$
declare
  def text;
  ny  text;
begin
  def := pg_get_functiondef('public.notify_email'::regproc);

  if position('who.status = ''failed''' in def) > 0 then
    raise notice 'notify_email() har redan failed-grenen — hoppar över.';
    return;
  end if;

  ny := replace(
    def,
    '      elsif who.status = ''draft_ready'' then',
    '      elsif who.status = ''failed'' then' || E'\n' ||
    '        subj := ''Vi tittar på ditt ärende #'' || new.request_id;' || E'\n' ||
    '        html := ''<h2>Något gick inte som det skulle</h2>''' || E'\n' ||
    '          || ''<p style="white-space:pre-wrap">'' || public.esc_html(new.body) || ''</p>''' || E'\n' ||
    '          || ''<p>Du behöver inte göra något — OakStride har fått besked och tittar på det.</p>''' || E'\n' ||
    '          || ''<p><a href="https://portal.oakstride.se">Följ ärendet i portalen</a></p>'';' || E'\n' ||
    '      elsif who.status = ''draft_ready'' then'
  );

  if ny = def then
    raise exception
      'Migration 25: ankaret "elsif who.status = ''''draft_ready'''' then" hittades inte i '
      'notify_email(). Inget har ändrats. Läs ut funktionen med pg_get_functiondef och lägg in '
      'grenen för hand.';
  end if;

  execute ny;
  raise notice 'notify_email(): failed-grenen inlagd i kommentarsgrenen.';
end
$mig$;

-- ---------------------------------------------------------------------------
-- ⚠️ VARNING TILL DEN SOM ÅTERSTÄLLER
-- ---------------------------------------------------------------------------
-- migration-23-notify-published-email.sql innehåller en KOMPLETT `create or replace` av
-- notify_email() — utan failed-grenen. Körs den om efter denna migration försvinner grenen
-- tyst, och kunden får fel besked igen. Kör i så fall migration 25 direkt efteråt; den är
-- idempotent och lägger tillbaka grenen. En varningsrad finns även överst i migration 23.

-- ---------------------------------------------------------------------------
-- VERIFIERING efter körning — båda ska returnera true
-- ---------------------------------------------------------------------------
--   select 'failed' = any (enum_range := array(
--     select unnest(string_to_array(
--       regexp_replace(pg_get_constraintdef(oid), '[^a-z_,]', '', 'g'), ',')))
--   ) from pg_constraint where conname = 'requests_status_check';
--
--   select pg_get_functiondef('public.notify_email'::regproc) like '%who.status = ''failed''%';
