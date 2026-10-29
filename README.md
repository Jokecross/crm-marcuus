# CRM des setters — Marcuus (Masterclass Black Friday 2026)

En ligne : https://crm-marcuus-eight.vercel.app · espace membre : https://esapcemembre-marcuus.vercel.app

Back-office des setters de la Masterclass Black Friday 2026 de Marcuus Lawrence,
repris tel quel du CRM de Mexed (`~/CRM Mexed`, non modifié). Un seul fichier
(`index.html`), sans build : Vercel le sert tel quel. Il lit et écrit dans le
projet Supabase de Marcuus (`vptuzxbjyiajntoctibx`), le même que la page de vente
(`~/page de vente Marcus`) et l'espace membre (`~/Espace Membre Marcuus`).

```
index.html                  le CRM (HTML, CSS, JS)
supabase/INSTALLATION.sql   toute la base : leads, CRM, espace membre
supabase/remise-a-zero.sql  vide les données de test
scripts/creer-comptes.mjs   crée les comptes de l'équipe
scripts/equipe.json         la liste de l'équipe
```

## Les deux équipes

| Équipe | Clé en base | Ce qu'elle travaille |
|---|---|---|
| **Base44** | `starter` | les leads du formulaire de la page de vente : vivier « Leads du jour », compte à rebours de 10 minutes, le premier setter qui prend le lead l'a pour lui |
| **Marcuus Lawrence** | `marcuus` | ses propres leads, saisis à la main (pipeline, relances, archive, dashboard, factures) |

Les deux sont étanches : un setter ne voit jamais les leads de l'autre équipe.
La séparation vit dans les règles RLS de la base, pas seulement dans
l'interface. Les administrateurs voient les deux et basculent de l'une à
l'autre. Un setter peut être ouvert aux deux avec `"equipes": ["starter", "marcuus"]`.

## Le parcours d'un lead

1. Le formulaire de la page de vente insère une ligne dans `leads`
   (équipe `starter` = Base44, vivier `formulaire`).
2. Le lead apparaît en temps réel dans **Leads du jour**, avec un compte à
   rebours de 10 minutes.
3. Le setter l'appelle sur WhatsApp, change le statut. Une vente **Monthly** vaut
   200 $ (10 % de commission, 20 $), une vente **Yearly** 250 $ (15 %, 37,50 $),
   repris de Mexed. C'est la base qui fixe le montant et la commission.
4. Pendant l'appel, le setter ouvre l'espace membre → `/admin` → Invitations :
   il génère le lien de l'élève.

## Installer

1. Projet Supabase de Marcuus → **SQL Editor** → coller
   `supabase/INSTALLATION.sql` → **Run**. Rejouable.
2. Authentication → Sign In / Providers → désactiver **Allow new users to
   sign up**.
3. Renseigner `SUPABASE_URL` et `SUPABASE_ANON` en haut du script de
   `index.html` (tant qu'ils sont vides, la connexion affiche « Configuration
   Supabase manquante »), ainsi que dans la page de vente et le `.env` de
   l'espace membre. Puis `ESPACE_URL`, une fois l'espace membre en ligne.
4. Remplir `scripts/equipe.json` (un objet par personne, `"equipe": "starter"`
   pour Base44 ou `"marcuus"` pour Marcuus Lawrence), puis créer les comptes :

   ```
   SUPABASE_URL="…" SUPABASE_SERVICE_ROLE_KEY="…" node scripts/creer-comptes.mjs
   ```

   Les mots de passe sont écrits dans `scripts/comptes.csv`, ignoré par git.
   `MDP_PRENOM=1` donne `prénom123` aux setters (risqué : devinable).

## Retiré par rapport à Mexed

L'onglet **Automatique** (le parcours sans appel des numéros africains) : la page
Marcuus n'a pas ce parcours. Le code et les tables restent, inutilisés.
