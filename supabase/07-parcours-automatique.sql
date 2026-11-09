-- =====================================================================
--  07 — Le parcours automatique des numéros africains (comme chez Mexed)
--
--  Un numéro africain qui remplit le formulaire de la page de vente ne
--  part pas dans les Leads du jour : il est enregistré dans le vivier
--  « auto » (équipe Base44) et suit la page « Active ton accès ». Sa
--  facture Base44 arrive dans le CRM, onglet Automatique, où Martin la
--  vérifie et crée l'accès à l'espace membre.
--
--  La table, la fonction de dépôt et le seau « factures-auto » existent
--  déjà (INSTALLATION). Ce fichier rouvre le formulaire public au vivier
--  « auto », et réserve la lecture des factures à l'administrateur
--  général. Rejouable.
-- =====================================================================

drop policy if exists "public peut deposer un lead" on public.leads;
create policy "public peut deposer un lead"
  on public.leads for insert to anon
  with check (
    status = 'nouveau'
    and setter_id is null
    and called_at is null
    and notes is null
    and dials = 0
    and cash_collecte = 0
    and equipe = 'starter'
    and facture_path is null
    and acces_valide_at is null
    and invite_token is null
    and (
      (vivier = 'formulaire' and auto_jeton is null)
      or (vivier = 'auto' and auto_jeton is not null)
    )
  );

-- Les factures du parcours : l'administrateur général seul les ouvre.
drop policy if exists "equipe lit les factures auto" on storage.objects;
create policy "equipe lit les factures auto" on storage.objects
  for select to authenticated using (
    bucket_id = 'factures-auto' and public.is_admin()
  );

-- Vérification
select (select count(*) from pg_policies where policyname = 'public peut deposer un lead') as regle_formulaire,
       (select public from storage.buckets where id = 'factures-auto')                     as seau_public,
       (select count(*) from public.leads where vivier = 'auto')                           as leads_automatiques;
