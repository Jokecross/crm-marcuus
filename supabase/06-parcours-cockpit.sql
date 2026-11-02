-- =====================================================================
--  06 — Le parcours « Mon Cockpit Black Friday »
--
--  • workshop_jours.blocs : la page de chaque jour (ce qu'on construit, les
--    étapes, les encadrés, « Tu as réussi si… »). Les prompts restent dans
--    `prompt` et `prompt_2`, et ne sortent toujours que pour un jour ouvert.
--  • workshop_reglages.parcours : le bandeau « Comment ça marche », les
--    textes du jour 0 et la page « Si ça ne marche pas ».
--  • Le didacticiel : plus de passage après le jour 0 sans capture d'écran
--    (la base le refuse, pas seulement l'écran).
--  Le contenu lui-même est déposé ensuite par un script. Rejouable.
-- =====================================================================

alter table public.workshop_jours    add column if not exists blocs    jsonb not null default '[]'::jsonb;
alter table public.workshop_reglages add column if not exists parcours jsonb not null default '{}'::jsonb;

-- mon_workshop renvoie aussi les blocs, aux mêmes conditions que le prompt.
drop function if exists public.mon_workshop();

create function public.mon_workshop()
returns table (
  jour            int,
  titre           text,
  resume          text,
  video_url       text,
  prompt          text,
  prompt_2        text,
  prompt_2_titre  text,
  consignes       text,
  ouvert          boolean,
  ouvre_le        timestamptz,
  capture_faite   boolean,
  etapes          jsonb,
  blocs           jsonb
)
language sql stable security definer set search_path = public
as $$
  with e as (
    select public.workshop_jour(auth.uid())    as jour_max,
           public.fuseau_membre(auth.uid())    as tz,
           public.workshop_depart(auth.uid())  as debut,
           (select workshop_dispense from members where id = auth.uid()) as dispense
  )
  select j.jour,
         j.titre,
         j.resume,
         case when j.jour <= e.jour_max then j.video_url      end,
         case when j.jour <= e.jour_max then j.prompt         end,
         case when j.jour <= e.jour_max then j.prompt_2       end,
         case when j.jour <= e.jour_max then j.prompt_2_titre end,
         case when j.jour <= e.jour_max then j.consignes      end,
         j.jour <= e.jour_max,
         case
           when j.jour <= e.jour_max or e.dispense or e.debut is null then null
           else ((((e.debut at time zone e.tz)::date + j.jour)::timestamp) at time zone e.tz)
         end,
         exists (select 1 from workshop_captures c
                  where c.member_id = auth.uid() and c.jour = j.jour),
         case when j.jour <= e.jour_max then j.etapes end,
         case when j.jour <= e.jour_max then j.blocs end
  from workshop_jours j, e
  order by j.jour;
$$;

revoke all on function public.mon_workshop() from public, anon;
grant execute on function public.mon_workshop() to authenticated;

-- Le didacticiel : l'étape « Ton jour 0 » ne se passe qu'avec une capture.
create or replace function public.guide_avancer(p_etape int, p_prompt_recu boolean default null)
returns void
language plpgsql volatile security definer set search_path = public
as $$
begin
  if p_etape >= 2
     and not public.is_equipe(auth.uid())
     and not exists (select 1 from public.preuves where member_id = auth.uid()) then
    raise exception 'Dépose d''abord ta capture d''écran.';
  end if;

  update public.members
     set guide_etape = greatest(guide_etape, least(greatest(p_etape, 0), 3)),
         prompt_recu = coalesce(p_prompt_recu, prompt_recu)
   where id = auth.uid();
end;
$$;

revoke all on function public.guide_avancer(int, boolean) from public, anon;
grant execute on function public.guide_avancer(int, boolean) to authenticated;

-- Vérification
select (select count(*) from information_schema.columns
         where table_name = 'workshop_jours' and column_name = 'blocs')    as colonne_blocs,
       (select count(*) from information_schema.columns
         where table_name = 'workshop_reglages' and column_name = 'parcours') as colonne_parcours;
