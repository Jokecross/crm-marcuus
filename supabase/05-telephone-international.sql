-- 05 — « 33617649718 » devient « +33617649718 » à l'envoi dans le CRM. Rejouable.

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
  -- 33617649718 : indicatif sans le « + ».
  if tel ~ '^[1-9][0-9]{9,14}$' then tel := '+' || tel; end if;
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

select 'ok' as telephone_corrige;
