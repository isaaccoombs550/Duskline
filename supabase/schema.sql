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
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  new_company_id uuid;
begin
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
