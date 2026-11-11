-- =====================================================================
--  12b — Les 3 ventes et leurs commissions (11/11/2026), après 12a.
--  À coller dans Supabase → SQL Editor → New query → Run. Rejouable.
--
--    Statut          Offre             Montant   Commission du setter
--    monthly         Builder mensuel   200 $     10 %
--    yearly          Starter annuel    250 $     12,5 % (15 % avant le 11/11)
--    yearly_builder  Builder annuel    450 $     15 %
--
--  Les ventes conclues avant le 11/11/2026 (heure de Paris) gardent leur
--  commission : seul l'annuel Starter change de taux, et seulement pour les
--  ventes à partir de cette date. Le Builder annuel compte comme une vente
--  annuelle dans tous les chiffres (ventes, annuels, part des annuels).
-- =====================================================================

-- 1. Le montant imposé par la base, selon l'offre.
create or replace function public.forcer_tarif()
returns trigger
language plpgsql
as $$
begin
  new.cash_collecte := case new.status::text
    when 'monthly'        then 200
    when 'yearly'         then 250
    when 'yearly_builder' then 450
    else 0
  end;
  return new;
end;
$$;

-- 2. La commission, calculée par la base sur le cash collecté.
--    1794351600 = 11/11/2026 00:00, heure de Paris.
alter table public.leads drop column if exists commission;
alter table public.leads add column commission numeric(10,2)
  generated always as (
    case status::text
      when 'monthly'        then round(cash_collecte * 0.10, 2)
      when 'yearly'         then round(cash_collecte * case when closed_at < to_timestamp(1794351600) then 0.15 else 0.125 end, 2)
      when 'yearly_builder' then round(cash_collecte * 0.15, 2)
      else 0
    end
  ) stored;

-- 3. Toutes les fonctions qui comptent les ventes : le Builder annuel y entre
--    comme une vente, et comme un annuel. L'invitation « Builder annuel » de
--    l'espace membre devient une vente Builder annuel.
do $$
declare
  f record;
  corps text;
  nouveau text;
begin
  for f in
    select p.oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.prosrc like '%''yearly''%' and p.prosrc not like '%yearly_builder%'
       and p.proname <> 'forcer_tarif'
  loop
    corps := pg_get_functiondef(f.oid);
    nouveau := corps;
    nouveau := replace(nouveau, '''monthly'', ''yearly'')', '''monthly'', ''yearly'', ''yearly_builder'')');
    nouveau := replace(nouveau, '''monthly'',''yearly'')', '''monthly'',''yearly'',''yearly_builder'')');
    nouveau := replace(nouveau, '''monthly'',''yearly'',''ghosted''', '''monthly'',''yearly'',''yearly_builder'',''ghosted''');
    nouveau := replace(nouveau, '''monthly'', ''yearly'', ''ghosted''', '''monthly'', ''yearly'', ''yearly_builder'', ''ghosted''');
    nouveau := regexp_replace(nouveau, 'status\s*=\s*''yearly''', 'status in (''yearly'', ''yearly_builder'')', 'g');
    nouveau := replace(nouveau, 'when ''annuel'' then ''yearly'' else', 'when ''annuel'' then ''yearly'' when ''builder_annuel'' then ''yearly_builder'' else');
    if nouveau <> corps then
      execute nouveau;
      raise notice 'mise à jour : %', f.oid::regprocedure;
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';

-- Vérification : les fonctions qui parlent encore de « yearly » sans le
-- Builder annuel (doit être vide, hormis forcer_tarif qui a les trois).
select p.proname as a_verifier
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prosrc like '%''yearly''%' and p.prosrc not like '%yearly_builder%';
