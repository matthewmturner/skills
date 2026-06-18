#!/usr/bin/env bash
# query.sh — Retrieve, search, or scroll embeddings in a local Qdrant collection.
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
COLLECTION=""
QUERY_ID=""
QUERY_TEXT=""
LIMIT=5
QDRANT_URL="http://localhost:6333"
HF_REPO="nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M"
POOLING="mean"
GPU_LAYERS="auto"
WITH_PAYLOAD=true
RAW_OUTPUT=false
OFFSET=""

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") -c <collection> <mode> [options]

Required:
  -c NAME    Qdrant collection name

Modes (pick one):
  -i ID      Get a point by ID
  -q TEXT    Semantic search (nearest-neighbor)
  (none)     Scroll the collection (list points)

Optional:
  -n NUM     Number of results (default: 5)
  -o NUM     Scroll offset (next page token from previous result)
  -u URL     Qdrant URL (default: http://localhost:6333)
  --hf REPO  HuggingFace model repo (default: nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M)
  -p TYPE    Pooling strategy: mean, cls, last, none, rank (default: mean)
  -g NUM     GPU layers (0=all CPU, 'all'=full offload, default: auto)
  --no-payload   Exclude payload from results
  --raw        Output raw JSON (no formatting)
EOF
  exit 1
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) COLLECTION="$2"; shift 2 ;;
    -i) QUERY_ID="$2"; shift 2 ;;
    -q) QUERY_TEXT="$2"; shift 2 ;;
    -n) LIMIT="$2"; shift 2 ;;
    -o) OFFSET="$2"; shift 2 ;;
    -u) QDRANT_URL="$2"; shift 2 ;;
    --hf) HF_REPO="$2"; shift 2 ;;
    -p) POOLING="$2"; shift 2 ;;
    -g) GPU_LAYERS="$2"; shift 2 ;;
    --no-payload) WITH_PAYLOAD=false; shift ;;
    --raw) RAW_OUTPUT=true; shift ;;
    -h|--help) usage ;;
    *) echo "ERROR: Unknown argument: $1"; usage ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
if [[ -z "$COLLECTION" ]]; then
  echo "ERROR: Collection name required (-c)"
  usage
fi
if [[ -n "$QUERY_ID" ]] && [[ -n "$QUERY_TEXT" ]]; then
  echo "ERROR: Cannot use both -i and -q simultaneously"
  usage
fi

# ── Temp directory ────────────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Check Qdrant connectivity ─────────────────────────────────────────────────
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$QDRANT_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "ERROR: Cannot reach Qdrant at $QDRANT_URL (HTTP $HTTP_CODE)"
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

# Print a formatted table from query results (array of compact JSON points)
print_table() {
  local results="$1"
  local total
  total=$(echo "$results" | wc -l)

  if [[ -z "$results" ]] || [[ "$total" -eq 0 ]]; then
    echo "  No results."
    return
  fi

  # Header
  printf "  %-3s  %-14s  %-20s  %-7s  %-6s  %s\n" "#" "ID" "SOURCE" "CHUNK" "SCORE" "TEXT"
  printf "  %s\n" "$(printf '%.0s─' {1..80})"

  local idx=0
  while IFS= read -r point; do
    idx=$((idx + 1))
    local pid src chunk score text

    pid=$(echo "$point" | jq -r '.id // "n/a"')
    local payload
    payload=$(echo "$point" | jq -c '.payload // {}')

    src=$(echo "$payload" | jq -r '.source_file // "—"')
    chunk=$(echo "$payload" | jq -r '.chunk_index // "—"')
    score=$(echo "$point" | jq -r '.score // "—"')
    text=$(echo "$payload" | jq -r '.text // "—"' | tr '\n' ' ')

    # Truncate long fields
    if [[ ${#pid} -gt 12 ]]; then pid="${pid:0:10}…"; fi
    if [[ ${#src} -gt 18 ]]; then src="${src:0:16}…"; fi
    if [[ ${#text} -gt 40 ]]; then text="${text:0:38}…"; fi

    printf "  %-3d  %-14s  %-20s  %-7s  %-6s  %s\n" \
      "$idx" "$pid" "$src" "$chunk" "$score" "$text"
  done <<< "$results"

  echo ""
}

# ── Mode: Get by ID ───────────────────────────────────────────────────────────
if [[ -n "$QUERY_ID" ]]; then
  echo "GET by ID: $QUERY_ID" >&2

  RESPONSE=$(curl -s \
    "$QDRANT_URL/collections/$COLLECTION/points/$QUERY_ID" \
    -H "Content-Type: application/json" \
    2>/dev/null)

  if [[ "$RAW_OUTPUT" == true ]]; then
    echo "$RESPONSE"
  else
    RESULT=$(echo "$RESPONSE" | jq -c '.result' 2>/dev/null)
    if [[ -z "$RESULT" ]]; then
      echo "ERROR: No result for ID $QUERY_ID"
      echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
      exit 1
    fi

    PAYLOAD=$(echo "$RESULT" | jq -c '.payload // {}')
    SOURCE=$(echo "$PAYLOAD" | jq -r '.source_file // "—"')
    CHUNK=$(echo "$PAYLOAD" | jq -r '.chunk_index // "—"')
    TEXT=$(echo "$PAYLOAD" | jq -r '.text // "" | if length > 200 then .[0:200] + "..." else . end')

    echo ""
    printf "  %-10s  %s\n" "ID:" "$QUERY_ID"
    printf "  %-10s  %s\n" "Source:" "$SOURCE"
    printf "  %-10s  %s\n" "Chunk:" "$CHUNK"
    echo ""
    if [[ -n "$TEXT" ]]; then
      echo "  Text:"
      echo "$TEXT" | sed 's/^/    /'
      echo ""
    fi

    if [[ "$WITH_PAYLOAD" == true ]]; then
      echo "$RESULT" | jq .
    fi
  fi
  exit 0
fi

# ── Mode: Semantic Search ─────────────────────────────────────────────────────
if [[ -n "$QUERY_TEXT" ]]; then
  echo "Searching: \"$QUERY_TEXT\"" >&2

  echo "$QUERY_TEXT" > "$WORK_DIR/query.txt"

  EMBED_JSON=$(llama-embedding \
    -hf "$HF_REPO" \
    -f "$WORK_DIR/query.txt" \
    --embd-output-format json \
    --pooling "$POOLING" \
    -g "$GPU_LAYERS" \
    --no-warmup \
    2>/dev/null) || {
    echo "ERROR: Failed to embed query text"
    exit 1
  }

  QUERY_VECTOR=$(echo "$EMBED_JSON" | jq -c '.data[0].embedding')
  if [[ -z "$QUERY_VECTOR" ]] || [[ "$QUERY_VECTOR" == "null" ]]; then
    echo "ERROR: No embedding vector for query"
    exit 1
  fi

  SEARCH_BODY=$(jq -n \
    --argjson vector "$QUERY_VECTOR" \
    --argjson limit "$LIMIT" \
    --argjson with_payload "$WITH_PAYLOAD" \
    '{
      "query": $vector,
      "limit": $limit,
      "with_payload": $with_payload
    }')

  RESPONSE=$(curl -s \
    -X POST "$QDRANT_URL/collections/$COLLECTION/points/query" \
    -H "Content-Type: application/json" \
    -d "$SEARCH_BODY" \
    2>/dev/null)

  if [[ "$RAW_OUTPUT" == true ]]; then
    echo "$RESPONSE"
  else
    RESULTS=$(echo "$RESPONSE" | jq -c '.result[]?' 2>/dev/null)
    if [[ -z "$RESULTS" ]]; then
      echo "ERROR: No results returned"
      echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
      exit 1
    fi

    echo ""
    echo "  Query: \"$QUERY_TEXT\""
    echo ""
    print_table "$RESULTS"
  fi
  exit 0
fi

# ── Mode: Scroll (default — no query params) ──────────────────────────────────
echo "Scrolling collection: $COLLECTION" >&2

SCROLL_BODY=$(jq -n \
  --argjson limit "$LIMIT" \
  --argjson with_payload "$WITH_PAYLOAD" \
  --arg offset "${OFFSET:-}" \
  '{
    "limit": $limit,
    "with_payload": $with_payload
  } | if $offset != "" then . + {"offset": $offset} else . end')

RESPONSE=$(curl -s \
  -X POST "$QDRANT_URL/collections/$COLLECTION/points/scroll" \
  -H "Content-Type: application/json" \
  -d "$SCROLL_BODY" \
  2>/dev/null)

if [[ "$RAW_OUTPUT" == true ]]; then
  echo "$RESPONSE"
  exit 0
fi

POINTS=$(echo "$RESPONSE" | jq -c '.result.points[]?' 2>/dev/null)
NEXT_OFFSET=$(echo "$RESPONSE" | jq -r '.result.next_page_offset // empty')

if [[ -z "$POINTS" ]]; then
  echo "  No points found in collection '$COLLECTION'."
  exit 0
fi

TOTAL=$(echo "$POINTS" | wc -l)
echo ""
echo "  Collection: $COLLECTION ($TOTAL point(s) on this page)"
echo ""
print_table "$POINTS"

if [[ -n "$NEXT_OFFSET" ]]; then
  echo "  Next page offset: $NEXT_OFFSET"
  echo "  Use: -o $NEXT_OFFSET"
else
  echo "  (end of collection)"
fi
echo ""
