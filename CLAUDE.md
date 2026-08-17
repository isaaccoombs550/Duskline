# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Duskline is a client-side web app for landscape lighting contractors: design a lighting layout on top of a customer's photo (drag-and-place fixtures, aim beams, draw wire runs and LED strips) and generate a customer quote / PDF from the same data. There is no build system and no package manager — the UI is one file, `duskline-lighting-designer_21.html` (~3000 lines: inline `<style>`, inline `<script>`, no external JS files except CDN-loaded SheetJS and `@supabase/supabase-js`). It now has a real backend for authentication only (Supabase — see "Auth & backend" below); all other app data (projects, fixtures, company settings) is still local-only.

This directory **is now a git repository** (initialized as part of the backend migration below), but has no `package.json`, no test suite, and no linter configured. Treat every change as a direct edit to the one HTML file.

The two markdown files here (`duskline-going-live-roadmap.md`, `duskline-subscription-launch-plan.md`) are advisory planning documents (not app docs), written before any backend existed, describing a phased plan to move this from a local-only file to a hosted multi-user product on Supabase with Stripe billing eventually. **Phase 1 of that plan (real accounts) is now implemented** — see "Auth & backend (Supabase)" below. Phases 2+ (migrating projects/fixtures/company data into Postgres, real file storage for photos, billing) are still not implemented — project/fixture/company data still lives entirely in `localStorage`, just scoped to a real account now instead of a typed name.

## Backend migration progress

Tracking status against the phased plan in `duskline-going-live-roadmap.md`. Update this checklist whenever a phase's status changes — it's the fastest way for a future session to know where things stand without re-reading the whole roadmap doc or guessing from the code.

- [x] **Phase 0 — product shape decided**: multi-tenant SaaS (not just a solo or single-team tool). Every signup creates its own company/tenant; there's no invite-an-existing-company flow yet.
- [x] **Phase 1 — auth + bare database**: Supabase project created (`bolwcxusbfsizsjtulvr`, see `SUPABASE_URL` in the HTML file and `supabase/schema.sql` for the schema). Real sign-up/login/logout works end-to-end and has been manually tested (signup → company auto-created → account panel shows company+role → logout → login). The app does not yet read/write projects or fixtures from the database — see Phase 2.
- [ ] **Phase 2 — migrate persistence**: replace `localStorage` reads/writes for projects/areas/fixtures/company with Supabase queries against new tables, scoped by `company_id` using the same RLS pattern as `profiles`/`companies`. Not started.
- [ ] **Phase 3 — move photos to real file storage**: swap embedded base64 photos for Supabase Storage uploads + URLs. Not started.
- [ ] **Phase 4 — deploy + domain**: host the static file (Vercel/Netlify/Cloudflare Pages) and point a domain at it. Not started.
- [ ] **Phase 5 — billing (Stripe)**: only worth doing once there's real demand — see the subscription-launch-plan doc's "validate first" recommendation. Not started.
- [ ] **Phase 6 — ongoing hardening**: backups, error monitoring, periodic RLS review. Not started.

Other open items worth resolving before real customers sign up (not blocking further dev work):
- **Email confirmation** is currently OFF for this Supabase project (test signups return an active session immediately, no email-verification step) — fine for development, but decide deliberately before production.
- No invite flow exists for adding a second person to an existing company (every signup makes a new tenant) — needed once "team seats" matters.
- The repo has a git history question outstanding: `git init` has been run, but **nothing has been committed yet** — nothing gets committed without being asked first.

## Running / testing changes

There's no dev server or build step. To check a change:
1. Open `duskline-lighting-designer_21.html` directly in a browser (double-click, or serve the folder with any static file server).
2. Exercise the feature manually — there are no automated tests. Check both the "Customer" and "Internal" quote-mode tabs, light and dark theme, and (for anything touching layout/export) the print/export path via the "Print / Export project" button.
3. Data persists via `localStorage` under per-profile keys, now keyed by Supabase user id (`duskline_profile_<user-uuid>`) rather than a typed name — clearing site data / using a private window gives a clean slate for testing signup flows, but note it won't delete the account itself from Supabase (see below).
4. Sign-up/login now requires the Supabase project to be reachable (it's a real network call to `https://bolwcxusbfsizsjtulvr.supabase.co`) — this won't work fully offline. Test accounts created while testing should be cleaned up from **Supabase dashboard → Authentication → Users** (deleting a user cascades to their `profiles`/`companies` rows via `on delete cascade`).

## Architecture (single IIFE, no framework)

Everything lives inside one `(function(){ "use strict"; ... })()` in the trailing `<script>` block (starts ~line 815). There's no component framework, no virtual DOM, no bundler — UI updates happen via direct DOM manipulation (`document.getElementById`, aliased as `$()`) and manual `render*()` functions that rebuild `innerHTML` for a section when state changes. Keep this style consistent rather than introducing new patterns for isolated features.

### State shape

A single in-memory `state` object (declared ~line 840) holds everything:
- `state.projects[]` → each project has `areas[]`, plus customer info and quote settings. Each area has `photo`, `placements[]` (fixtures dropped on the photo), `lightStrips[]`, `wireRuns[]`, and lighting/brightness sliders.
- `state.customFixtures[]` / `state.fixtureOverrides{}` — user-added or user-edited fixtures, layered on top of the built-in `BASE_FIXTURES` catalog (~line 820) via `allFixtures()`.
- `state.company{}` — company branding + PDF/quote appearance settings (logo, accent color, tax rate, PDF section order).
- `state.activeProfile` — the signed-in Supabase user's id, used purely to pick which `localStorage` blob to load/save (see `saveProfile`/`loadProfile`, ~line 2464). It's a cache key, not itself an auth boundary — real auth now lives in Supabase (see below).

The whole `state` object is serialized to `localStorage` as one JSON blob per profile on every save — including base64-embedded photos. There's no incremental diffing; treat state mutation + a full `renderX()` re-render as the standard update pattern used throughout.

### Screens

Three top-level tabs (`switchTopScreen`, ~line 1614) — Projects, Fixtures, Company — plus two fullscreen overlay modes that aren't tabs: the **Area Editor** (`#editorScreen`, `openAreaEditor`/`closeAreaEditor` ~line 1792) where photo-based design happens, and the **Crop screen** (`#cropScreen`, `openCropScreen` ~line 1844) used after any photo upload/capture.

### Key subsystems (search these section-comment banners, e.g. `// ---------------- wire runs ----------------`, to navigate)

- **Canvas pan/zoom** (~line 894): desktop ctrl+scroll / pinch-to-zoom for precise fixture placement on the photo, independent of the CSS layout.
- **Beam rendering** (~line 938, `buildBeamHtml`): computes the on-screen gradient/cone HTML for each placed fixture's light beam from angle, reach, brightness, and Kelvin color temp (`kelvinColor`). This same math is duplicated in Canvas 2D form for export — see `drawBeamOnCanvas` (~line 2270) — because DOM-to-canvas libraries couldn't faithfully reproduce the CSS gradients (see comment at ~line 2239).
- **Wire runs & LED strips** (~lines 1017, 1039): freehand paths drawn on the photo, stored as point arrays, rendered as SVG overlays live and re-drawn onto canvas for export.
- **Drag/placement handlers** (~line 1192, `makeDraggable`; ~line 1216, `attachPlacementHandlers`): pointer-event-based dragging for moving fixtures, aiming beams (ring handle), and widening beams (square handle).
- **Quote math** (~line 1483): `computeAreaLineItems`/`computeProjectLineItems` roll up placements + strips + accessories into priced line items; toggled between "Customer" (sell price) and "Internal" (cost) modes.
- **Fixture library + Excel import** (~lines 1885–2119): SheetJS (`xlsx.full.min.js`, CDN) reads an uploaded spreadsheet; `findFixtureHeaderRow`/`parseFixtureRows` locate and parse fixture rows against a downloadable template (`downloadFixtureTemplate`).
- **PDF / export** (~line 2154): "PDF export" is actually the browser's native `window.print()` against a print stylesheet (`applyQuoteAppearance`, `applySectionOrder` reorder printed sections per company settings). A separate path, `exportAreaImagesOnly`/`captureAreaDesignImage` (~line 2354), renders a design (photo + beams + wires + strips) onto an offscreen `<canvas>` at higher resolution to produce a flat JPG when the user wants images without the quote table.

### Auth & backend (Supabase)

Real authentication was added on top of the otherwise-unchanged localStorage app (Phase 1 of the migration plan in the roadmap doc). Key pieces:

- **Client init** (~line 894): `sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY)`, loaded via the `@supabase/supabase-js@2` CDN script tag in `<head>`. The anon key is intentionally public — it's safe to be in client-side code because row-level security (RLS) is what actually restricts access, not the key itself. Never put the `service_role` key in this file.
- **Schema**: see `supabase/schema.sql` — the actual source of truth for the live schema (`companies`, `profiles`, RLS policies, the `handle_new_user` trigger), kept manually in sync since there's no migrations CLI wired up. RLS is scoped through a `security definer` helper function `current_company_id()` — **do not** write a `profiles` RLS policy as a raw subquery against `profiles` itself (e.g. `company_id in (select company_id from profiles where id = auth.uid())`); that causes Postgres error 42P17 "infinite recursion detected in policy," which is exactly what happened the first time this was built. Always route self-referencing lookups through the `security definer` function instead. If you change the schema, update `supabase/schema.sql` (and run the SQL yourself via the Supabase SQL Editor — there's no tool/CLI access to the database from this environment).
- **Signup auto-creates a tenant**: a Postgres trigger (`handle_new_user`, defined in Supabase) fires on every `auth.users` insert, reading `company_name`/`full_name` out of the signup call's `options.data` and creating one new `companies` row + one `profiles` row (`role: 'owner'`) per signup. There is currently no invite flow for adding a second person to an existing company — every signup is a brand-new tenant.
- **App-side auth flow** (~lines 2510–2660): `sb.auth.onAuthStateChange` (subscribed once in `init()`) is the single source of truth for entering/leaving the app — `enterAppForUser()` on a session, `leaveApp()` on none. Session persistence (surviving a page reload) is handled entirely by supabase-js itself via its own `localStorage` key; nothing in this app's code re-implements that. The `#accountModal` element is dual-purpose: it's the mandatory sign-in/sign-up gate when logged out (`.app` is hidden via the `auth-hidden` CSS class until a session exists — see `setAppVisible`), and becomes an account-info/log-out panel when logged in — `openAccountModal()` branches on whether `authUser` is set.
- **Not yet done**: projects/fixtures/company data still isn't in Postgres at all — only accounts are real. Don't assume a `projects` or `fixtures` table exists in Supabase; check the actual schema (ask the user, or query it) before writing code that references one.

### Editing conventions specific to this file

- New UI elements are added as plain HTML in the relevant screen's markup block (search the `<!-- ===== SECTION ===== -->` banner comments in the body, ~lines 388–814), then wired up with `addEventListener` calls inside `init()` (~line 2629, the largest function in the file).
- Fixture/accessory/strip categories are distinguished by `cat: 'fixture' | 'accessory' | 'strip'` throughout — filtering and rendering logic branches on this field repeatedly (sheet lists, quote line items, import parsing).
- Money values are always formatted through the `money()` helper (~line 873); don't hand-roll currency formatting.
- Because state is one big object persisted verbatim to `localStorage`, adding a new field to a project/area/fixture should include a sensible default read (`x.newField || default`) at each read site, since existing saved profiles won't have it — there's no migration step.
