-- =====================================================================
--  12a — Le statut de vente « Builder annuel » (11/11/2026)
--  À passer SEUL d'abord (Run), puis 12b dans une nouvelle requête :
--  Postgres n'accepte pas qu'un nouveau statut serve dans la même requête.
-- =====================================================================
alter type public.lead_statut add value if not exists 'yearly_builder';
