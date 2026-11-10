-- =====================================================================
--  10 — Les accès « direction » (Marcuus, Kevin, Syrin)
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Un compte direction est administrateur des deux équipes (Base44 et
--  Marcuus Lawrence) pour LIRE leurs chiffres, mais ne voit que les
--  onglets listés dans staff.vues : Dashboard, Sources, Rapport, Factures.
--
--  - staff.vues : null = tous les onglets de son rôle (comme avant) ;
--    une liste = ces onglets seulement.
--  - Un compte avec une liste d'onglets n'est jamais administrateur
--    général (is_admin) : ni Opt-in, ni Automatique, ni Partenaires, ni
--    validation des ventes, ni gestion des comptes.
--  - Il ne devient pas administrateur de l'espace membre.
--  - Il lit l'onglet Sources (équipe Base44) et les factures des ventes
--    validées depuis l'espace membre.
-- =====================================================================

-- 1. La liste des onglets visibles.
alter table public.staff add column if not exists vues text[];
comment on column public.staff.vues is
  'Onglets du CRM visibles (null = tous ceux du rôle). Un compte limité n''est jamais administrateur général.';

-- 2. L'administrateur général : jamais un compte aux onglets limités.
create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.staff
    where user_id = auth.uid() and actif and role = 'admin' and vues is null
      and coalesce(equipes, array[equipe]) @> array['starter', 'marcuus']
  );
$$;

-- 3. L'onglet Sources : l'administrateur général, ou un admin de l'équipe
--    Base44 qui a l'onglet Sources dans sa liste.
create or replace function public.peut_voir_sources()
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.is_admin() or exists (
    select 1 from public.staff
    where user_id = auth.uid() and actif and role = 'admin'
      and 'starter' = any(coalesce(equipes, array[equipe]))
      and 'sources' = any(vues)
  );
$$;
revoke all on function public.peut_voir_sources() from public, anon;
grant execute on function public.peut_voir_sources() to authenticated;

do $$
declare
  corps text;
begin
  select pg_get_functiondef('public.stats_sources(date, date)'::regprocedure) into corps;
  if position('peut_voir_sources' in corps) = 0 then
    corps := replace(corps, 'if not public.is_admin() then', 'if not public.peut_voir_sources() then');
    execute corps;
  end if;
end $$;

-- 4. Pas d'administration de l'espace membre pour un compte aux onglets
--    limités : la synchronisation staff → members l'ignore.
create or replace function public.staff_vers_membre()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.vues is not null then
    return new;
  end if;
  if new.actif then
    insert into public.members (id, email, first_name, last_name, role)
    select new.user_id, u.email, new.first_name, new.last_name,
           case when new.role = 'admin' then 'admin' else 'setter' end
    from auth.users u
    where u.id = new.user_id
    on conflict (id) do update
      set role = case
                   when excluded.role = 'admin' then 'admin'
                   when members.role = 'member' then 'setter'
                   else excluded.role
                 end;
  else
    -- Quelqu'un qui quitte l'équipe ne garde pas le back-office. On lui
    -- laisse sa fiche : la retirer effacerait sa progression s'il était
    -- aussi élève.
    update public.members set role = 'member' where id = new.user_id;
  end if;
  return new;
end;
$$;

-- 5. Les factures des ventes validées (seau factures-clients, rangées par
--    closer) : lisibles aussi par les admins de l'équipe du closer.
drop policy if exists "facture client lue" on storage.objects;
create policy "facture client lue" on storage.objects
  for select to authenticated using (
    bucket_id = 'factures-clients'
    and ((storage.foldername(name))[1] = auth.uid()::text
         or public.is_admin(auth.uid())
         or public.admin_du_dossier((storage.foldername(name))[1]))
  );

-- 6. En lecture seule : un compte aux onglets limités ne saisit ni ne
--    supprime de lead, de facture ou d'enregistrement d'appel.
create or replace function public.compte_limite()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.staff where user_id = auth.uid() and vues is not null);
$$;
revoke all on function public.compte_limite() from public, anon;
grant execute on function public.compte_limite() to authenticated;

-- admin_de sert à saisir et supprimer des leads : pas pour eux.
create or replace function public.admin_de(p_equipe text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.staff
    where user_id = auth.uid() and actif and role = 'admin' and vues is null
      and p_equipe = any(coalesce(equipes, array[equipe]))
  );
$$;

drop policy if exists "facture retiree" on public.invoices;
create policy "facture retiree" on public.invoices
  for delete to authenticated
  using ((setter_id = auth.uid() or public.admin_du_setter(setter_id)) and not public.compte_limite());

drop policy if exists "facture retiree" on storage.objects;
create policy "facture retiree" on storage.objects
  for delete using (
    bucket_id = 'factures'
    and ((storage.foldername(name))[1] = auth.uid()::text
         or public.admin_du_dossier((storage.foldername(name))[1]))
    and not public.compte_limite()
  );

drop policy if exists "appel supprime" on public.lead_calls;
create policy "appel supprime" on public.lead_calls
  for delete to authenticated
  using ((setter_id = auth.uid() or public.admin_du_setter(setter_id)) and not public.compte_limite());

drop policy if exists "appel efface" on storage.objects;
create policy "appel efface" on storage.objects
  for delete using (
    bucket_id = 'appels'
    and ((storage.foldername(name))[1] = auth.uid()::text
         or public.admin_du_dossier((storage.foldername(name))[1]))
    and not public.compte_limite()
  );

-- La modification des leads de leur équipe (« staff modifie les leads »)
-- leur est fermée aussi.
drop policy if exists "staff modifie les leads" on public.leads;
create policy "staff modifie les leads"
  on public.leads for update to authenticated
  using  (public.is_admin()
          or (public.is_staff() and not public.compte_limite()
              and equipe = any(public.mes_equipes()) and vivier <> 'optin'))
  with check (public.is_admin()
              or (public.is_staff() and not public.compte_limite()
                  and equipe = any(public.mes_equipes()) and vivier <> 'optin'));

drop policy if exists "staff saisit un lead" on public.leads;
create policy "staff saisit un lead"
  on public.leads for insert to authenticated
  with check (
    public.is_admin()
    or (public.is_staff() and not public.compte_limite()
        and equipe = any(public.mes_equipes()) and setter_id = auth.uid())
  );

notify pgrst, 'reload schema';
