-- =====================================================================
--  11 — Whop : seul le produit de la page compte
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Le webhook reçoit TOUS les paiements du compte Whop de Marcuus (acomptes
--  et plans de ses autres offres). Seul le produit « Base 44 » à 9,99 €
--  (prod_UQFQCnFzTFob6, plan_DrtsM796QriYh) concerne la page et le CRM :
--  1. whop_paiement_recu ignore les autres produits (rien n'est stocké, aucun
--     lead n'est déplacé) ;
--  2. les paiements des autres produits déjà enregistrés sont effacés (ils
--     n'ont rien à faire ici : e-mails et montants de clients d'autres offres).
-- =====================================================================

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

  -- Le compte Whop de Marcuus encaisse aussi ses autres offres : seul le
  -- produit de la page (« Base 44 », 9,99 €) concerne le CRM. Les autres
  -- paiements ne sont ni enregistrés ni rattachés.
  if coalesce(p->>'product_id', p->'product'->>'id', '') <> 'prod_UQFQCnFzTFob6' then
    return 'autre produit';
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

delete from public.whop_paiements
 where coalesce(brut->>'product_id', brut->'product'->>'id', '') <> 'prod_UQFQCnFzTFob6';

-- Vérification : seulement des paiements à 9,99 €.
select count(*) as paiements, min(montant) as min, max(montant) as max, sum(montant) as total
  from public.whop_paiements;
