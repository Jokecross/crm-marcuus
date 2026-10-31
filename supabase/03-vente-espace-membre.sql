-- =====================================================================
--  03 — Les closers de l'équipe Marcuus Lawrence dans l'espace membre
--
--  Un closer (staff.role = 'setter', staff.equipe = 'marcuus') n'a dans
--  l'espace membre qu'un back-office réduit : créer un lien d'invitation et
--  voir les siens. Avant de générer un lien, il renseigne le client
--  (prénom, nom, e-mail, téléphone) et dépose la facture envoyée pendant
--  l'appel. La base refuse l'invitation sinon : l'écran ne fait que suivre.
--
--  Les administrateurs et les setters Base44 ne changent pas.
--  Rejouable. Supabase → SQL Editor → Run.
-- =====================================================================

-- 1. Le client et sa facture, sur l'invitation
alter table public.invites add column if not exists client_prenom    text;
alter table public.invites add column if not exists client_nom       text;
alter table public.invites add column if not exists client_email     text;
alter table public.invites add column if not exists client_telephone text;
alter table public.invites add column if not exists facture_path     text;

-- 2. « La personne connectée est-elle un closer Marcuus ? »
create or replace function public.est_vendeur()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.staff
    where user_id = auth.uid() and actif and role = 'setter' and equipe = 'marcuus'
  );
$$;
revoke all on function public.est_vendeur() from public, anon;
grant execute on function public.est_vendeur() to authenticated;

-- 3. Les factures des clients : privées, rangées par closer
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('factures-clients', 'factures-clients', false, 15728640,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic'])
on conflict (id) do update
  set public = false, file_size_limit = 15728640,
      allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic'];

drop policy if exists "facture client deposee" on storage.objects;
create policy "facture client deposee" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'factures-clients'
    and public.is_equipe(auth.uid())
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "facture client lue" on storage.objects;
create policy "facture client lue" on storage.objects
  for select to authenticated using (
    bucket_id = 'factures-clients'
    and ((storage.foldername(name))[1] = auth.uid()::text
         or public.is_admin(auth.uid()))
  );

-- 4. Les invitations
drop policy if exists "equipe gère les invitations" on public.invites;
drop policy if exists "invitations lues" on public.invites;
drop policy if exists "invitation creee" on public.invites;
drop policy if exists "invitation modifiee" on public.invites;
drop policy if exists "invitation supprimee" on public.invites;

-- Lecture : un closer Marcuus ne voit que les siennes.
create policy "invitations lues" on public.invites
  for select to authenticated using (
    public.is_equipe(auth.uid())
    and (not public.est_vendeur() or created_by = auth.uid())
  );

-- Création : pour un closer Marcuus, client complet + facture déposée.
create policy "invitation creee" on public.invites
  for insert to authenticated with check (
    public.is_equipe(auth.uid())
    and (
      not public.est_vendeur()
      or (
        created_by = auth.uid()
        and length(trim(coalesce(client_prenom, ''))) > 0
        and length(trim(coalesce(client_nom, ''))) > 0
        and coalesce(client_email, '') ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
        and length(regexp_replace(coalesce(client_telephone, ''), '\D', '', 'g')) >= 8
        and facture_path like auth.uid()::text || '/%'
        and exists (
          select 1 from storage.objects o
          where o.bucket_id = 'factures-clients' and o.name = invites.facture_path
        )
      )
    )
  );

-- Modification et suppression : pas pour les closers Marcuus.
create policy "invitation modifiee" on public.invites
  for update to authenticated
  using (public.is_equipe(auth.uid()) and not public.est_vendeur())
  with check (public.is_equipe(auth.uid()) and not public.est_vendeur());

create policy "invitation supprimee" on public.invites
  for delete to authenticated
  using (public.is_equipe(auth.uid()) and not public.est_vendeur());

-- Vérification : les 83 closers Marcuus sont bien reconnus.
select count(*) as closers_marcuus
from public.staff where actif and role = 'setter' and equipe = 'marcuus';
