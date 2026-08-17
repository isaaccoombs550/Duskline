# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Duskline is a client-side web app for landscape lighting contractors: design a lighting layout on top of a customer's photo (drag-and-place fixtures, aim beams, draw wire runs and LED strips) and generate a customer quote / PDF from the same data. There is no build system and no package manager — the UI is one file, `duskline-lighting-designer_21.html` (~3200 lines: inline `<style>`, inline `<script>`, no external JS files except CDN-loaded SheetJS and `@supabase/supabase-js`). It has a real Supabase backend for both authentication and app data now (see "Auth & backend" below) — `localStorage` is no longer used for projects/fixtures/company data, only for small UI prefs (theme).

This directory **is now a git repository** (initialized as part of the backend migration below), but has no `package.json`, no test suite, and no linter configured. Treat every change as a direct edit to the one HTML file.

The two markdown files here (`duskline-going-live-roadmap.md`, `duskline-subscription-launch-plan.md`) are advisory planning documents (not app docs), written before any backend existed, describing a phased plan to move this from a local-only file to a hosted multi-user product on Supabase with Stripe billing eventually. **Phases 1 and 2 of that plan (real accounts, and projects/fixtures/company data in Postgres) are now implemented** — see "Auth & backend (Supabase)" below. Phases 3+ (real file storage for photos, deploy/domain, billing) are still not implemented.

## Backend migration progress

Tracking status against the phased plan in `duskline-going-live-roadmap.md`. Update this checklist whenever a phase's status changes — it's the fastest way for a future session to know where things stand without re-reading the whole roadmap doc or guessing from the code.

- [x] **Phase 0 — product shape decided**: multi-tenant SaaS (not just a solo or single-team tool). Every signup creates its own company/tenant; there's no invite-an-existing-company flow yet.
- [x] **Phase 1 — auth + bare database**: Supabase project created (`bolwcxusbfsizsjtulvr`, see `SUPABASE_URL` in the HTML file and `supabase/schema.sql` for the schema). Real sign-up/login/logout works end-to-end, manually tested (signup → company auto-created → account panel shows company+role → logout → login). Committed as `c0164d5`.
- [x] **Phase 2 — migrate persistence**: `projects`, `areas`, `custom_fixtures`, `fixture_overrides` tables added, plus branding/quote-appearance columns on `companies` (all in `supabase/schema.sql`). The app reads/writes these instead of the Phase-1 localStorage blob — see "Auth & backend (Supabase)" below for how loads/saves are scoped. Manually tested end-to-end: create project → add area → increment an accessory quantity → close editor → log out → log back in → project/area/accessory data all reload correctly from Postgres (confirmed both via the UI and by querying the REST API directly). Not yet committed to git.
- [ ] **Phase 3 — move photos to real file storage**: swap embedded base64 photos (still inline in the `areas.photo` column) for Supabase Storage uploads + URLs. Not started.
- [ ] **Phase 4 — deploy + domain**: host the static file (Vercel/Netlify/Cloudflare Pages) and point a domain at it. Not started.
- [ ] **Phase 5 — billing (Stripe)**: only worth doing once there's real demand — see the subscription-launch-plan doc's "validate first" recommendation. Not started.
- [ ] **Phase 6 — ongoing hardening**: backups, error monitoring, periodic RLS review. Not started.

Other open items worth resolving before real customers sign up (not blocking further dev work):
- **Email confirmation** is currently OFF for this Supabase project (test signups return an active session immediately, no email-verification step) — fine for development, but decide deliberately before production.
- No invite flow exists for adding a second person to an existing company (every signup makes a new tenant) — needed once "team seats" matters.
- **Async saves can lose the last few seconds of an edit on tab close.** Phase 1's `beforeunload`/`pagehide` saves were synchronous `localStorage` writes, so they always completed. Phase 2's saves are network calls, which aren't guaranteed to finish before the page actually unloads. The 5s autosave tick plus explicit flushes when navigating away (closing the area editor, switching projects, logging out) keep the window small, but closing the tab within ~5s of an edit and before navigating away can still lose that edit. Worth a `sendBeacon`-based fix if it turns out to matter in practice; not done.
- The repo has commits pending: Phase 2's code/schema/doc changes are not committed yet — nothing gets committed without being asked first.

## Running / testing changes

There's no dev server or build step. To check a change:
1. Open `duskline-lighting-designer_21.html` directly in a browser (double-click, or serve the folder with any static file server).
2. Exercise the feature manually — there are no automated tests. Check both the "Customer" and "Internal" quote-mode tabs, light and dark theme, and (for anything touching layout/export) the print/export path via the "Print / Export project" button.
3. All app data now lives in Supabase, not `localStorage` — clearing site data / using a private window no longer gives a clean slate for a given account, since a login re-fetches everything from Postgres regardless of what's in the browser. To test "fresh account" flows, sign up a new test account instead.
4. The whole app requires the Supabase project to be reachable (real network calls to `https://bolwcxusbfsizsjtulvr.supabase.co` for both auth and data) — nothing works offline anymore, including opening a project you already created. Test accounts/projects created while testing should be cleaned up from the **Supabase dashboard → Authentication → Users** (deleting a user cascades to `profiles` → their `companies` row isn't auto-deleted by that cascade, since `companies` doesn't reference `auth.users` — delete stray `companies`/`projects` rows manually via **Table Editor** if you want a fully clean slate, or just leave them, since RLS means no other account can ever see them).

## Architecture (single IIFE, no framework)

Everything lives inside one `(function(){ "use strict"; ... })()` in the trailing `<script>` block (starts ~line 815). There's no component framework, no virtual DOM, no bundler — UI updates happen via direct DOM manipulation (`document.getElementById`, aliased as `$()`) and manual `render*()` functions that rebuild `innerHTML` for a section when state changes. Keep this style consistent rather than introducing new patterns for isolated features.

### State shape

A single in-memory `state` object (declared ~line 840) holds everything:
- `state.projects[]` → each project has `areas[]`, plus customer info and quote settings. Each area has `photo`, `placements[]` (fixtures dropped on the photo), `lightStrips[]`, `wireRuns[]`, and lighting/brightness sliders.
- `state.customFixtures[]` / `state.fixtureOverrides{}` — user-added or user-edited fixtures, layered on top of the built-in `BASE_FIXTURES` catalog (~line 820) via `allFixtures()`.
- `state.company{}` — company branding + PDF/quote appearance settings (logo, accent color, tax rate, PDF section order).
- `state.activeProfile` — the signed-in Supabase user's id. Now mostly vestigial (it predates Phase 2's real data layer) — truthy-checked in a couple of places as a loose "is someone logged in" signal, but `authUser` (see below) is the actual source of truth for that.

`state` itself still gets mutated in place and re-rendered via `renderX()` functions exactly as before Phase 2 — that part of the architecture didn't change. What changed is where mutations get *persisted*: instead of one `localStorage.setItem` of the whole object, saves now go to Supabase, scoped to just the company/project/area actually being edited (see "Auth & backend" below for why, and for the load/save functions).

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

- **Client init** (~line 894): `sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY)`, loaded via the `@supabase/supabase-js@2` CDN script tag in `<head>`. The anon key is intentionally public — it's safe to be in client-side code because row-level security (RLS) is what actually restricts access, not the key itself. Never put the `service_role` key in this file.
- **Schema**: see `supabase/schema.sql` — the actual source of truth for the live schema (`companies`, `profiles`, `projects`, `areas`, `custom_fixtures`, `fixture_overrides`, all RLS policies, the `handle_new_user` trigger), kept manually in sync since there's no migrations CLI wired up. If you change the schema, update `supabase/schema.sql` in the same session (and run the SQL yourself via the Supabase SQL Editor — there's no tool/CLI access to the database from this environment).
- RLS is scoped through a `security definer` helper function `current_company_id()`. **Do not** write a `profiles` RLS policy as a raw subquery against `profiles` itself (e.g. `company_id in (select company_id from profiles where id = auth.uid())`); that causes Postgres error 42P17 "infinite recursion detected in policy," which is exactly what happened the first time this was built. Always route self-referencing lookups through the `security definer` function instead.
- **Signup auto-creates a tenant**: a Postgres trigger (`handle_new_user`, defined in Supabase) fires on every `auth.users` insert, reading `company_name`/`full_name` out of the signup call's `options.data` and creating one new `companies` row + one `profiles` row (`role: 'owner'`) per signup. There is currently no invite flow for adding a second person to an existing company — every signup is a brand-new tenant.
- **App-side auth flow** (~lines 2690–2740): `sb.auth.onAuthStateChange` (subscribed once in `init()`) is the single source of truth for entering/leaving the app — `enterAppForUser()` on a session, `leaveApp()` on none. Session persistence (surviving a page reload) is handled entirely by supabase-js itself via its own `localStorage` key; nothing in this app's code re-implements that. The `#accountModal` element is dual-purpose: it's the mandatory sign-in/sign-up gate when logged out (`.app` is hidden via the `auth-hidden` CSS class until a session exists — see `setAppVisible`), and becomes an account-info/log-out panel when logged in — `openAccountModal()` branches on whether `authUser` is set.

**Data sync** (~lines 2536–2635, section banner `// ---------------- data sync (Supabase) ----------------`) is where projects/areas/company/fixtures actually move between `state` and Postgres. The load side and the save side are deliberately asymmetric:

- **Loading is eager**: `loadCompanyDataFromDb(companyId)`, called once from `enterAppForUser`, fetches the company row, *all* projects, *all* areas (via RLS alone — no explicit filter needed, since the `areas` RLS policy already scopes it), and the whole fixture library, then populates `state` in one shot — mirroring exactly what the old localStorage blob used to hand back. This is intentionally not optimized (e.g. not lazy-loading areas per-project) — Phase 3 (moving photos out of the JSON) is where that would actually start to matter; doing it now would be solving a Phase 3 problem inside Phase 2.
- **Saving is scoped, not eager.** This is the important part, and it's not just a performance choice — see the migration-progress note above about why a single whole-account blob write isn't safe once more than one person can be editing a company's data at once. `flushCurrentEdits()` only ever writes the company row plus whichever project/area `currentProject()`/`currentArea()` currently point to — never the rest of `state.projects`. It runs on a 5s `setInterval`, on `beforeunload`/`pagehide`, and is explicitly called before anything that would change what "current" means: `closeAreaEditor()`, and `openProjectDetail()` (flushing the *previous* project before switching `state.currentProjectId`). **If you add a new screen or navigation path that changes `currentProjectId`/`currentAreaId`, add a `flushCurrentEdits()` call before that reassignment**, the same way `openProjectDetail` does — otherwise pending edits to whatever was open before can be silently dropped once "current" points elsewhere.
- **Discrete create/delete/explicit-save actions bypass the scoped-save mechanism entirely and write immediately**: new project (`customerSave`), new area (`areaNameCreate`), project delete, area delete, and fixture add/edit/delete/import all do their own direct `sb.from(...).insert/update/delete(...)` call right at the point of the user's click — these don't wait for the tick since they're one-off actions, not continuous edits like dragging a fixture or typing in a field.
- **Row \<-> `state` shape mapping** (`companyToRow`/`rowToCompany`, `projectToRow`/`rowToProject`, `areaToRow`/`rowToArea`) converts between Postgres's snake_case columns and the app's existing camelCase in-memory shape. If you add a field to `state.company`/a project/an area, it needs a matching column in `supabase/schema.sql` *and* both directions of the corresponding mapper function, or it'll silently fail to persist.

### Editing conventions specific to this file

- New UI elements are added as plain HTML in the relevant screen's markup block (search the `<!-- ===== SECTION ===== -->` banner comments in the body, ~lines 388–814), then wired up with `addEventListener` calls inside `init()` (~line 2741, the largest function in the file).
- Fixture/accessory/strip categories are distinguished by `cat: 'fixture' | 'accessory' | 'strip'` throughout — filtering and rendering logic branches on this field repeatedly (sheet lists, quote line items, import parsing).
- Money values are always formatted through the `money()` helper (~line 873); don't hand-roll currency formatting.
- Adding a new field to a project/area/company/fixture now touches three places, not one: a column in `supabase/schema.sql` (run via SQL Editor), both directions of the relevant `rowTo*`/`*ToRow` mapper function, and a sensible default read (`x.newField || default`) at call sites — existing rows in the database won't have the new column backfilled, and there's no migration runner to do it for you.
