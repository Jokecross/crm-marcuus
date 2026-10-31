-- =====================================================================
--  02 — Un administrateur par équipe
--
--  Avant : tout compte « admin » voyait les deux équipes.
--  Après :
--    • administrateur général = admin dont `equipes` contient starter ET
--      marcuus (Martin). Il voit tout, gère les comptes et les réglages.
--    • administrateur d'équipe = admin d'une seule équipe (Marcuus, Tom,
--      Emile, Julien → marcuus). Il voit les leads, les setters, les
--      factures, les appels, les dispos et la présence de SON équipe
--      seulement. Il ne crée ni ne modifie de compte.
--  Rejouable. À passer une fois dans Supabase → SQL Editor → Run.
-- =====================================================================

-- 1. « is_admin » = administrateur général
create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.staff
    where user_id = auth.uid() and actif and role = 'admin'
      and coalesce(equipes, array[equipe]) @> array['starter', 'marcuus']
  );
$$;

-- 2. Administrateur de telle équipe
create or replace function public.admin_de(p_equipe text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.staff
    where user_id = auth.uid() and actif and role = 'admin'
      and p_equipe = any(coalesce(equipes, array[equipe]))
  );
$$;

-- 3. Administrateur de l'équipe de tel setter (texte : sert aussi aux
--    dossiers du stockage, nommés d'après l'identifiant du setter)
create or replace function public.admin_du_dossier(p_user text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
    from public.staff moi
    join public.staff s on s.user_id::text = p_user
    where moi.user_id = auth.uid() and moi.actif and moi.role = 'admin'
      and coalesce(s.equipes, array[s.equipe]) && coalesce(moi.equipes, array[moi.equipe])
  );
$$;

create or replace function public.admin_du_setter(p_user uuid)
returns boolean
language sql stable security definer set search_path = public
as $$ select public.admin_du_dossier(p_user::text); $$;

revoke all on function public.admin_de(text), public.admin_du_dossier(text), public.admin_du_setter(uuid) from public, anon;
grant execute on function public.admin_de(text), public.admin_du_dossier(text), public.admin_du_setter(uuid) to authenticated;

-- 4. Leads : lecture et modification inchangées (l'admin d'équipe passe par
--    « is_staff() and equipe = any(mes_equipes()) »). Saisie et suppression :
drop policy if exists "admin ajoute des leads" on public.leads;
create policy "admin ajoute des leads"
  on public.leads for insert to authenticated
  with check (public.admin_de(equipe));

drop policy if exists "admin supprime" on public.leads;
create policy "admin supprime"
  on public.leads for delete to authenticated
  using (public.admin_de(equipe));

-- 5. Fil d'activité : on ne lit que celui des leads qu'on voit
--    (la RLS de leads s'applique dans la sous-requête).
drop policy if exists "staff lit l'activite" on public.lead_events;
create policy "staff lit l'activite"
  on public.lead_events for select to authenticated
  using (exists (select 1 from public.leads l where l.id = lead_events.lead_id));

-- 6. Factures
drop policy if exists "facture lue" on public.invoices;
create policy "facture lue" on public.invoices
  for select to authenticated
  using (setter_id = auth.uid() or public.admin_du_setter(setter_id));

drop policy if exists "facture retiree" on public.invoices;
create policy "facture retiree" on public.invoices
  for delete to authenticated
  using (setter_id = auth.uid() or public.admin_du_setter(setter_id));

drop policy if exists "facture lue" on storage.objects;
create policy "facture lue" on storage.objects
  for select using (
    bucket_id = 'factures'
    and ((storage.foldername(name))[1] = auth.uid()::text
         or public.admin_du_dossier((storage.foldername(name))[1]))
  );

drop policy if exists "facture retiree" on storage.objects;
create policy "facture retiree" on storage.objects
  for delete using (
    bucket_id = 'factures'
    and ((storage.foldername(name))[1] = auth.uid()::text
         or public.admin_du_dossier((storage.foldername(name))[1]))
  );

-- 7. Enregistrements d'appels
drop policy if exists "appel lu" on public.lead_calls;
create policy "appel lu" on public.lead_calls
  for select to authenticated
  using (setter_id = auth.uid() or public.admin_du_setter(setter_id));

drop policy if exists "appel supprime" on public.lead_calls;
create policy "appel supprime" on public.lead_calls
  for delete to authenticated
  using (setter_id = auth.uid() or public.admin_du_setter(setter_id));

drop policy if exists "appel ecoute" on storage.objects;
create policy "appel ecoute" on storage.objects
  for select using (
    bucket_id = 'appels'
    and ((storage.foldername(name))[1] = auth.uid()::text
         or public.admin_du_dossier((storage.foldername(name))[1]))
  );

drop policy if exists "appel efface" on storage.objects;
create policy "appel efface" on storage.objects
  for delete using (
    bucket_id = 'appels'
    and ((storage.foldername(name))[1] = auth.uid()::text
         or public.admin_du_dossier((storage.foldername(name))[1]))
  );

-- 8. Dispos et présence
drop policy if exists "dispos lues par leur setter ou un admin" on public.dispos;
create policy "dispos lues par leur setter ou un admin"
  on public.dispos for select to authenticated
  using (setter_id = auth.uid() or public.admin_du_setter(setter_id));

drop policy if exists "absences lues par leur setter ou un admin" on public.dispos_absences;
create policy "absences lues par leur setter ou un admin"
  on public.dispos_absences for select to authenticated
  using (setter_id = auth.uid() or public.admin_du_setter(setter_id));

drop policy if exists "admin lit la presence" on public.presence;
create policy "admin lit la presence"
  on public.presence for select to authenticated
  using (public.admin_du_setter(user_id));

drop policy if exists "admin lit les inactivites" on public.inactivites;
create policy "admin lit les inactivites"
  on public.inactivites for select to authenticated
  using (public.admin_du_setter(user_id));

-- 9. Statistiques : l'admin d'équipe peut regarder un setter de son équipe
--    (les lignes restent bornées par la RLS : security invoker).
create or replace function public.crm_stats(
  p_debut  timestamptz default null,
  p_fin    timestamptz default null,
  p_setter uuid        default null,
  p_vivier text        default null,
  p_equipe text        default null
)
returns json
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  resultat json;
begin
  if not (public.is_admin() or public.admin_du_setter(p_setter))
     and p_setter is not null
     and p_setter <> auth.uid() then
    raise exception 'Chiffres réservés : tu peux consulter les tiens ou ceux de toute l''équipe.';
  end if;

  with
  recus as (
    select *
    from public.leads
    where (p_debut  is null or created_at >= p_debut)
      and (p_fin    is null or created_at <  p_fin)
      and (p_setter is null or setter_id = p_setter)
      and (p_vivier is null or vivier = p_vivier)
      and (p_equipe is null or equipe = p_equipe)
  ),
  ventes as (
    select *
    from public.leads
    where status in ('monthly', 'yearly')
      and closed_at is not null
      and (p_debut  is null or closed_at >= p_debut)
      and (p_fin    is null or closed_at <  p_fin)
      and (p_setter is null or setter_id = p_setter)
      and (p_vivier is null or vivier = p_vivier)
      and (p_equipe is null or equipe = p_equipe)
  ),
  retard as (
    select count(*) as n
    from public.leads
    where status = 'follow_up'
      and follow_up_at is not null
      and follow_up_at < now()
      and (p_setter is null or setter_id = p_setter)
      and (p_vivier is null or vivier = p_vivier)
      and (p_equipe is null or equipe = p_equipe)
  ),
  activite as (
    select
      count(*)                                                     as leads,
      coalesce(sum(dials), 0)                                      as dials,
      count(*) filter (where dials > 0)                            as tentes,
      count(*) filter (where status in
        ('follow_up','monthly','yearly','ghosted','time_waster'))  as joints,
      count(*) filter (where status = 'pas_de_reponse')            as sans_reponse,
      count(*) filter (where status = 'time_waster')               as time_wasters
    from recus
  ),
  argent as (
    select
      count(*) filter (where status = 'monthly')   as monthly,
      count(*) filter (where status = 'yearly')    as yearly,
      count(*)                                     as closed,
      coalesce(sum(cash_collecte), 0)              as cash,
      coalesce(sum(commission), 0)                 as commissions
    from ventes
  )
  select json_build_object(
    'leads',            a.leads,
    'dials',            a.dials,
    'tentes',           a.tentes,
    'joints',           a.joints,
    'sans_reponse',     a.sans_reponse,
    'time_wasters',     a.time_wasters,
    'monthly',          v.monthly,
    'yearly',           v.yearly,
    'closed',           v.closed,
    'cash',             v.cash,
    'commissions',      v.commissions,
    'retards',          r.n,
    'connection_rate',  case when a.tentes > 0
                          then round(a.joints::numeric / a.tentes * 100) else 0 end,
    'closing_rate',     case when a.joints > 0
                          then round(v.closed::numeric / a.joints * 100) else 0 end,
    'tw_rate',          case when a.joints > 0
                          then round(a.time_wasters::numeric / a.joints * 100) else 0 end,
    'yearly_rate',      case when v.closed > 0
                          then round(v.yearly::numeric / v.closed * 100) else 0 end
  )
  into resultat
  from activite a, argent v, retard r;

  return resultat;
end;
$$;

revoke all on function public.crm_stats(timestamptz, timestamptz, uuid, text, text) from public, anon;
grant execute on function public.crm_stats(timestamptz, timestamptz, uuid, text, text) to authenticated;
