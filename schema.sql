-- Shop Counter — database schema for Supabase (Postgres)
-- Run this once in the Supabase SQL editor on a new project.
--
-- Design notes
--   * One shop, two kinds of staff: owner and attendant.
--   * Cost prices and the supplier position are readable only by the owner.
--     That is enforced here, in the database, not in the page. An attendant
--     who opens developer tools still cannot read a cost.
--   * The attendant reads items through a view that has no cost column, and
--     records money through functions rather than by writing to tables that
--     hold costs.

-- ---------------------------------------------------------------- roles

create type public.staff_role as enum ('owner', 'attendant');

create table public.profiles (
  id          uuid primary key references auth.users on delete cascade,
  full_name   text,
  role        public.staff_role not null default 'attendant',
  created_at  timestamptz not null default now()
);

comment on table public.profiles is
  'One row per signed-in person. Role decides what they can see.';

-- Helpers. SECURITY DEFINER so a policy can read profiles without recursing
-- through the policy on profiles itself.
create or replace function public.is_owner()
  returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'owner');
$$;

create or replace function public.is_staff()
  returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid());
$$;

-- Every new sign-up starts as an attendant. Promote to owner by hand.
create or replace function public.handle_new_user()
  returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', new.email));
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------- tables

create table public.items (
  id          text primary key,
  name        text not null,
  qty         numeric not null default 0 check (qty >= 0),
  cost        numeric not null default 0 check (cost >= 0),   -- owner only
  price       numeric not null default 0 check (price >= 0),  -- the floor
  source      text not null default 'Own stock',
  sort_order  bigint not null default 0,
  created_at  timestamptz not null default now()
);
comment on column public.items.price is
  'Lowest price the attendant may sell at. Never below cost without a warning.';

create table public.customers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null default '',
  phone       text not null default '',
  phone_key   text unique,            -- normalised: the real identity
  note        text not null default '',
  first_seen  date not null default current_date,
  created_at  timestamptz not null default now()
);
comment on column public.customers.phone_key is
  'Digits only, local form. Two people may share a name, never a number.';

create table public.services (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  typical_charge numeric not null default 0,
  sort_order     bigint not null default 0
);

create table public.sales (
  id           uuid primary key default gen_random_uuid(),
  ts           timestamptz not null default now(),
  item_id      text references public.items(id) on delete set null,
  item_name    text not null,
  qty          numeric not null check (qty > 0),
  unit_price   numeric not null check (unit_price >= 0),
  total        numeric not null check (total >= 0),
  payment      text not null default 'cash',
  customer_id  uuid references public.customers(id) on delete set null,
  buyer        text not null default '',
  phone        text not null default '',
  received     numeric not null default 0 check (received >= 0),
  due_date     date,
  recorded_by  uuid references auth.users(id),
  constraint sales_received_within_total check (received <= total)
);

create table public.jobs (
  id           uuid primary key default gen_random_uuid(),
  ts           timestamptz not null default now(),
  service      text not null,
  charge       numeric not null check (charge >= 0),
  parts_cost   numeric not null default 0 check (parts_cost >= 0),
  device       text not null default '',
  payment      text not null default 'cash',
  customer_id  uuid references public.customers(id) on delete set null,
  buyer        text not null default '',
  phone        text not null default '',
  received     numeric not null default 0 check (received >= 0),
  due_date     date,
  recorded_by  uuid references auth.users(id),
  constraint jobs_received_within_charge check (received <= charge)
);

create table public.deals (
  id            uuid primary key default gen_random_uuid(),
  ts            timestamptz not null default now(),
  device        text not null,
  customer_id   uuid references public.customers(id) on delete set null,
  buyer         text not null default '',
  phone         text not null default '',
  cost          numeric not null default 0 check (cost >= 0),  -- owner only
  price         numeric not null check (price >= 0),
  down_payment  numeric not null default 0 check (down_payment >= 0),
  received      numeric not null default 0 check (received >= 0),
  instalment    numeric not null default 0 check (instalment >= 0),
  count         integer not null default 1 check (count >= 1),
  interval      text not null default 'month'
                check (interval in ('week', 'fortnight', 'month')),
  start_date    date,
  recorded_by   uuid references auth.users(id),
  constraint deals_received_within_price check (received <= price)
);
comment on table public.deals is
  'Phones given out on hire purchase. cost is the owner''s figure only.';

create table public.payments (
  id         uuid primary key default gen_random_uuid(),
  ts         timestamptz not null default now(),
  ref_type   text not null check (ref_type in ('sale','job','deal','tranche','receivable')),
  ref_id     text not null,
  who        text not null default '',
  amount     numeric not null check (amount > 0),
  taken_by   uuid references auth.users(id)
);
comment on table public.payments is
  'Every instalment as it arrives, so a balance can be explained.';

-- Owner-only tables ------------------------------------------------------

create table public.expenses (
  id      uuid primary key default gen_random_uuid(),
  ts      date not null default current_date,
  what    text not null,
  amount  numeric not null check (amount > 0)
);

create table public.tranches (
  id        uuid primary key default gen_random_uuid(),
  label     text not null,
  due_date  date,
  amount    numeric not null check (amount >= 0),
  paid      numeric not null default 0 check (paid >= 0),
  sort_order bigint not null default 0,
  constraint tranches_paid_within_amount check (paid <= amount)
);
comment on table public.tranches is 'What is owed to the supplier, and when.';

create table public.receivables (
  id        uuid primary key default gen_random_uuid(),
  name      text not null,
  amount    numeric not null check (amount >= 0),
  paid      numeric not null default 0 check (paid >= 0),
  due_date  date,
  sort_order bigint not null default 0,
  constraint receivables_paid_within_amount check (paid <= amount)
);

-- ---------------------------------------------------------------- indexes

create index sales_ts_idx        on public.sales (ts desc);
create index sales_item_idx      on public.sales (item_id);
create index sales_customer_idx  on public.sales (customer_id);
create index jobs_ts_idx         on public.jobs (ts desc);
create index jobs_customer_idx   on public.jobs (customer_id);
create index deals_customer_idx  on public.deals (customer_id);
create index payments_ref_idx    on public.payments (ref_type, ref_id);
create index customers_key_idx   on public.customers (phone_key);

-- ---------------------------------------------------------------- RLS

alter table public.profiles    enable row level security;
alter table public.items       enable row level security;
alter table public.customers   enable row level security;
alter table public.services    enable row level security;
alter table public.sales       enable row level security;
alter table public.jobs        enable row level security;
alter table public.deals       enable row level security;
alter table public.payments    enable row level security;
alter table public.expenses    enable row level security;
alter table public.tranches    enable row level security;
alter table public.receivables enable row level security;

-- profiles: you may read your own row; the owner may read and change all.
create policy profiles_self_read on public.profiles
  for select using (id = auth.uid() or public.is_owner());
create policy profiles_owner_write on public.profiles
  for all using (public.is_owner()) with check (public.is_owner());

-- items: the cost column lives here, so only the owner reads the table.
-- Staff read items through public.items_counter, below.
create policy items_owner_all on public.items
  for all using (public.is_owner()) with check (public.is_owner());

-- deals: same reasoning — cost is here.
create policy deals_owner_all on public.deals
  for all using (public.is_owner()) with check (public.is_owner());

-- Things an attendant works with directly.
create policy customers_staff_read on public.customers
  for select using (public.is_staff());
create policy customers_staff_write on public.customers
  for insert with check (public.is_staff());
create policy customers_staff_update on public.customers
  for update using (public.is_staff()) with check (public.is_staff());
create policy customers_owner_delete on public.customers
  for delete using (public.is_owner());

create policy services_staff_read on public.services
  for select using (public.is_staff());
create policy services_owner_write on public.services
  for all using (public.is_owner()) with check (public.is_owner());

create policy sales_staff_read on public.sales
  for select using (public.is_staff());
create policy sales_staff_insert on public.sales
  for insert with check (public.is_staff());
create policy sales_staff_update on public.sales
  for update using (public.is_staff()) with check (public.is_staff());
-- An attendant may undo only what he recorded today; the owner may undo anything.
create policy sales_delete on public.sales
  for delete using (public.is_owner() or (public.is_staff() and ts::date = current_date));

create policy jobs_staff_read on public.jobs
  for select using (public.is_staff());
create policy jobs_staff_insert on public.jobs
  for insert with check (public.is_staff());
create policy jobs_staff_update on public.jobs
  for update using (public.is_staff()) with check (public.is_staff());
create policy jobs_delete on public.jobs
  for delete using (public.is_owner() or (public.is_staff() and ts::date = current_date));

create policy payments_staff_read on public.payments
  for select using (public.is_staff());
create policy payments_staff_insert on public.payments
  for insert with check (public.is_staff());
create policy payments_owner_delete on public.payments
  for delete using (public.is_owner());

-- Owner only, no staff access at all.
create policy expenses_owner_all on public.expenses
  for all using (public.is_owner()) with check (public.is_owner());
create policy tranches_owner_all on public.tranches
  for all using (public.is_owner()) with check (public.is_owner());
create policy receivables_owner_all on public.receivables
  for all using (public.is_owner()) with check (public.is_owner());

-- ------------------------------------------------- cost-free staff views
-- These deliberately run as definer so they can read the base tables the
-- attendant cannot. They expose no cost column, so there is nothing to leak.

create view public.items_counter
  with (security_invoker = off) as
  select id, name, qty, price, source, sort_order
  from public.items;

create view public.deals_counter
  with (security_invoker = off) as
  select id, ts, device, customer_id, buyer, phone,
         price, down_payment, received, instalment, count, interval, start_date
  from public.deals;

revoke all on public.items_counter from anon, authenticated;
revoke all on public.deals_counter from anon, authenticated;
grant select on public.items_counter to authenticated;
grant select on public.deals_counter to authenticated;

-- --------------------------------------------- money-recording functions
-- An attendant must be able to take a hire-purchase instalment without being
-- able to read the deal's cost. These run as definer and touch only what they
-- need to, so there is no path from "record a payment" to "see the margin".

create or replace function public.record_deal_payment(p_deal uuid, p_amount numeric)
  returns numeric language plpgsql security definer set search_path = public as $$
declare
  v_price numeric;
  v_received numeric;
  v_new numeric;
  v_who text;
begin
  if not public.is_staff() then
    raise exception 'not allowed';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be above zero';
  end if;

  select price, received, buyer into v_price, v_received, v_who
  from public.deals where id = p_deal for update;
  if not found then
    raise exception 'no such deal';
  end if;

  v_new := least(v_price, v_received + p_amount);
  update public.deals set received = v_new where id = p_deal;

  insert into public.payments (ref_type, ref_id, who, amount, taken_by)
  values ('deal', p_deal::text, v_who, v_new - v_received, auth.uid());

  return v_price - v_new;   -- the balance still outstanding
end;
$$;

-- Adding stock is the owner's job, but the floor price can be corrected by
-- the owner alone too; this exists so the app has one clear entry point.
create or replace function public.set_item_floor(p_item text, p_price numeric)
  returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then
    raise exception 'only the owner may change a floor price';
  end if;
  update public.items set price = p_price where id = p_item;
end;
$$;

revoke all on function public.record_deal_payment(uuid, numeric) from anon;
revoke all on function public.set_item_floor(text, numeric) from anon;
grant execute on function public.record_deal_payment(uuid, numeric) to authenticated;
grant execute on function public.set_item_floor(text, numeric) to authenticated;

-- --------------------------------------------------------- the one clock
-- A browser cannot read the Date response header across origins, and a device
-- can be hours wrong: this shop's laptop was four hours out, which filed an
-- evening's trading under the next day. The app asks here instead.

create or replace function public.server_now()
  returns timestamptz language sql stable as $$
  select now();
$$;

revoke all on function public.server_now() from public;
grant execute on function public.server_now() to anon, authenticated;

-- ---------------------------------------------------------------- grants

grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.sales, public.jobs, public.customers, public.payments
  to authenticated;
grant select, insert, update, delete on public.services to authenticated;
grant select, insert, update, delete on
  public.items, public.deals, public.expenses, public.tranches,
  public.receivables, public.profiles
  to authenticated;   -- RLS above is what actually restricts these
