# Taking Duskline from a File to a Real Product

This is the honest version of "what it takes," not the marketing version. Duskline today is a genuinely capable tool — the gap between "a great single-file app" and "a hosted product with real accounts" is mostly about **plumbing**, not about the design work you've already done. The UI, the interaction model, the beam math, the quote logic — none of that has to be thrown away. What changes is where the data lives and how people get in.

---

## 1. What actually changes

Right now:
- Everything runs in one person's browser, in one HTML file.
- "Saving your work" means writing to that browser's local storage.
- "Logging in" is really just naming a local profile — it doesn't leave the device.
- Photos are embedded as base64 text directly inside your project data.

To become a real hosted product, four things need to exist that don't today:

| Piece | What it does | Why localStorage can't do it |
|---|---|---|
| **A server/backend** | Runs your logic outside the browser, talks to a database | Browsers can't securely hold shared, multi-user data |
| **A database** | Stores projects, fixtures, company info per account | localStorage is per-browser, per-device, and easily wiped |
| **Real authentication** | Verifies who someone is, keeps others out of their data | A typed name isn't a password; anyone could type someone else's |
| **File/photo storage** | Holds the actual uploaded images | Base64-in-JSON doesn't scale — it bloats storage and slows everything down |

Everything else — the design canvas, the drag-to-place fixtures, the beam rendering, the quote math, the PDF/JPG export — stays essentially as-is. That's the good news: the hardest, most bespoke part of this project is already built.

---

## 2. The architecture I'd recommend

For a tool like this — built by one person, used by a sales team or a handful of contractors, not a huge engineering org — I'd steer away from "build everything from scratch" and toward a **managed backend-as-a-service**. The two well-established options:

- **Supabase** — Postgres database + built-in auth + file storage + row-level security, all with a generous free tier. Popular specifically for "I have a client-side app and need to add a real backend without hiring a backend team."
- **Firebase** (Google) — similar idea, different database model (NoSQL instead of SQL).

I'd lean **Supabase** for this project specifically, because:
- A real relational database (Postgres) maps naturally onto your existing data shape (projects → areas → placements → fixtures) — this is exactly the kind of structured, relational data Postgres is good at.
- Its **row-level security** feature is the clean answer to "make sure Isaac can't see Mike's projects" — you write a rule once at the database level, not scattered through your app code.
- Its JS client library is simple enough that most of your existing app logic barely needs to change — you're mainly swapping `localStorage.setItem(...)` for `supabase.from('projects').upsert(...)`.

The alternative — a fully custom Node.js/Express server with your own Postgres database and hand-rolled authentication — gives you more control but means building and securing login, password resets, session handling, and file uploads yourself. That's real, non-trivial security surface area. I wouldn't recommend it as a first move unless you specifically want to learn backend development or later need something Supabase genuinely can't do.

**Important:** you do *not* need to rewrite the frontend in React or any framework to make this work. The app can stay close to its current vanilla JS structure — you're changing the *persistence layer*, not the UI.

---

## 3. Data model changes

A few real decisions to make before writing code:

**Multi-tenancy.** Right now "profiles" are just local names. In a real system, every project, fixture, and company-settings row needs to be tied to an actual authenticated `user_id` (or a `company_id`, if you want a whole sales team sharing one fixture library and company branding but keeping separate projects — worth deciding now, since it's much easier to build in from day one than retrofit later).

**Photos move out of the JSON.** Instead of embedding a giant base64 string inside a project record, you'd upload the photo to file storage (Supabase Storage, or an S3-compatible bucket) and store just a URL. This is a real but mechanical change — your crop tool still produces a JPEG blob, it just gets uploaded instead of stored inline.

**The rest of your schema translates almost directly**: projects, areas, placements, fixtures, company settings, quote line items — these already exist as clean, structured JS objects in your app. They map onto database tables with very little redesign.

---

## 4. Phased plan

I'd do this in stages, each one independently useful, so you're never stuck with something half-working:

**Phase 0 — Decide the shape of the product** (a day of thinking, not coding)
Is this just for you? For your whole team at Normac, sharing fixtures/branding? Are you ever going to charge other landscape lighting companies to use it? This changes the multi-tenancy design above, so it's worth answering first.

**Phase 1 — Auth + a bare database**
Set up Supabase, get real sign-up/login/logout working, create the core tables. At the end of this phase, people can create an account, but the app doesn't use the database for anything yet.

**Phase 2 — Migrate persistence**
Go through the app's state-saving logic and replace local storage calls with API calls to Supabase. This is the biggest single chunk of work, but it's mechanical rather than creative — same operations, different destination.

**Phase 3 — Move photos to real file storage**
Swap embedded base64 photos for uploaded files + URLs.

**Phase 4 — Deploy and get a domain**
Host the static frontend (Vercel, Netlify, or Cloudflare Pages are all simple, cheap, and pair well with Supabase) and point a real domain at it.

**Phase 5 — (Optional) Billing, if you ever plan to charge others**
Stripe is the standard choice here. Only worth building once you know you want this — don't build billing infrastructure speculatively.

**Phase 6 — Ongoing**
Backups, monitoring for errors, and periodically reviewing security (especially the row-level security rules — that's the thing standing between "each customer sees only their own data" and a very bad day).

---

## 5. Rough cost expectations

I'll give ranges, not promises — pricing changes, and you should check current numbers before committing:

- **Supabase**: free tier covers a solo user or small team comfortably to start; paid tiers begin roughly in the $25/month range once you outgrow the free limits (mainly database size and file storage volume).
- **Hosting the frontend** (Vercel/Netlify/Cloudflare Pages): free tier is generally sufficient for a tool like this.
- **Domain name**: roughly $12–20/year.
- **Stripe** (if/when you add billing): no monthly fee, just a per-transaction percentage.

Realistic starting point: **free to roughly $25–50/month** until you have meaningful usage, which is a very low bar to clear before deciding whether to pursue this seriously.

---

## 6. Security and data-handling basics

A few things to build in from the start, not bolt on later:

- **Row-level security** on every table, so one account's data is genuinely unreachable by another's — not just hidden by the UI.
- **Never store payment card details yourself** — if you add billing, Stripe handles that; you never touch raw card numbers.
- **Customer personal information** (names, phone numbers, addresses, emails already in your quote system) — worth being deliberate about who can access it and having a basic privacy policy once real customer data is involved, especially since you're in Canada (PIPEDA applies to that kind of business data, similar in spirit to GDPR).
- **Password reset and session handling** — this is exactly the class of problem managed auth (Supabase/Firebase Auth) exists to get right so you don't have to.

---

## 7. Who should actually build this

Three honest paths:

1. **You, with help.** Given how far this app has already come through iterative requests like this one, this is achievable — but this next phase (multi-file backend integration, environment variables, deployment) is a different *kind* of work than "describe a feature, get a file back." It benefits from a tool built for exactly that: **Claude Code**. It works directly in a real project folder across many files, runs your code, and iterates — much better suited to "wire up auth across twelve functions and three new API calls" than a single downloadable file ever was.
2. **Hire a freelance developer** for the backend migration specifically, using this document (and the existing app) as the spec. Realistically a well-scoped few-week engagement for someone experienced with Supabase or similar.
3. **A mix** — you drive product decisions and UI, someone else handles the backend wiring.

## 8. Realistic timeline

For one person doing this in spare time, learning the tools as they go: **realistically 3–6 weeks** of evenings/weekends to get Phases 1–4 solid. For an experienced web developer working on it full-time: **1–2 weeks**. Phase 5 (billing) and ongoing hardening are open-ended and only worth doing once you know you need them.

---

## Immediate next steps, concretely

1. Answer the Phase 0 question (solo tool vs. team tool vs. product-you-sell) — everything else follows from this.
2. Create a free Supabase project and get comfortable with its dashboard and JS client in isolation, before touching Duskline's code at all.
3. If you want help doing the actual migration, that's a strong candidate for a Claude Code session against a real project folder — a fundamentally better fit for this stage of work than continuing in this chat-based, single-file format.
