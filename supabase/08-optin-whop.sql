-- =====================================================================
--  08 — Paiement Whop à 9,99 € et vivier « Opt-in » (repris de Sirius)
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  La page de vente crée le lead dans le vivier « optin », puis affiche le
--  paiement Whop de 9,99 € dans la même fenêtre. Le webhook de Whop
--  (fonction whop-webhook) appelle whop_paiement_recu() : le lead passe
--  alors dans « formulaire », donc dans les Leads du jour, comme s'il
--  venait d'arriver. Sans paiement, il reste dans Opt-in, que seul
--  l'administrateur général voit.
--
--  Les numéros africains ne paient pas : ils suivent le parcours
--  automatique (vivier « auto », page « Active ton accès »).
--
--  Ce fichier contient aussi tout le 07 : inutile de passer le 07 avant.
-- =====================================================================

-- 1. Le nouveau vivier.
alter table public.leads drop constraint if exists leads_vivier_check;
alter table public.leads add constraint leads_vivier_check
  check (vivier in ('formulaire', 'iclosed', 'auto', 'optin'));

-- 2. Le formulaire public : Leads du jour, opt-in, ou parcours automatique.
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
      (vivier in ('formulaire', 'optin') and auto_jeton is null)
      or (vivier = 'auto' and auto_jeton is not null)
    )
  );

-- 3. (repris du 07) Les factures du parcours automatique : l'administrateur
--    général seul les ouvre.
drop policy if exists "equipe lit les factures auto" on storage.objects;
create policy "equipe lit les factures auto" on storage.objects
  for select to authenticated using (
    bucket_id = 'factures-auto' and public.is_admin()
  );

-- 4. Ce que le paiement laisse sur le lead.
alter table public.leads
  add column if not exists paye_at         timestamptz,
  add column if not exists whop_payment_id text;

-- 5. Le registre des paiements reçus de Whop, rattachés ou non. Un même
--    webhook peut arriver deux fois : l'identifiant du paiement fait foi.
create table if not exists public.whop_paiements (
  id        text primary key,
  lead_id   uuid references public.leads(id) on delete set null,
  email     text,
  nom       text,
  montant   numeric(10,2),
  devise    text,
  statut    text,
  recu_at   timestamptz not null default now(),
  brut      jsonb not null default '{}'::jsonb
);

alter table public.whop_paiements enable row level security;
drop policy if exists "admin lit les paiements whop" on public.whop_paiements;
create policy "admin lit les paiements whop" on public.whop_paiements
  for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.whop_paiements from anon, authenticated;

-- 6. Le paiement reçu. Appelée par la fonction whop-webhook avec la clé
--    service_role, jamais depuis une page.
--    Rattachement : l'identifiant du lead passé en metadata, sinon l'e-mail,
--    sur le lead opt-in le plus récent.
create or replace function public.whop_paiement_recu(p jsonb)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id     text := p->>'id';
  v_email  text := lower(trim(coalesce(nullif(p->>'customer_email', ''), p->'user'->>'email', '')));
  v_nom    text := coalesce(p->'billing_address'->>'name', p->'user'->>'name');
  v_meta   text := p->'metadata'->>'lead_id';
  v_total  numeric;
  v_devise text;
  v_lead   public.leads%rowtype;
begin
  if v_id is null then
    return 'sans identifiant';
  end if;

  -- `total` est un nombre ou un objet { amount, currency } selon la version.
  begin
    v_total := coalesce((p->'total'->>'amount')::numeric, (p->>'total')::numeric);
  exception when others then v_total := null;
  end;
  v_devise := coalesce(p->'total'->>'currency', p->>'currency');

  insert into public.whop_paiements (id, email, nom, montant, devise, statut, brut)
  values (v_id, nullif(v_email, ''), v_nom, v_total, v_devise, p->>'status', p)
  on conflict (id) do nothing;
  if not found then
    return 'deja recu';
  end if;

  if v_meta ~* '^[0-9a-f-]{36}$' then
    select * into v_lead from public.leads where id = v_meta::uuid;
  end if;
  if v_lead.id is null and v_email <> '' then
    select * into v_lead from public.leads
     where lower(trim(email)) = v_email and vivier = 'optin'
     order by created_at desc limit 1;
  end if;
  if v_lead.id is null then
    return 'introuvable';
  end if;

  update public.whop_paiements set lead_id = v_lead.id where id = v_id;

  -- Le lead entre dans les Leads du jour comme s'il venait d'arriver : le
  -- décompte des 10 minutes part du paiement. L'heure du formulaire est
  -- gardée dans formulaire_at.
  update public.leads
     set vivier          = 'formulaire',
         formulaire_at   = coalesce(formulaire_at, created_at),
         created_at      = case when vivier = 'optin' then now() else created_at end,
         paye_at         = coalesce(paye_at, now()),
         whop_payment_id = coalesce(whop_payment_id, v_id)
   where id = v_lead.id;

  return 'rattache';
end;
$$;

revoke all on function public.whop_paiement_recu(jsonb) from public, anon, authenticated;
grant execute on function public.whop_paiement_recu(jsonb) to service_role;

-- 7. L'opt-in ne regarde que l'administrateur général : un setter (ou un
--    admin d'équipe) ne lit ni ne modifie un lead tant qu'il n'a pas payé.
drop policy if exists "staff lit les leads" on public.leads;
create policy "staff lit les leads"
  on public.leads for select to authenticated
  using (public.is_admin()
         or (public.is_staff() and equipe = any(public.mes_equipes()) and vivier <> 'optin'));

drop policy if exists "staff modifie les leads" on public.leads;
create policy "staff modifie les leads"
  on public.leads for update to authenticated
  using  (public.is_admin()
          or (public.is_staff() and equipe = any(public.mes_equipes()) and vivier <> 'optin'))
  with check (public.is_admin()
              or (public.is_staff() and equipe = any(public.mes_equipes()) and vivier <> 'optin'));

-- Vérification : une seule ligne, tout à true.
select
  pg_get_constraintdef((select oid from pg_constraint where conname = 'leads_vivier_check')) like '%optin%' as vivier_optin,
  exists (select 1 from information_schema.columns where table_name = 'leads' and column_name = 'paye_at')  as colonne_paye,
  exists (select 1 from pg_proc where proname = 'whop_paiement_recu')                                       as fonction_paiement,
  (select count(*) from pg_policies where tablename = 'leads'
     and policyname in ('staff lit les leads', 'staff modifie les leads') and qual like '%optin%') = 2      as optin_cache_aux_setters;
