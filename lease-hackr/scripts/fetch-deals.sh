#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAPPINGS="$SCRIPT_DIR/../data/mappings.json"
BASE_URL="https://forum.leasehackr.com"
UA="lease-hackr-skill/1.0 (personal research; Claude Code skill)"

CLASS=""
LOCATION=""
CATEGORY="both"
DAYS=30
MAX=20
PAGES=4
DETAILS=0
HOT=0
LOCAL_ONLY=0
RAW=0

usage() {
  cat <<'EOF'
Usage: fetch-deals.sh -c <class> -l <location> [options]

Query the LeaseHackr forum (Discourse JSON API) for lease deal topics
matching a vehicle class and location.

Required:
  -c CLASS         Vehicle class key from data/mappings.json (e.g. "luxury suv")
  -l LOCATION      Location key (e.g. "new jersey", "socal")

Options:
  --category T     signed | marketplace | both        (default: both)
  --days N         Recency window in days             (default: 30)
  --max N          Max topics kept per section        (default: 20)
  --pages N        Max pages per tag query, 30/page   (default: 4)
  --details N      Also fetch the first post of the top N topics per
                   section and attach a text excerpt  (default: 0, max 10)
  --hot N          Also fetch the 3 most recent posts of the top N
                   marketplace topics (where brokers post one-off
                   limited/high-demand specials)      (default: 0, max 15)
  --local-only     Skip the usa-nationwide query; only topics tagged
                   with the location itself
  --list           Print available classes and locations, then exit
  --raw            Dump raw matched topics as NDJSON and exit
  -h, --help       Show this help

Output: one JSON document on stdout:
  { "query": {...}, "signed": [...], "marketplace": [...] }
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CLASS="${2:?-c requires a value}"; shift 2 ;;
    -l) LOCATION="${2:?-l requires a value}"; shift 2 ;;
    --category) CATEGORY="${2:?--category requires a value}"; shift 2 ;;
    --days) DAYS="${2:?--days requires a value}"; shift 2 ;;
    --max) MAX="${2:?--max requires a value}"; shift 2 ;;
    --pages) PAGES="${2:?--pages requires a value}"; shift 2 ;;
    --details) DETAILS="${2:?--details requires a value}"; shift 2 ;;
    --hot) HOT="${2:?--hot requires a value}"; shift 2 ;;
    --local-only) LOCAL_ONLY=1; shift ;;
    --list)
      echo "Classes:"
      jq -r '.classes | keys[] | "  " + .' "$MAPPINGS"
      echo "Locations:"
      jq -r '.locations | keys[] | "  " + .' "$MAPPINGS"
      exit 0 ;;
    --raw) RAW=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[[ -f "$MAPPINGS" ]] || die "mappings file not found: $MAPPINGS"
command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"
[[ -n "$CLASS" && -n "$LOCATION" ]] || { usage >&2; die "-c and -l are required"; }
[[ "$CATEGORY" =~ ^(signed|marketplace|both)$ ]] || die "--category must be signed, marketplace, or both"
(( DETAILS > 10 )) && DETAILS=10
(( HOT > 15 )) && HOT=15

CLASS="$(echo "$CLASS" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//;s/ *$//')"
LOCATION="$(echo "$LOCATION" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//;s/ *$//')"

CLASS_JSON="$(jq -c --arg k "$CLASS" '.classes[$k] // empty' "$MAPPINGS")"
if [[ -z "$CLASS_JSON" ]]; then
  { echo "Error: unknown class '$CLASS'. Available classes:"
    jq -r '.classes | keys[] | "  " + .' "$MAPPINGS"; } >&2
  exit 1
fi
LOC_TAGS_JSON="$(jq -c --arg k "$LOCATION" '.locations[$k] // empty' "$MAPPINGS")"
if [[ -z "$LOC_TAGS_JSON" ]]; then
  { echo "Error: unknown location '$LOCATION'. Available locations:"
    jq -r '.locations | keys[] | "  " + .' "$MAPPINGS"; } >&2
  exit 1
fi

BODY_TAG="$(jq -r '.tag' <<<"$CLASS_JSON")"
# brands may be a literal array or the string "luxury" referencing .luxury_brands
BRANDS_JSON="$(jq -c --argjson cls "$CLASS_JSON" \
  'if ($cls.brands | type) == "string" then .luxury_brands else $cls.brands end' "$MAPPINGS")"
REQ_TAGS_JSON="$(jq -c '.require_tags // []' <<<"$CLASS_JSON")"
SIGNED_IDS="$(jq -c '.categories.signed.ids' "$MAPPINGS")"
MKT_IDS="$(jq -c '.categories.marketplace.ids' "$MAPPINGS")"
MAKES_JSON="$(jq -c '.makes' "$MAPPINGS")"

mapfile -t QUERY_TAGS < <(jq -r '.[]' <<<"$LOC_TAGS_JSON")
# Nationwide/shippable results are first-class unless suppressed: brokers
# ship anywhere, and signed deals tagged usa-nationwide are valid benchmarks.
if (( ! LOCAL_ONLY )) \
   && ! jq -e 'index("usa-nationwide")' <<<"$LOC_TAGS_JSON" >/dev/null; then
  QUERY_TAGS+=("usa-nationwide")
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

code="$(curl -s -o /dev/null -w "%{http_code}" -H "User-Agent: $UA" "$BASE_URL/site.json")"
[[ "$code" == "200" ]] || die "cannot reach $BASE_URL (HTTP $code)"

# fetch <url> <outfile>  — GET with politeness + 429 backoff; returns 1 on give-up
fetch() {
  local url="$1" out="$2" attempt code retry_after
  for attempt in 1 2 3; do
    code="$(curl -sg -D "$TMP/headers" -o "$out" -w "%{http_code}" -H "User-Agent: $UA" "$url")"
    if [[ "$code" == "200" ]]; then return 0; fi
    if [[ "$code" == "429" ]]; then
      retry_after="$(awk 'tolower($1)=="retry-after:" {gsub(/\r/,""); print $2}' "$TMP/headers")"
      retry_after="${retry_after:-30}"
      echo "Warning: HTTP 429 on $url — backing off ${retry_after}s (attempt $attempt/3)" >&2
      sleep "$retry_after"
    else
      echo "Warning: HTTP $code on $url (attempt $attempt/3)" >&2
      sleep 2
    fi
  done
  return 1
}

TOPICS="$TMP/topics.ndjson"
: > "$TOPICS"

for loc in "${QUERY_TAGS[@]}"; do
  for (( page=0; page<PAGES; page++ )); do
    url="$BASE_URL/tags/intersection/$BODY_TAG/$loc.json?match_all_tags=true&page=$page"
    if ! fetch "$url" "$TMP/page.json"; then
      echo "Warning: giving up on tag query $BODY_TAG+$loc page $page" >&2
      break
    fi
    count="$(jq '.topic_list.topics | length' "$TMP/page.json" 2>/dev/null || echo 0)"
    (( count == 0 )) && break
    jq -c '.topic_list.topics[]' "$TMP/page.json" >> "$TOPICS"
    per_page="$(jq '.topic_list.per_page // 30' "$TMP/page.json")"
    (( count < per_page )) && break
    sleep 1
  done
  sleep 1
done

if (( RAW )); then
  cat "$TOPICS"
  exit 0
fi

CUTOFF="$(date -u -d "@$(( $(date -u +%s) - DAYS * 86400 ))" +%Y-%m-%dT%H:%M:%SZ)"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -s \
  --argjson signed_ids "$SIGNED_IDS" \
  --argjson mkt_ids "$MKT_IDS" \
  --argjson brands "$BRANDS_JSON" \
  --argjson req_tags "$REQ_TAGS_JSON" \
  --argjson loc_tags "$LOC_TAGS_JSON" \
  --argjson makes "$MAKES_JSON" \
  --argjson max "$MAX" \
  --argjson days "$DAYS" \
  --arg cutoff "$CUTOFF" \
  --arg base "$BASE_URL" \
  --arg class "$CLASS" \
  --arg location "$LOCATION" \
  --arg body_tag "$BODY_TAG" \
  --arg category "$CATEGORY" \
  --arg generated_at "$GENERATED_AT" \
  '
  # the intersection endpoint returns tags as {id,name,slug} objects;
  # other endpoints return plain strings — normalize to names
  def clean: unique_by(.id)
    | map(select(.tags != null))
    | map(.tags = (.tags | map(if type == "object" then .name else . end)))
    | map(select(.tags | index("EXPIRED") | not));

  def section: if ([.category_id] | inside($signed_ids)) then "signed"
    elif ([.category_id] | inside($mkt_ids)) then "marketplace"
    else null end;

  def brand_of: .tags as $t | (first($makes[] | select(. as $m | $t | index($m))) // null);

  def availability: .tags as $t
    | if any($loc_tags[]; . as $l | $t | index($l)) then "local"
      elif ($t | index("usa-nationwide")) then "nationwide"
      elif ($t | index("shipping")) then "ships"
      else "other" end;

  def shape: {
    id, title, slug,
    url: "\($base)/t/\(.slug)/\(.id)",
    brand: brand_of,
    tags, created_at, bumped_at,
    posts_count, views, like_count,
    gist: (.ai_topic_gist // null),
    availability: availability,
    ships: ((.tags | index("shipping")) != null)
  };

  clean
  | map(. + {section: section})
  | map(select(.section != null))
  | map(select(($brands | length) == 0 or (.tags as $t | any($brands[]; . as $b | $t | index($b)))))
  | map(select(($req_tags | length) == 0 or all($req_tags[]; . as $r | .tags | index($r))))
  | {
      query: {
        class: $class, location: $location,
        body_tag: $body_tag, location_tags: $loc_tags,
        brands: $brands, require_tags: $req_tags,
        category: $category, days: $days, generated_at: $generated_at
      },
      signed: (if $category == "marketplace" then [] else
        [ .[] | select(.section == "signed" and .created_at >= $cutoff) | shape ]
        | sort_by(.created_at) | reverse | .[:$max] end),
      marketplace: (if $category == "signed" then [] else
        [ .[] | select(.section == "marketplace" and ((.bumped_at // .created_at) >= $cutoff)) | shape ]
        | sort_by(.bumped_at // .created_at) | reverse | .[:$max] end)
    }
  ' "$TOPICS" > "$TMP/result.json"

RESULT="$TMP/result.json"

if (( DETAILS > 0 )); then
  DETAILS_ND="$TMP/details.ndjson"
  : > "$DETAILS_ND"
  while read -r id; do
    sleep 1
    if ! fetch "$BASE_URL/t/$id.json" "$TMP/topic.json"; then
      echo "Warning: skipping details for topic $id" >&2
      continue
    fi
    jq -r '.post_stream.posts[0].cooked // ""' "$TMP/topic.json" \
      | sed -e 's/<[^>]*>/ /g' \
            -e 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g; s/&nbsp;/ /g' \
      | tr -s ' ' ' ' | grep -v '^ *$' | head -c 1500 \
      | jq -Rs --argjson id "$id" '{id: $id, excerpt: .}' >> "$DETAILS_ND"
  done < <(jq -r ".signed[:$DETAILS][].id, .marketplace[:$DETAILS][].id" "$RESULT")

  jq --slurpfile det <(jq -s '.' "$DETAILS_ND") '
    ($det[0] | map({key: (.id | tostring), value: .excerpt}) | from_entries) as $ex
    | .signed |= map(. + (if $ex[.id | tostring] then {first_post_excerpt: $ex[.id | tostring]} else {} end))
    | .marketplace |= map(. + (if $ex[.id | tostring] then {first_post_excerpt: $ex[.id | tostring]} else {} end))
  ' "$RESULT" > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
fi

# --hot: brokers post one-off limited/high-demand specials as recent replies
# in their megathreads, not in the (often outdated) first post
if (( HOT > 0 )); then
  HOT_ND="$TMP/hot.ndjson"
  : > "$HOT_ND"
  while read -r id; do
    sleep 1
    if ! fetch "$BASE_URL/t/$id.json" "$TMP/topic.json"; then
      echo "Warning: skipping recent posts for topic $id" >&2
      continue
    fi
    qs="$(jq -r '[.post_stream.stream[-3:][] | "post_ids[]=\(.)"] | join("&")' "$TMP/topic.json")"
    [[ -n "$qs" ]] || continue
    sleep 1
    if ! fetch "$BASE_URL/t/$id/posts.json?$qs" "$TMP/posts.json"; then
      echo "Warning: skipping recent posts for topic $id" >&2
      continue
    fi
    jq -c --argjson id "$id" '
      {id: $id,
       recent_posts: [.post_stream.posts[]
         | {username, created_at,
            excerpt: ((.cooked // "")
              | gsub("<[^>]*>"; " ")
              | gsub("&amp;"; "&") | gsub("&lt;"; "<") | gsub("&gt;"; ">")
              | gsub("&quot;"; "\"") | gsub("&#39;"; "'\''") | gsub("&nbsp;"; " ")
              | gsub("\\s+"; " ")
              | .[0:900])}]}
    ' "$TMP/posts.json" >> "$HOT_ND"
  done < <(jq -r ".marketplace[:$HOT][].id" "$RESULT")

  jq --slurpfile hot <(jq -s '.' "$HOT_ND") '
    ($hot[0] | map({key: (.id | tostring), value: .recent_posts}) | from_entries) as $rp
    | .marketplace |= map(. + (if $rp[.id | tostring] then {recent_posts: $rp[.id | tostring]} else {} end))
  ' "$RESULT" > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
fi

cat "$RESULT"
