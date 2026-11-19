-- =====================================================================
--  13 — L'onglet Opt-in ouvert aux setters, compté à part (19/11/2026)
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--  Jusqu'ici, seul l'administrateur général lisait les opt-in (formulaire
--  rempli, 9,99 € non payés). Les setters de l'équipe les lisent et les
--  prennent désormais depuis l'onglet Opt-in.
--
--  Un opt-in garde le vivier « optin », même pris. Leurs chiffres de base
--  (Leads du jour, Pipeline, Archive, Rapport, Dashboard « Leads des
--  setters ») ne lisent que le vivier « formulaire » : un opt-in n'y entre
--  jamais. Le Dashboard a sa propre source « Opt-in (compté à part) ».
--
--  Un opt-in déjà pris par un setter qui paie ensuite les 9,99 € reste chez
--  ce setter, dans l'Opt-in. Il ne repart pas dans les Leads du jour, et ne
--  passe pas dans les chiffres de base.
-- =====================================================================

-- 1. Lire et modifier les opt-in de son équipe (comme les autres leads).
drop policy if exists "staff lit les leads" on public.leads;
create policy "staff lit les leads"
  on public.leads for select to authenticated
  using (public.is_admin()
         or (public.is_staff() and equipe = any(public.mes_equipes())));

drop policy if exists "staff modifie les leads" on public.leads;
create policy "staff modifie les leads"
  on public.leads for update to authenticated
  using  (public.is_admin()
          or (public.is_staff() and not public.compte_limite()
              and equipe = any(public.mes_equipes())))
  with check (public.is_admin()
              or (public.is_staff() and not public.compte_limite()
                  and equipe = any(public.mes_equipes())));

-- 2. Le paiement des 9,99 € : un opt-in que personne n'a pris passe dans
--    les Leads du jour, comme avant. Un opt-in déjà pris reste à son setter,
--    dans l'Opt-in.
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

  -- Seul le produit de la page (« Base 44 », 9,99 €) concerne le CRM.
  if coalesce(p->>'product_id', p->'product'->>'id', '') <> 'prod_UQFQCnFzTFob6' then
    return 'autre produit';
  end if;

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

  -- Opt-in libre : il entre dans les Leads du jour comme s'il venait
  -- d'arriver. Opt-in déjà pris : il reste où il est, marqué payé.
  update public.leads
     set vivier          = case when vivier = 'optin' and setter_id is not null then vivier else 'formulaire' end,
         formulaire_at   = coalesce(formulaire_at, created_at),
         created_at      = case when vivier = 'optin' and setter_id is null then now() else created_at end,
         paye_at         = coalesce(paye_at, now()),
         whop_payment_id = coalesce(whop_payment_id, v_id)
   where id = v_lead.id;

  return 'rattache';
end;
$$;

revoke all on function public.whop_paiement_recu(jsonb) from public, anon, authenticated;
grant execute on function public.whop_paiement_recu(jsonb) to service_role;

notify pgrst, 'reload schema';

-- Vérification : une seule ligne, tout à true.
select
  (select count(*) from pg_policies where tablename = 'leads'
     and policyname in ('staff lit les leads', 'staff modifie les leads')
     and qual not like '%optin%') = 2                                                 as optin_ouvert_aux_setters,
  (select count(*) from pg_policies where tablename = 'leads'
     and policyname = 'staff modifie les leads' and qual like '%compte_limite%') = 1   as direction_toujours_en_lecture,
  pg_get_functiondef('public.whop_paiement_recu(jsonb)'::regprocedure)
     like '%setter_id is not null%'                                                    as optin_pris_reste_au_setter;
