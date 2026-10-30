-- PILOTAGE FINANCIER V2 — initialisation Supabase
-- À coller dans Supabase > SQL Editor > Run. Relançable : repart de zéro.

drop view  if exists public.v_wallet_balances, public.v_debts;
drop table if exists public.forecasts, public.debts, public.wallet_movements,
  public.actor_allocations, public.operations, public.wallets, public.actors,
  public.categories, public.settings cascade;

-- Paramètres -----------------------------------------------------------
create table public.settings (key text primary key, value text not null);
insert into public.settings values ('horizon_days','90'), ('tolerance','0.5');

create table public.categories (name text primary key);
insert into public.categories values ('Ventes / formations'),('Salaires'),('Loyer'),
 ('Marketing'),('Fournitures'),('Transport'),('Abonnements'),('Impôts / taxes'),
 ('Investissement'),('Frais bancaires'),('Dépenses personnelles'),('Autre');

-- Acteurs & portefeuilles ---------------------------------------------
create table public.actors (
  id text primary key,
  name text not null unique,
  type text not null check (type in ('Personne','Entreprise')),
  status text not null default 'Actif' check (status in ('Actif','Inactif')),
  safety_reserve numeric not null default 0 check (safety_reserve >= 0)
);

create table public.wallets (
  id text primary key,
  name text not null unique,
  type text not null check (type in ('Compte bancaire','Caisse physique','Mobile Money','Autre')),
  legal_holder text not null references public.actors(name) on update cascade,
  economic_owner text not null references public.actors(name) on update cascade,
  initial_balance numeric not null default 0,
  ref_date date
);

-- Journal des opérations ----------------------------------------------
create table public.operations (
  id text primary key,                                   -- OP-0001…
  op_date date not null,
  label text,
  nature text not null check (nature in ('Dépense','Recette','Transfert','Prêt accordé',
    'Emprunt reçu','Remboursement de prêt','Apport','Retrait / distribution','Autre')),
  category text references public.categories(name) on update cascade,
  amount numeric not null check (amount > 0),
  status text not null default 'Réel' check (status in ('Réel','Annulé')),
  reference text,
  notes text,
  created_at timestamptz not null default now()
);

create table public.actor_allocations (
  id bigint generated always as identity primary key,
  operation_id text not null references public.operations(id) on update cascade on delete cascade,
  actor text not null references public.actors(name) on update cascade,
  imputation text not null check (imputation in ('Charge supportée','Recette bénéficiaire',
    'Prêteur','Emprunteur','Apporteur','Bénéficiaire (apport / distribution)','Autre')),
  pct numeric check (pct between 0 and 1),               -- 0.5 = 50 %
  amount_input numeric check (amount_input >= 0),        -- le montant l'emporte sur le %
  check (pct is not null or amount_input is not null)
);

create table public.wallet_movements (
  id bigint generated always as identity primary key,
  operation_id text not null references public.operations(id) on update cascade on delete cascade,
  wallet text not null references public.wallets(name) on update cascade,
  actor text not null references public.actors(name) on update cascade,
  direction text not null check (direction in ('Entrée','Sortie')),
  amount numeric not null check (amount > 0)
);

-- Dettes & prévisions --------------------------------------------------
create table public.debts (
  id text primary key,
  debt_date date not null,
  creditor text not null references public.actors(name) on update cascade,
  debtor text not null references public.actors(name) on update cascade,
  type text not null check (type in ('Prêt remboursable','Avance remboursable',
    'Apport non remboursable','Prise en charge définitive')),
  initial_amount numeric not null check (initial_amount > 0),
  repaid numeric not null default 0 check (repaid >= 0),
  due_date date,
  operation_id text references public.operations(id) on update cascade on delete set null,
  notes text,
  check (creditor <> debtor),
  check (repaid <= initial_amount)
);

create table public.forecasts (
  id text primary key,
  forecast_date date not null,
  nature text not null check (nature in ('Recette attendue','Remboursement attendu',
    'Dépense prévue','Remboursement à payer','Investissement')),
  actor text not null references public.actors(name) on update cascade,
  wallet text references public.wallets(name) on update cascade,
  category text references public.categories(name) on update cascade,
  label text,
  amount numeric not null check (amount > 0),
  probability numeric not null check (probability between 0 and 1)
);

create index on public.operations (op_date);
create index on public.actor_allocations (operation_id);
create index on public.wallet_movements (operation_id);
create index on public.wallet_movements (wallet);
create index on public.forecasts (forecast_date);

-- Vues (équivalents des colonnes calculées d'Excel) ---------------------
create view public.v_wallet_balances with (security_invoker = true) as
with n as (
  select w.id, coalesce(sum(case when o.status = 'Réel'
           and (w.ref_date is null or o.op_date >= w.ref_date)
           then case m.direction when 'Entrée' then m.amount else -m.amount end end), 0) as net
  from public.wallets w
  left join public.wallet_movements m on m.wallet = w.name
  left join public.operations o on o.id = m.operation_id
  group by w.id)
select w.id, w.name, w.type, w.legal_holder, w.economic_owner, w.initial_balance,
       n.net as net_movements, w.initial_balance + n.net as theoretical_balance
from public.wallets w join n using (id);

create view public.v_debts with (security_invoker = true) as
select d.*,
  case when d.type in ('Prêt remboursable','Avance remboursable')
       then greatest(d.initial_amount - d.repaid, 0) else 0 end as balance_due,
  case when d.type not in ('Prêt remboursable','Avance remboursable') then 'Définitif'
       when d.initial_amount - d.repaid <= 0.5 then 'Soldé'
       when d.due_date < current_date then 'En retard' else 'En cours' end as status
from public.debts d;

-- Sécurité : seuls les utilisateurs connectés accèdent aux données -------
do $$
declare t text;
begin
  foreach t in array array['settings','categories','actors','wallets','operations',
    'actor_allocations','wallet_movements','debts','forecasts'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "authenticated_all" on public.%I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

-- Crée ensuite l'utilisateur : Authentication > Users > Add user (e-mail + mot de passe).
