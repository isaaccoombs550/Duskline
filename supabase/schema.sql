-- Duskline — Supabase schema
--
-- This is not an automated migration runner — there's no CLI/migrations setup in this
-- repo. This file exists purely as a source of truth for what's actually been run
-- against the live project (https://bolwcxusbfsizsjtulvr.supabase.co) via the SQL
-- Editor, so the schema isn't only visible in the Supabase dashboard. If you change
-- anything about companies/profiles/RLS, update this file to match in the same session.
--
-- Phase 1 of the backend migration (see ../duskline-going-live-roadmap.md and
-- ../CLAUDE.md): real accounts, multi-tenant by company. Projects/fixtures/company
-- data are NOT in this database yet — that's Phase 2, still localStorage-only.

create table public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  full_name text,
  role text not null default 'owner' check (role in ('owner','member')),
  created_at timestamptz not null default now()
);

alter table public.companies enable row level security;
alter table public.profiles enable row level security;

-- Looks up the caller's own company_id. SECURITY DEFINER so it runs as the function's
-- owner (bypassing RLS for this one read) rather than as the calling user — required
-- because a `profiles` RLS policy cannot safely subquery `profiles` directly: that was
-- tried first and produced Postgres error 42P17, "infinite recursion detected in policy
-- for relation profiles" (the subquery re-triggers the same policy it's used in).
create or replace function public.current_company_id()
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  select company_id from public.profiles where id = auth.uid()
$$;

create policy "Users can view their own company"
  on public.companies for select
  using (id = public.current_company_id());

create policy "Users can view profiles in their own company"
  on public.profiles for select
  using (company_id = public.current_company_id());

create policy "Users can update their own profile"
  on public.profiles for update
  using (id = auth.uid());

-- Fires on every new Supabase Auth signup. Reads company_name/full_name out of the
-- signup call's `options.data` (see submitAuthForm() in the HTML file) and provisions
-- one new company + one profile (role: 'owner') per signup. There is currently no way
-- for a second person to join an EXISTING company — every signup creates its own tenant.
-- Adding a real invite flow is future work, not yet scoped.
--
-- Access-code gate (added while onboarding is by invite only, see ../CLAUDE.md): if
-- new.raw_user_meta_data->>'access_code' doesn't match the hardcoded value below, this
-- raises, which rolls back the whole trigger transaction — including the auth.users row
-- Supabase Auth had just inserted — so the signup fails atomically rather than leaving an
-- orphaned auth user with no company/profile row. This intentionally lives in the trigger
-- (server-side), not just as a client-side field check, so it can't be bypassed by editing
-- the page's JS. To change the code or remove the gate entirely, re-run this whole
-- `create or replace function` block via the SQL Editor with the code updated (or the
-- `if` block deleted to remove the gate).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  new_company_id uuid;
begin
  if new.raw_user_meta_data->>'access_code' is distinct from 'DUSKLINEBETAV12026' then
    raise exception 'invalid access code';
  end if;

  insert into public.companies (name)
  values (coalesce(new.raw_user_meta_data->>'company_name', 'My Company'))
  returning id into new_company_id;

  insert into public.profiles (id, company_id, full_name, role)
  values (new.id, new_company_id, new.raw_user_meta_data->>'full_name', 'owner');

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================================
-- Phase 2 (see ../CLAUDE.md "Backend migration progress"): projects, areas, and
-- the fixture library move from localStorage into Postgres, scoped by company
-- via the same current_company_id() pattern as Phase 1. Company branding/quote-
-- appearance settings (previously only in client-side state.company) also move
-- onto the companies table.
-- ============================================================================

alter table public.companies
  add column phone text not null default '',
  add column email text not null default '',
  add column address text not null default '',
  add column website text not null default '',
  add column logo text,
  add column tax_rate numeric not null default 0,
  add column tax_label text not null default 'Tax',
  add column quote_accent text not null default '#F0A84E',
  add column pdf_logo_size int not null default 30,
  add column pdf_font_size int not null default 10,
  add column pdf_bg_color text not null default '#FFFFFF',
  add column heading_align text not null default 'left',
  add column section_order jsonb not null default '["header","customer","areas","load","quote"]';

-- Phase 1 only let a user read their own company row; settings need to be editable too.
create policy "Users can update their own company"
  on public.companies for update
  using (id = public.current_company_id())
  with check (id = public.current_company_id());

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  customer jsonb not null default '{}',        -- {name, phone, email, address}
  discount_percent numeric not null default 0,
  discount_reason text not null default '',
  labor_cost numeric not null default 0,
  created_at timestamptz not null default now()
);

-- One row per area. placements/wire_runs/light_strips/accessory_qty stay as JSONB rather
-- than further-normalized tables: the app always reads and writes each of these as a
-- whole unit whenever an area is open in the editor, so normalizing them would add
-- relational complexity without a real benefit. photo is still an inline base64 data URL
-- for now (moving it to Supabase Storage is Phase 3, not done here).
create table public.areas (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  name text not null,
  photo text,
  photo_aspect numeric,
  darkness numeric not null default 0.6,
  beam_brightness numeric not null default 1,
  placements jsonb not null default '[]',
  accessory_qty jsonb not null default '{}',
  wire_runs jsonb not null default '[]',
  light_strips jsonb not null default '[]',
  created_at timestamptz not null default now()
);

-- id stays a client-generated text id ('c'+timestamp), matching what the app already
-- generated for custom fixtures pre-migration — no reason to force it onto a uuid.
create table public.custom_fixtures (
  id text primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  data jsonb not null
);

-- base_fixture_id references one of the hardcoded BASE_FIXTURES ids (e.g. 'f1') defined
-- in the HTML file itself, not a database table — there's no fixtures catalog table.
create table public.fixture_overrides (
  company_id uuid not null references public.companies(id) on delete cascade,
  base_fixture_id text not null,
  data jsonb not null,
  primary key (company_id, base_fixture_id)
);

-- Distributors a company orders fixtures from. A fixture references one by id (stored as
-- vendorId inside its own data/override blob, or directly on a BASE_FIXTURES entry) rather
-- than duplicating name/email/phone onto every fixture that uses the same distributor.
create table public.distributors (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  email text not null default '',
  phone text not null default '',
  account_number text not null default '',
  created_at timestamptz not null default now()
);

alter table public.projects enable row level security;
alter table public.areas enable row level security;
alter table public.custom_fixtures enable row level security;
alter table public.fixture_overrides enable row level security;
alter table public.distributors enable row level security;

create policy "Company members manage their own projects"
  on public.projects for all
  using (company_id = public.current_company_id())
  with check (company_id = public.current_company_id());

create policy "Company members manage their own areas"
  on public.areas for all
  using (project_id in (select id from public.projects where company_id = public.current_company_id()))
  with check (project_id in (select id from public.projects where company_id = public.current_company_id()));

create policy "Company members manage their own custom fixtures"
  on public.custom_fixtures for all
  using (company_id = public.current_company_id())
  with check (company_id = public.current_company_id());

create policy "Company members manage their own fixture overrides"
  on public.fixture_overrides for all
  using (company_id = public.current_company_id())
  with check (company_id = public.current_company_id());

create policy "Company members manage their own distributors"
  on public.distributors for all
  using (company_id = public.current_company_id())
  with check (company_id = public.current_company_id());

-- ============================================================================
-- Phase 3 (see ../CLAUDE.md "Backend migration progress"): area photos and the
-- company logo move out of the JSON (they were base64 data URLs inline in
-- areas.photo / companies.logo) into Supabase Storage. The columns themselves
-- are unchanged (still `text`) — they now hold a Storage public URL instead of
-- a data: URL. Existing rows with an inline base64 photo keep working as-is
-- (an <img> doesn't care whether its src is a data: URL or an https:// URL);
-- there's no backfill migration, they just naturally move to Storage the next
-- time that area's photo (or the logo) is changed.
--
-- Bucket is public: reading a photo needs no auth (simplest — an <img src>
-- just works, no signed URLs to refresh), and the object path always starts
-- with the owning company's id, which is an unguessable uuid, not enumerable
-- or listable by anyone outside the bucket policies below. Uploads/overwrites/
-- deletes still go through RLS-equivalent storage policies scoped by
-- company_id via the path convention {company_id}/... — see uploadAreaPhoto/
-- uploadCompanyLogo in the HTML file for the exact paths used.
insert into storage.buckets (id, name, public)
values ('photos', 'photos', true)
on conflict (id) do nothing;

create policy "Company members manage their own photos"
  on storage.objects for all
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = public.current_company_id()::text)
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = public.current_company_id()::text);

-- ============================================================================
-- Quote footer: free-text field shown at the very end of every printed/exported
-- quote (payment terms, a thank-you note, license info, etc.). Not part of the
-- reorderable PDF section list (section_order) — a footer is always last by
-- definition, so it renders via a fixed high CSS order value instead.
alter table public.companies
  add column footer_text text not null default '';

-- ============================================================================
-- Distributor accounts (see ../CLAUDE.md): a distributor company maintains one
-- fixture catalog and gives out contractor accounts, each with its own price
-- multiplier applied live against the distributor's own list price. See
-- CLAUDE.md's "Distributor accounts" section for the full design rationale —
-- summarized inline here since it's not obvious from the SQL alone.
-- ============================================================================

alter table public.companies
  add column account_type text not null default 'contractor'
    check (account_type in ('contractor','distributor'));

-- The existing "Users can update their own company" policy (Phase 2, above) has no
-- column restriction — as written, any signed-in user could PATCH their own company
-- row and set account_type:'distributor' directly via the REST API, bypassing the UI
-- entirely. Column-level grants close that: account_type is deliberately excluded
-- from the writable list below, so it can only ever be set by handle_new_user()
-- (SECURITY DEFINER, bypasses grants) at signup, never by an ordinary update.
revoke update on public.companies from authenticated;
grant update (name, phone, email, address, website, logo, tax_rate, tax_label,
  quote_accent, pdf_logo_size, pdf_font_size, pdf_bg_color, heading_align,
  section_order, footer_text) on public.companies to authenticated;

-- One row per contractor a distributor has onboarded. multiplier is what turns the
-- distributor's own custom_fixtures.price (their sell price -- which IS the
-- contractor's list price) into that specific contractor's net cost, computed live
-- by contractor_catalog_view below -- there is no copy/snapshot anywhere, so a
-- multiplier or price change is visible to the contractor on their very next load.
create table public.distributor_links (
  distributor_company_id uuid not null references public.companies(id) on delete cascade,
  contractor_company_id uuid not null references public.companies(id) on delete cascade,
  multiplier numeric not null default 1,
  created_at timestamptz not null default now(),
  primary key (distributor_company_id, contractor_company_id)
);

-- How a distributor onboards a contractor who doesn't have an account yet. Redeemed
-- via the SAME access_code signup field the beta gate already uses (see
-- handle_new_user() below) -- no separate "distributor invite code" field exists in
-- the signup form; the trigger disambiguates server-side by looking the code up here
-- first, before falling back to the hardcoded beta/distributor codes.
create table public.distributor_invites (
  code text primary key,
  distributor_company_id uuid not null references public.companies(id) on delete cascade,
  multiplier numeric not null default 1,
  label text not null default '',
  created_at timestamptz not null default now(),
  redeemed_at timestamptz,
  used_by_company_id uuid references public.companies(id)
);

alter table public.distributor_links enable row level security;
alter table public.distributor_invites enable row level security;

create policy "Distributor manages own links"
  on public.distributor_links for all
  using (distributor_company_id = public.current_company_id())
  with check (distributor_company_id = public.current_company_id());

-- A contractor can read their own link row (which distributor(s) they're connected
-- to, and their own multiplier) -- it's their own rate, not another contractor's, so
-- there's no secrecy concern, and the app surfaces it as "Connected distributors" in
-- the Company tab.
create policy "Contractor can view own link"
  on public.distributor_links for select
  using (contractor_company_id = public.current_company_id());

create policy "Distributor manages own invites"
  on public.distributor_invites for all
  using (distributor_company_id = public.current_company_id())
  with check (distributor_company_id = public.current_company_id());
-- No policy for the redeeming contractor -- redemption happens entirely inside
-- handle_new_user() (SECURITY DEFINER), which bypasses RLS. A contractor never
-- queries distributor_invites directly.

-- The live-pricing mechanism. Selects a linked distributor's own custom_fixtures
-- rows, strips their private cost/vendorId (a distributor's own cost basis and PO
-- vendor are theirs alone -- never exposed to a contractor), and replaces price
-- (the distributor's sell price = the contractor's list price) with a computed
-- cost = price * multiplier. This view is owned by whichever role creates it (the
-- SQL Editor's `postgres` role), so its internal join can read across the
-- distributor's custom_fixtures rows despite that table's own
-- `company_id = current_company_id()` RLS policy -- the view's own
-- `where dl.contractor_company_id = current_company_id()` clause (current_company_id()
-- reflects the ACTUAL calling user's session regardless of the view's ownership) is
-- what performs the real per-caller filtering. A contractor querying custom_fixtures
-- directly is still fully blocked from ever seeing another company's rows -- only
-- this filtered, computed view is exposed to them.
create view public.contractor_catalog_view as
select
  cf.id,
  dl.distributor_company_id,
  c.name as distributor_name,
  (cf.data - 'cost' - 'vendorId') || jsonb_build_object(
    'cost', round(((cf.data->>'price')::numeric * dl.multiplier)::numeric, 2)
  ) as data
from public.custom_fixtures cf
join public.companies c on c.id = cf.company_id and c.account_type = 'distributor'
join public.distributor_links dl on dl.distributor_company_id = cf.company_id
where dl.contractor_company_id = public.current_company_id();

grant select on public.contractor_catalog_view to authenticated;

-- Supersedes the handle_new_user() defined near the top of this file. Same
-- access-code gate as before, but the single `access_code` signup field now has
-- three possible meanings, checked in this order: (1) an unredeemed distributor
-- invite code -> ordinary contractor account, auto-linked to that distributor at
-- the given multiplier; (2) the hardcoded distributor-provisioning code -> a
-- distributor account (handed manually to a paying distributor partner, same way
-- the beta code itself is shared); (3) the existing hardcoded beta code -> an
-- ordinary contractor account, unchanged from before. Anything else still rolls
-- back the whole signup atomically, exactly as before.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  new_company_id uuid;
  -- Strip anything outside printable ASCII (incl. plain spaces) before comparing --
  -- a copy-pasted code can pick up a stray invisible character (non-breaking space,
  -- zero-width space, smart-quote artifacts, etc.) that looks identical on screen but
  -- fails a byte-for-byte match. All real codes (generated invites and the hardcoded
  -- ones below) are plain ASCII with no whitespace, so this normalization is safe.
  v_code text := regexp_replace(coalesce(new.raw_user_meta_data->>'access_code',''), '[^\x21-\x7E]', '', 'g');
  v_invite record;
  -- Whether the select below actually found a row, captured via PL/pgSQL's FOUND right
  -- after it runs -- NOT `v_invite is not null`. A ROW/record's IS NULL / IS NOT NULL
  -- follows SQL's per-field semantics: true only if EVERY field is null (IS NULL) or
  -- EVERY field is non-null (IS NOT NULL). An unredeemed invite always has some non-null
  -- fields (code, multiplier, ...) and some null ones (redeemed_at, used_by_company_id),
  -- so `v_invite is not null` is FALSE even when a row was genuinely found -- this was a
  -- real bug here (confirmed live: a matching, unredeemed invite still fell through to
  -- "invalid access code" every time). FOUND doesn't have this problem.
  v_invite_found boolean;
  v_account_type text := 'contractor';
begin
  select * into v_invite from public.distributor_invites where code = v_code and redeemed_at is null;
  v_invite_found := found;

  if v_invite_found then
    v_account_type := 'contractor';
  elsif v_code = 'DUSKLINEDISTRIBUTORV1' then
    v_account_type := 'distributor';
  elsif v_code is distinct from 'DUSKLINEBETAV12026' then
    raise exception 'invalid access code';
  end if;

  insert into public.companies (name, account_type)
  values (coalesce(new.raw_user_meta_data->>'company_name', 'My Company'), v_account_type)
  returning id into new_company_id;

  insert into public.profiles (id, company_id, full_name, role)
  values (new.id, new_company_id, new.raw_user_meta_data->>'full_name', 'owner');

  -- Hide every BASE_FIXTURES starter/example fixture for a brand-new company (both
  -- account types) via the same fixture_overrides{hidden:true} mechanism a user would
  -- get by manually clicking "Remove from library" on each one -- restorable the same
  -- way too, from "Removed from your library" at the bottom of the Fixtures tab. Once
  -- distributor accounts exist, a fresh signup should only ever see fixtures it actually
  -- added itself or (for a contractor) a connected distributor's real catalog, not this
  -- app's generic example catalog. This ONLY runs at signup -- it does not touch any
  -- already-existing company's fixture library.
  -- NOTE: this id list must be kept in sync BY HAND with BASE_FIXTURES in index.html --
  -- there is no shared source of truth between the client array and this SQL trigger.
  insert into public.fixture_overrides (company_id, base_fixture_id, data)
  select new_company_id, id, jsonb_build_object('hidden', true)
  from unnest(array['f1','f2','f3','f4','f5','f6','f7','f8','f9','f10',
    'a1','a2','a3','a4','a5','a6','st1']) as id;

  if v_invite_found then
    insert into public.distributor_links (distributor_company_id, contractor_company_id, multiplier, label)
    values (v_invite.distributor_company_id, new_company_id, v_invite.multiplier, v_invite.label);
    update public.distributor_invites set redeemed_at = now(), used_by_company_id = new_company_id
      where code = v_code;
  end if;

  return new;
end;
$$;

-- ============================================================================
-- Distributor accounts follow-up: the Contractors screen's "Linked contractors"
-- list showed every contractor as "Unnamed contractor" -- the app's query embeds
-- the linked company's name via `companies!contractor_company_id(name)`, but
-- `companies` SELECT RLS only ever allowed a user to see their OWN company row
-- (`id = current_company_id()`), so that embedded join came back null for every
-- OTHER company regardless of the distributor_links relationship. Same "expose a
-- narrow, computed view instead of raw table access" pattern as
-- contractor_catalog_view above -- a distributor should see a linked contractor's
-- business name/phone/email/address (enough to know who they are and reach them),
-- not their tax rate, branding, or other account settings, so this is a purpose-
-- built view rather than a broader companies RLS policy.
alter table public.distributor_links add column label text not null default '';
-- label is the distributor's own chosen nickname for this contractor (separate from
-- the contractor's real business name below) -- seeded from the invite's own label
-- at redemption time (see handle_new_user() above), editable afterward from the
-- Contractors screen the same way the multiplier is.

create view public.distributor_contractor_view as
select
  dl.distributor_company_id,
  dl.contractor_company_id,
  dl.multiplier,
  dl.label,
  c.name as contractor_name,
  c.phone as contractor_phone,
  c.email as contractor_email,
  c.address as contractor_address
from public.distributor_links dl
join public.companies c on c.id = dl.contractor_company_id
where dl.distributor_company_id = public.current_company_id();

grant select on public.distributor_contractor_view to authenticated;

-- Same bug, other direction: a contractor's "Connected distributor catalogs" (Company
-- tab) tried to embed the distributor's name the same broken way -- fixed the same way.
create view public.contractor_distributor_view as
select
  dl.distributor_company_id,
  dl.contractor_company_id,
  dl.multiplier,
  c.name as distributor_name
from public.distributor_links dl
join public.companies c on c.id = dl.distributor_company_id
where dl.contractor_company_id = public.current_company_id();

grant select on public.contractor_distributor_view to authenticated;
