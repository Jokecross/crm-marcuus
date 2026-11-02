-- =====================================================================
--  04 — Martin vérifie la facture, puis envoie la vente dans le CRM
--
--  Une invitation créée par un closer Marcuus (avec facture) naît
--  « à vérifier ». Depuis le back-office de l'espace membre, l'administrateur
--  général (Martin seul) :
--    • « Envoyer dans le CRM » → crée le lead dans l'équipe du closer, en
--      Mensuel (200 $) ou Annuel (250 $), rattaché au closer, avec la facture
--      dans l'onglet Factures ; l'invitation passe « validée » ;
--    • « Refuser » → l'invitation passe « refusée » et le lien est désactivé.
--  Rejouable. Supabase → SQL Editor → Run.
-- =====================================================================

-- 1. L'état de la vérification, sur l'invitation
alter table public.invites add column if not exists verif       text;
alter table public.invites add column if not exists verif_at    timestamptz;
alter table public.invites add column if not exists verif_motif text;
alter table public.invites add column if not exists lead_id     uuid references public.leads on delete set null;

alter table public.invites drop constraint if exists invites_verif_check;
alter table public.invites add constraint invites_verif_check
  check (verif is null or verif in ('a_verifier', 'validee', 'refusee'));

update public.invites set verif = 'a_verifier'
where facture_path is not null and verif is null;

-- Une invitation avec facture naît toujours « à vérifier » : personne ne
-- se valide soi-même à la création.
create or replace function public.invite_a_verifier()
returns trigger
language plpgsql
as $$
begin
  if new.facture_path is not null then
    new.verif := 'a_verifier';
    new.verif_at := null;
    new.verif_motif := null;
    new.lead_id := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_invite_a_verifier on public.invites;
create trigger trg_invite_a_verifier
  before insert on public.invites
  for each row execute function public.invite_a_verifier();

-- 2. La facture d'un client vit dans un autre seau que celles des setters
alter table public.invoices add column if not exists bucket text not null default 'factures';

-- 3. Envoyer dans le CRM
create or replace function public.valider_vente(p_token uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  i      public.invites;
  lid    uuid;
  tel    text;
  eq     text;
begin
  if not public.is_admin() then
    raise exception 'Réservé à l''administrateur général.';
  end if;

  select * into i from public.invites where token = p_token for update;
  if not found then raise exception 'Invitation introuvable.'; end if;
  if i.verif is distinct from 'a_verifier' then
    raise exception 'Cette vente a déjà été traitée.';
  end if;

  -- 06 12 34 56 78 → +33612345678 ; un numéro déjà international reste tel quel.
  tel := regexp_replace(coalesce(i.client_telephone, ''), '[^0-9+]', '', 'g');
  if tel ~ '^0[1-9][0-9]{8}$' then tel := '+33' || substr(tel, 2); end if;
  if tel ~ '^00' then tel := '+' || substr(tel, 3); end if;
  if char_length(tel) < 9 then
    raise exception 'Le téléphone du client est trop court : %', i.client_telephone;
  end if;

  select equipe into eq from public.staff where user_id = i.created_by;

  insert into public.leads (first_name, last_name, email, phone, status, setter_id,
                            equipe, source, called_at)
  values (i.client_prenom, i.client_nom, lower(i.client_email), tel,
          case i.plan_code when 'annuel' then 'yearly' else 'monthly' end::lead_statut,
          i.created_by, coalesce(eq, 'marcuus'), 'espace-membre', now())
  returning id into lid;

  insert into public.invoices (lead_id, setter_id, file_path, file_name, bucket)
  values (lid, i.created_by, i.facture_path,
          'Facture ' || i.client_prenom || ' ' || i.client_nom, 'factures-clients');

  update public.invites
     set verif = 'validee', verif_at = now(), lead_id = lid
   where token = p_token;

  return lid;
end;
$$;

-- 4. Refuser : le lien ne s'ouvre plus
create or replace function public.refuser_vente(p_token uuid, p_motif text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Réservé à l''administrateur général.';
  end if;

  update public.invites
     set verif = 'refusee', verif_at = now(), verif_motif = nullif(trim(p_motif), ''),
         expires_at = least(expires_at, now())
   where token = p_token and verif = 'a_verifier';

  if not found then raise exception 'Cette vente a déjà été traitée.'; end if;
end;
$$;

-- L'espace membre demande « suis-je l'administrateur général ? » pour
-- afficher les deux boutons.
create or replace function public.est_admin_general()
returns boolean
language sql stable security definer set search_path = public
as $$ select public.is_admin(); $$;

revoke all on function public.valider_vente(uuid), public.refuser_vente(uuid, text), public.est_admin_general() from public, anon;
grant execute on function public.valider_vente(uuid), public.refuser_vente(uuid, text), public.est_admin_general() to authenticated;

-- 5. Le CRM ouvre ces factures : le closer (son dossier) et les admins y
--    ont déjà accès par « facture client lue ». Rien à ajouter.

-- Vérification
select verif, count(*) from public.invites group by verif;
