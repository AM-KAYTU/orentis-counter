# Shop Counter — putting it online

**Steps 1 to 4 below are already done.** Your project `orentis-shop` exists in
Europe, the schema and your data are in it, both logins are created, and your
account is the owner. The copy of the app in `Downloads\orentis-counter\` has
your project's URL and key already in it. The only step left is 5, hosting.
The rest of this file is kept as a record of what was done and how to redo it.

| File | What it is |
|---|---|
| `schema.sql` | The tables, the login roles, and the rules that keep cost prices away from the counter. Run once. |
| `seed.sql` | Your real data as it stands today — 109 items, 6 sales, 2 repairs, the Samsung deal, the three supplier tranches. Run once, after the schema. Safe to run again. |
| `app.html` | The whole app. One file, no build step. |
| `README.md` | This. |

---

## 1. Make the project

1. Go to supabase.com, sign in, **New project**.
2. Name it `shop`, choose a region close to Ghana (**West EU (London)** is the
   nearest fast one), and set a database password. Write that password down
   somewhere safe — it is not the password you will log into the shop with.
3. Wait for it to finish setting up, about two minutes.

## 2. Create the tables

1. Open **SQL Editor** in the left sidebar.
2. Paste the whole of `schema.sql`, click **Run**. It should say "Success".
3. New query. Paste the whole of `seed.sql`, click **Run**.

To check it took: **Table Editor → items** should show 109 rows.

## 3. Create the two logins

Still in Supabase, **Authentication → Users → Add user → Create new user**.
Tick *Auto Confirm User* both times, so neither account needs an email link.

- Yours: your email, and a password only you know.
- The shop's: something like `counter@yourshop.com` with a password you are
  happy for the attendant to have. It does not have to be a real mailbox.

Both accounts start as attendants. Promote yourself — **SQL Editor**, new
query:

```sql
update public.profiles set role = 'owner'
where id = (select id from auth.users where email = 'YOUR-EMAIL-HERE');
```

Run it, then check:

```sql
select u.email, p.role from public.profiles p join auth.users u on u.id = p.id;
```

You want to see exactly one `owner` — you — and one `attendant`. If both say
attendant, the update did not match your email; check the spelling.

## 4. Point the app at your project

In Supabase, **Project Settings → API**. You need two values:

- **Project URL** — looks like `https://abcdefgh.supabase.co`
- **anon public** key — a long string starting `eyJ…`

Open `app.html` in any text editor. The top of the file has:

```js
window.SHOP_CONFIG = {
    url: "YOUR_SUPABASE_URL",
    anonKey: "YOUR_SUPABASE_ANON_KEY"
};
```

Replace the two placeholders, keeping the quotes. Save.

The anon key is meant to be public — it is in every visitor's browser by
design. What protects your cost prices is the rules in `schema.sql`, not
secrecy about that key. The **service_role** key on that same page is the
dangerous one: never put it in the app or send it to anyone.

## 5. Put it online

`app.html` is a single file with no server behind it, so anywhere that hosts a
web page will do. Easiest:

- **Netlify Drop** — netlify.com/drop, drag `app.html` onto the page, done.
  You get a link immediately. Rename the file `index.html` first so the link
  is clean.
- **Cloudflare Pages** or **Vercel** work the same way if you prefer them.

Then open the link on your phone and on the shop's phone, and use *Add to
Home Screen* on both so it opens like an app.

---

## What each person sees

**You, signed in as owner** — all seven tabs. Cost, profit, capital, the
supplier schedule, floor prices, the CSV export.

**The attendant** — five tabs: Sell, Sales, Repairs, Owed, People. No Money
tab, no Stock tab. On the Sell screen each item shows only its floor price,
which is the lowest he may sell it for.

That split is enforced by the database, not by hiding buttons. If he opened
the browser console and asked for cost prices directly, he would get nothing
back: the counter reads a view that has no cost column in it, and the
`items`, `deals`, `expenses` and `tranches` tables return zero rows to him.
He can still take a hire purchase instalment, because that goes through a
function that updates the deal without ever showing him what the phone cost
you.

Both accounts see the same sales, repairs and customers, instantly-ish — the
app refetches every twenty seconds, so a sale made on the shop phone shows up
on yours within about that long.

## Day to day

- **Adding stock** — Stock tab, as now. Cost and floor price are yours to set.
- **A new attendant** — add a user in Supabase, give them the password. Do not
  promote them.
- **Someone leaves** — Authentication → Users → delete that user, or just
  change the password. Their access stops at once.
- **Backup** — Supabase keeps daily backups on the free plan. The CSV export
  on your Sales tab is a second copy worth taking now and then.
- **Free plan limits** — a shop your size will not come close. The one thing
  to watch: a project with no activity for a week gets paused, and you wake
  it from the dashboard. Daily use prevents that.

## If something looks wrong

- **"Could not load: …"** across the top — the app could not read something.
  Usually the URL or anon key is mistyped; check step 4.
- **The attendant sees no items** — check `profiles`: if nobody is `owner`,
  or his row is missing, run the promotion query again.
- **Sign-in says email not confirmed** — the user was created without *Auto
  Confirm*. Delete and recreate with it ticked.

---

## What was tested, and what was not

Proven against a real Postgres 16 with the policies applied: an attendant
sees 0 rows in `items`, `deals`, `expenses` and `tranches`; `items_counter`
has no cost column at all; he can record a sale and take an instalment (the
function returned the correct ₵1,200 balance) but cannot change a floor
price or add a running cost. Proven in a browser, both roles: the login gate
holds until signed in, the saved session reopens the app without a second
login, all 109 items arrive and render, a sale writes the right columns, an
instalment goes through the database function, a refused read is reported on
screen instead of leaving the app blank, and no cost or profit wording
appears anywhere on the attendant's screen.

Not yet tested, because it needs your project: the real Supabase login, and
the migration running against the live database. That is step 2 and step 3,
and the first thing to check after them is the 109 rows in the Table Editor.
