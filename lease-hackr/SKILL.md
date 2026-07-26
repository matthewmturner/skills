---
name: lease-hackr
description: Query the LeaseHackr forum (forum.leasehackr.com, public Discourse JSON API) for current car lease deals by vehicle class and location — prioritizing community-signed deals (real transacted prices) over broker/marketplace ads, including nationwide offers that ship to the region — and render a markdown report ranked by savings. Use when the user asks to find, compare, or report on car lease deals, lease specials, or broker lease offers for a vehicle type in a region.
---

# LeaseHackr Deal Report

Fetches lease-deal topics from LeaseHackr's public Discourse JSON API (no auth),
filtered by vehicle class (e.g. "luxury suv") and location (e.g. "new jersey"),
then renders a markdown report separating **community-signed deals** (real,
reported by members) from **broker/marketplace offers** (paid advertisements).
Signed deals are the priority throughout: they are actual transacted prices
and the benchmark broker quotes should be judged against, so they lead the
report, the takeaways, and the analysis effort. Offers that ship nationwide
are included by default and marked as such — many brokers deliver anywhere.

## Prerequisites

- `curl` and `jq` (check with `command -v curl jq`)
- `minijinja-cli` for report rendering (install: `cargo install minijinja-cli`)
- Network access to forum.leasehackr.com. No API key, no env vars.

## Usage

```
scripts/fetch-deals.sh -c <class> -l <location> [options]
```

| Flag | Meaning | Default |
|------|---------|---------|
| `-c CLASS` | Class key from `data/mappings.json` (e.g. `"luxury suv"`) | required |
| `-l LOCATION` | Location key (e.g. `"new jersey"`, `"socal"`, `"tri-state"`) | required |
| `--category T` | `signed` \| `marketplace` \| `both` | `both` |
| `--days N` | Recency window (signed filtered on `created_at`, marketplace on `bumped_at` — broker megathreads live for years; a recent bump means live offers) | 30 |
| `--max N` | Max topics per section | 20 |
| `--pages N` | Max pages per tag query (30 topics/page) | 4 |
| `--details N` | Fetch first-post text excerpt for top N topics per section (capped at 10) | 0 |
| `--hot N` | Fetch the 3 most recent posts of the top N marketplace topics, attached as `recent_posts` (capped at 15) — where brokers announce one-off limited specials | 0 |
| `--local-only` | Skip the `usa-nationwide` query — only topics tagged with the location itself | off |
| `--list` | Print available classes and locations, exit | |
| `--raw` | Dump raw matched topics as NDJSON, exit (debugging) | |

Output is one JSON doc: `{ query, signed: [...], marketplace: [...] }`. Each
topic has `id, title, slug, url, brand, tags, created_at, bumped_at,
posts_count, views, like_count, gist, availability, ships` and (with
`--details`) `first_post_excerpt`. `availability` is `local` (tagged with the
requested location), `nationwide` (tagged `usa-nationwide`), or `ships`
(carries the `shipping` tag). Topics tagged `EXPIRED` are dropped.

## Workflow

1. **Resolve inputs.** Map the user's phrasing to a class and location key.
   Run `scripts/fetch-deals.sh --list` if unsure. "Luxury" classes filter to a
   luxury-brand set client-side (the forum's `luxury` tag is too sparse).
2. **Fetch.** For a report, always use details and hot:
   `scripts/fetch-deals.sh -c "luxury suv" -l "new jersey" --days 30 --details 6 --hot 8`
   (use `--details 0 --hot 0` only for a quick count/scan). Expect ~1s per API
   request; a full run takes 1–3 minutes.
3. **Backfill signed deals if thin.** Signed deals are the priority; a report
   with 0–4 of them is a weak benchmark. When the signed section comes back
   with fewer than 5 topics, run a second pass with a wider window and merge:
   `scripts/fetch-deals.sh -c ... -l ... --category signed --days 90 --details 10`
   Keep the marketplace section at the original window (stale ads mislead;
   older signed deals are still useful reference points — note their age).
4. **Extract deal terms** per topic from `title`, `gist`, and
   `first_post_excerpt`: monthly payment (`$N/mo`), DAS/down/drive-off,
   term/mileage (`36/10k`), MSRP, money factor (`MF .00xxx`), residual %,
   % off MSRP, broker fee. Use `—` when a value is absent. Never invent
   numbers.
5. **Score and rank by savings.** For every deal with published numbers:
   - **Effective monthly** = (monthly × term + due-at-signing + broker/acq
     fees) ÷ term — folds DAS into the payment so a "$0 down" and a "$3k
     down" deal compare fairly. Exclude MSDs (refundable deposits).
   - **Leasehackr Score** — the community's native metric: the number of
     years of effective payments it would take to equal the sticker price.
     Official formula (per LeaseHackr's co-founder,
     https://forum.leasehackr.com/t/leasehackr-score-question/394887):
     `Score = (MSRP × (1 + tax rate)) ÷ (Total Lease Cost ÷ months) ÷ 12`
     where Total Lease Cost = payment incl. tax × (months − 1) + drive-off
     + disposition fee − rebates − gov fees. In practice this reduces to
     `Score = MSRP ÷ (12 × effective monthly)` when payment and MSRP are
     both pre-tax. When the advertised payment *includes* tax, gross MSRP
     up by the stated tax rate first; if the rate isn't stated, skip the
     gross-up and label the score "conservative". Higher is better —
     observed range ~5–20 yrs; community rule of thumb: ~8+ solid,
     10+ excellent, below ~6 weak (leasing that car is questionable).
   - Signed-deal posts usually link a Leasehackr Calculator page showing
     the official score — read it from the post when visible rather than
     recomputing.
   - If a deal's MSRP isn't posted but the identical model/trim/year has a
     published MSRP elsewhere in the same report, that may be used as a
     reference — prefix the score with `≈` and note the source.
   Rank each section by LH Score (highest first); deals with a payment but
   no computable score rank next by effective monthly; deals with no
   numbers or stale price signals (e.g. an excerpt dated a year ago) get
   rank `—` and sort last. Don't mix tax-inclusive and pre-tax numbers
   silently — note "+ tax" / "incl. tax" in the eff-monthly cell.
6. **Spot limited & high-demand offers.** Scan each marketplace topic's
   `recent_posts` (plus `title`/`first_post_excerpt`) for one-off specials
   with explicit scarcity or urgency language: "today only", "1 left" /
   "only N units", "will go quick / fast", "firesale", "blowout",
   "expires <date>", "last one", "price drop", "few remaining",
   "first come first served". Rules:
   - Require an explicit quantity or time limit — every ad says "great
     deal"; that alone does not qualify.
   - Only include posts from roughly the last 10 days (`created_at` on the
     post) — an expired flash deal is worse than none.
   - Quote the broker's own urgency phrase verbatim in the report; extract
     the vehicle and terms from the same post, `—` when absent.
7. **Determine availability** for each marketplace offer: start from the
   script's `availability` field, then refine from the excerpt — shipping
   language ("we ship", "delivery available", state coverage lists, delivery
   fee quotes) upgrades a `nationwide` offer to a confident "ships to
   <region>". Display strings like `Local (NJ)`, `Nationwide — ships`,
   `Ships to NJ (per post)`.
8. **Assemble render data** as JSON in a scratch file (arrays pre-sorted by
   rank). The `vehicle` and `offer` strings become the hyperlink text for
   `url` in the rendered tables — keep them concise and free of `|` and `[]`
   characters:

   ```json
   {
     "class_display": "Luxury SUV", "location_display": "New Jersey",
     "days": 30, "generated_at": "2026-07-24", "has_results": true,
     "signed_days": 90,
     "signed": [ {"rank": 1, "vehicle": "...", "terms": "...",
                  "eff_monthly": "$276 incl. tax", "lh_score": "16.7 yrs",
                  "date": "YYYY-MM-DD", "url": "..."} ],
     "marketplace": [ {"rank": "—", "offer": "...", "signals": "...",
                       "eff_monthly": "—", "lh_score": "—",
                       "availability": "...", "updated": "YYYY-MM-DD",
                       "url": "..."} ],
     "hot_offers": [ {"offer": "...", "terms": "...", "lh_score": "10.3 yrs",
                      "urgency": "broker's verbatim scarcity phrase",
                      "posted": "YYYY-MM-DD", "availability": "...",
                      "url": "..."} ],
     "highlights": ["one-line market observations"]
   }
   ```

   Include `signed_days` only when the backfill widened the signed window
   (it switches the header to show both windows).
   Keep `signed` and `marketplace` strictly separate — real deals vs ads.
   `highlights` must lead with the best signed deal(s) as the benchmark,
   then the best broker offers measured against it.
   Omit `hot_offers` (or leave it empty) when nothing qualifies — the
   section only renders when present.
9. **Render** with the template next to this SKILL.md — do not hand-write the
   report: `minijinja-cli template.j2 /path/to/data.json`
10. **Present**, and offer to drill into a specific thread:
   `curl -s -H 'User-Agent: lease-hackr-skill/1.0' https://forum.leasehackr.com/t/<id>.json | jq -r '.post_stream.posts[0].cooked'`

## Edge cases & notes

- **Unknown class/location:** the script exits 1 and prints the valid keys —
  relay the closest options to the user, or add a new entry to
  `data/mappings.json` for a genuinely missing region/class.
- **Zero results:** widen `--days` (60/90), fall back from `luxury suv` to
  `suv`, or retry with `-l nationwide`.
- **Rate limiting:** the script sleeps 1s between requests and backs off on
  HTTP 429 automatically. If a run still fails, wait a minute and retry —
  don't tighten the sleeps. Keep `--pages`/`--details` modest; this is a
  community forum, not an API product.
- **Category IDs drift:** signed = category 6, marketplace = 7 + regional
  subcategories 14–18. If sections come back empty despite raw matches,
  re-verify with `curl -s https://forum.leasehackr.com/site.json | jq
  '.categories[] | {id, slug, parent_category_id}'` and update
  `data/mappings.json`.
- **Advertised prices** usually exclude tax/fees and may require specific
  qualifications (loyalty/conquest, tier-1 credit) — surface this in
  Takeaways when the excerpts show it.
- This skill only reads public forum data — it never posts, messages, or
  authenticates.
