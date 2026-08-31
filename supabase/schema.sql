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

alter table public.projects enable row level security;
alter table public.areas enable row level security;
alter table public.custom_fixtures enable row level security;
alter table public.fixture_overrides enable row level security;

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
