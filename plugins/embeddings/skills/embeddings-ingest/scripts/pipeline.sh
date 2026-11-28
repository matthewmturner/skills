#!/usr/bin/env bash
# pipeline.sh — Extract, chunk, embed, and upsert documents to Qdrant.
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
DOCUMENT=""
HF_REPO="nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M"
EMBED_DIM=768         # nomic-embed-text-v1.5 dimensionality
CHUNK_SIZE=500        # words per chunk
CHUNK_OVERLAP=50      # words of overlap between chunks
STORE_TEXT=true       # include full chunk text in payload
QDRANT_URL="http://localhost:6333"
POOLING="mean"
GPU_LAYERS="auto"
DELETE_EXISTING=false
FORCE_CREATE=false

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") -d <document> [options]

Required:
  -d PATH    Document or directory to embed

Optional:
  --hf REPO  HuggingFace repo + quant (default: nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M)
  -s NUM     Chunk size in words (default: 500)
  -o NUM     Chunk overlap in words (default: 50)
  -n         Do NOT store full text in payload
  -u URL     Qdrant URL (default: http://localhost:6333)
  -p TYPE    Pooling strategy: mean, cls, last, none, rank (default: mean)
  -g NUM     GPU layers (0=all CPU, 'all'=full offload, default: auto)
  --delete   Delete existing points for document before re-ingesting
  --force-create   Recreate Qdrant collection even if it exists
EOF
  exit 1
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) DOCUMENT="$2"; shift 2 ;;
    --hf) HF_REPO="$2"; shift 2 ;;
    -s) CHUNK_SIZE="$2"; shift 2 ;;
    -o) CHUNK_OVERLAP="$2"; shift 2 ;;
    -n) STORE_TEXT=false; shift ;;
    -u) QDRANT_URL="$2"; shift 2 ;;
    -p) POOLING="$2"; shift 2 ;;
    -g) GPU_LAYERS="$2"; shift 2 ;;
    --delete) DELETE_EXISTING=true; shift ;;
    --force-create) FORCE_CREATE=true; shift ;;
    -h|--help) usage ;;
    *) echo "ERROR: Unknown argument: $1"; usage ;;
  esac
done

if [[ -z "$DOCUMENT" ]]; then
  echo "ERROR: Document path required (-d)"
  usage
fi
if [[ ! -e "$DOCUMENT" ]]; then
  echo "ERROR: Document not found: $DOCUMENT"
  exit 1
fi

# ── Derived values ────────────────────────────────────────────────────────────
# Collection name = HF repo name, sanitized
# e.g. nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M → nomic-ai-nomic-embed-text-v1.5-gguf-q4-k-m
COLLECTION=$(echo "$HF_REPO" | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9._:-]/-/g' \
  | sed 's/-\{2,\}/-/g' \
  | sed 's/\./-/g' \
  | sed 's/:/-/g' \
  | sed 's/^-*//;s/-*$//' \
  | sed 's|/|-|g')

# Embedding dimension is known for the hardcoded model (nomic-embed-text-v1.5 = 768)
# If using a different model via -h, adjust EMBED_DIM accordingly.

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Document Embeddings Pipeline"
echo "═══════════════════════════════════════════════════════════"
echo "  Document : $DOCUMENT"
echo "  Model    : $HF_REPO"
echo "  Dim      : $EMBED_DIM"
echo "  Pooling  : $POOLING"
echo "  GPU      : $GPU_LAYERS"
echo "  Collection : $COLLECTION"
echo "  Chunk size: $CHUNK_SIZE words"
echo "  Overlap  : $CHUNK_OVERLAP words"
echo "  Store txt: $STORE_TEXT"
echo "  Qdrant   : $QDRANT_URL"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── Temp directory ────────────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Step 1: Check Qdrant connectivity ─────────────────────────────────────────
echo "[1/5] Checking Qdrant connectivity..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$QDRANT_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "ERROR: Cannot reach Qdrant at $QDRANT_URL (HTTP $HTTP_CODE)"
  exit 1
fi
echo "  ✓ Qdrant is reachable"

# ── Step 2: Extract text ─────────────────────────────────────────────────────
echo ""
echo "[2/5] Extracting text..."

extract_file() {
  local src="$1" dest="$2"
  local ext="${src##*.}"
  case "$ext" in
    pdf)
      pdftotext "$src" "$dest" 2>/dev/null
      if [[ ! -s "$dest" ]]; then
        echo "  WARNING: pdftotext failed for $src, falling back to raw read"
        cat "$src" > "$dest" 2>/dev/null || true
      fi
      ;;
    *)
      # Direct read — txt, md, code, csv, json, xml, yaml, html, etc.
      cat "$src" > "$dest" 2>/dev/null || true
      ;;
  esac
}

# Collect all files to process
declare -a SOURCE_FILES=()
declare -a EXTRACTED_FILES=()

if [[ -d "$DOCUMENT" ]]; then
  while IFS= read -r -d '' file; do
    SOURCE_FILES+=("$file")
  done < <(find "$DOCUMENT" -type f -print0 2>/dev/null | sort -z)
  if [[ ${#SOURCE_FILES[@]} -eq 0 ]]; then
    echo "ERROR: No files found in directory: $DOCUMENT"
    exit 1
  fi
  echo "  Found ${#SOURCE_FILES[@]} files in directory"
else
  SOURCE_FILES=("$DOCUMENT")
fi

for src in "${SOURCE_FILES[@]}"; do
  safe_name=$(echo "$src" | sed 's/[^a-zA-Z0-9._-]/_/g')
  ext_file="$WORK_DIR/${safe_name}.txt"
  extract_file "$src" "$ext_file"
  if [[ -s "$ext_file" ]]; then
    EXTRACTED_FILES+=("$ext_file")
  else
    echo "  SKIPPED: $src (empty after extraction)"
  fi
done

echo "  ✓ Extracted ${#EXTRACTED_FILES[@]} file(s)"

# ── Step 3: Create or verify Qdrant collection ───────────────────────────────
echo ""
echo "[3/5] Setting up Qdrant collection '$COLLECTION'..."

COLLECTION_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" "$QDRANT_URL/collections/$COLLECTION" 2>/dev/null || echo "000")

if [[ "$FORCE_CREATE" == true ]] || [[ "$COLLECTION_EXISTS" == "404" ]]; then
  if [[ "$COLLECTION_EXISTS" == "200" ]] && [[ "$FORCE_CREATE" != true ]]; then
    echo "  ✓ Collection '$COLLECTION' already exists"
  else
    if [[ "$COLLECTION_EXISTS" == "200" ]]; then
      curl -s -X DELETE "$QDRANT_URL/collections/$COLLECTION" >/dev/null 2>&1
      echo "  Deleted existing collection '$COLLECTION'"
    fi

    curl -s -X PUT "$QDRANT_URL/collections/$COLLECTION" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --argjson dim "$EMBED_DIM" '{
        "vectors": { "size": $dim, "distance": "Cosine" },
        "hnsw_config": { "m": 16, "ef_construct": 100 }
      }')" >/dev/null 2>&1
    echo "  ✓ Created collection '$COLLECTION' (dim=$EMBED_DIM, Cosine)"
  fi
else
  echo "  ✓ Collection '$COLLECTION' already exists"
fi

# ── Step 4: Chunk text ───────────────────────────────────────────────────────
echo ""
echo "[4/5] Chunking text..."

CHUNK_DIR="$WORK_DIR/chunks"
mkdir -p "$CHUNK_DIR"
TOTAL_CHUNKS=0

# chunk_file: split text into word-based chunks with overlap
# Uses awk for memory-efficient tokenization
# Outputs: $CHUNK_DIR/<safe_name>_<idx>.chunk  (text)
#          $CHUNK_DIR/<safe_name>_<idx>.meta    (safe_name\tidx\tword_start\tword_end)
chunk_file() {
  local ext_file="$1"
  local safe_name="$2"

  local step=$((CHUNK_SIZE - CHUNK_OVERLAP))
  if [[ $step -le 0 ]]; then
    step=1
  fi

  local added
  added=$(awk -v chunk_size="$CHUNK_SIZE" -v step="$step" \
              -v chunk_dir="$CHUNK_DIR" -v safe_name="$safe_name" \
  'BEGIN { n = 0 }
  {
    for (i = 1; i <= NF; i++) {
      words[n] = $i
      n++
    }
  }
  END {
    if (n == 0) { print 0; exit }
    idx = 0
    offset = 0
    while (offset < n) {
      end = offset + chunk_size
      if (end > n) end = n

      chunk_path = chunk_dir "/" safe_name "_" idx ".chunk"
      for (j = offset; j < end; j++) {
        if (j > offset) printf " " > chunk_path
        printf "%s", words[j] > chunk_path
      }
      printf "\n" > chunk_path
      close(chunk_path)

      meta_path = chunk_dir "/" safe_name "_" idx ".meta"
      printf "%s\t%d\t%d\t%d\n", safe_name, idx, offset, end > meta_path
      close(meta_path)

      idx++
      offset = offset + step
      if (end >= n) break
    }
    print idx
  }' "$ext_file")

  TOTAL_CHUNKS=$((TOTAL_CHUNKS + added))
}

for i in "${!EXTRACTED_FILES[@]}"; do
  ext_file="${EXTRACTED_FILES[$i]}"
  src_file="${SOURCE_FILES[$i]}"
  safe_name=$(echo "$src_file" | sed 's/[^a-zA-Z0-9._-]/_/g')
  chunk_file "$ext_file" "$safe_name"
done

echo "  ✓ Total chunks: $TOTAL_CHUNKS"

if [[ $TOTAL_CHUNKS -eq 0 ]]; then
  echo "ERROR: No chunks produced. Check that files contain extractable text."
  exit 1
fi

# ── Step 5: Embed and upsert ──────────────────────────────────────────────────
echo ""
echo "[5/5] Embedding and uploading to Qdrant..."

BATCH_SIZE=64
UPSERT_BATCH="$WORK_DIR/upsert_batch.json"
echo '{"points":[]}' > "$UPSERT_BATCH"
PROCESSED=0
FAILED=0

# ── Helper functions ──────────────────────────────────────────────────────────
upsert_batch() {
  local count
  count=$(jq '.points | length' "$UPSERT_BATCH")
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "$QDRANT_URL/collections/$COLLECTION/points" \
    -H "Content-Type: application/json" \
    -d @"$UPSERT_BATCH" 2>/dev/null)

  if [[ "$http_code" == "200" ]] || [[ "$http_code" == "201" ]] || [[ "$http_code" == "204" ]]; then
    echo "  ✓ Uploaded $count points ($PROCESSED/$TOTAL_CHUNKS)"
  else
    echo "  ⚠ Upsert returned HTTP $http_code, retrying..."
    sleep 1
    curl -s -X PUT "$QDRANT_URL/collections/$COLLECTION/points" \
      -H "Content-Type: application/json" \
      -d @"$UPSERT_BATCH" >/dev/null 2>&1
  fi
}

flush_batch() {
  local remaining
  remaining=$(jq '.points | length' "$UPSERT_BATCH")
  if [[ $remaining -ge $BATCH_SIZE ]]; then
    upsert_batch
    echo '{"points":[]}' > "$UPSERT_BATCH"
  fi
}

# Delete existing points for the document (if --delete)
if [[ "$DELETE_EXISTING" == true ]]; then
  for src in "${SOURCE_FILES[@]}"; do
    safe_name=$(echo "$src" | sed 's/[^a-zA-Z0-9._-]/_/g')
    curl -s -X POST "$QDRANT_URL/collections/$COLLECTION/points/delete" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg sf "$safe_name" '{
        "filter": { "must": [{ "key": "source_file", "match": { "value": $sf } }] }
      }')" >/dev/null 2>&1
  done
  echo "  Deleted existing points for document(s)"
fi

# Process chunks: embed each one, batch upserts to Qdrant
# llama-embedding is called per-chunk; model is mmap'd so reloads are fast.
# For faster embedding with llama-server, consider running llama-server
# and using the /embedding endpoint instead.

declare -a ALL_META_FILES=()
while IFS= read -r -d '' mf; do
  ALL_META_FILES+=("$mf")
done < <(find "$CHUNK_DIR" -name '*.meta' -print0 | sort -z)

for meta_file in "${ALL_META_FILES[@]}"; do
  IFS=$'\t' read -r safe_name chunk_idx word_start word_end < "$meta_file"
  chunk_file="$CHUNK_DIR/${safe_name}_${chunk_idx}.chunk"

  if [[ ! -f "$chunk_file" ]]; then
    echo "  WARNING: Missing chunk $safe_name chunk $chunk_idx"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Embed — write chunk to temp file, call llama-embedding
  cp "$chunk_file" "$WORK_DIR/current_chunk.txt"

  EMBED_JSON=$(llama-embedding \
    -hf "$HF_REPO" \
    -f "$WORK_DIR/current_chunk.txt" \
    --embd-output-format json \
    --pooling "$POOLING" \
    --gpu-layers "$GPU_LAYERS" \
    --no-warmup \
    2>/dev/null) || {
    echo "  ERROR: Embedding failed for $safe_name chunk $chunk_idx"
    FAILED=$((FAILED + 1))
    continue
  }

  EMBED_VECTOR=$(echo "$EMBED_JSON" | jq -c '.data[0].embedding')
  if [[ -z "$EMBED_VECTOR" ]] || [[ "$EMBED_VECTOR" == "null" ]]; then
    echo "  ERROR: No embedding vector for $safe_name chunk $chunk_idx"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Deterministic point ID (UUID from first 32 hex chars of SHA-256)
  POINT_ID=$(printf "%s_%d" "$safe_name" "$chunk_idx" | sha256sum | cut -c1-32 | sed 's/^\(.{8}\)\(.{4}\)\(.{4}\)\(.{4}\)\(.*\)$/\1-\2-\3-\4-\5/')

  # Build payload
  if [[ "$STORE_TEXT" == true ]]; then
    CHUNK_TEXT=$(cat "$chunk_file")
    PAYLOAD=$(jq -n \
      --arg sf "$safe_name" \
      --argjson ci "$chunk_idx" \
      --arg text "$CHUNK_TEXT" \
      --argjson ws "$word_start" \
      --argjson we "$word_end" \
      '{source_file: $sf, chunk_index: $ci, text: $text, word_range: [$ws, $we]}')
  else
    PAYLOAD=$(jq -n \
      --arg sf "$safe_name" \
      --argjson ci "$chunk_idx" \
      --argjson ws "$word_start" \
      --argjson we "$word_end" \
      '{source_file: $sf, chunk_index: $ci, word_range: [$ws, $we]}')
  fi

  # Add point to batch
  jq --arg id "$POINT_ID" \
     --argjson vec "$EMBED_VECTOR" \
     --argjson payload "$PAYLOAD" \
     '.points += [{"id": $id, "vector": $vec, "payload": $payload}]' \
     "$UPSERT_BATCH" > "$WORK_DIR/upsert_tmp.json"
  mv "$WORK_DIR/upsert_tmp.json" "$UPSERT_BATCH"

  PROCESSED=$((PROCESSED + 1))
  flush_batch

  # Progress indicator every 10 chunks
  if (( PROCESSED % 10 == 0 )); then
    pct=$((PROCESSED * 100 / TOTAL_CHUNKS))
    echo "  Progress: $PROCESSED/$TOTAL_CHUNKS ($pct%)"
  fi
done

# Flush remaining
REMAINING=$(jq '.points | length' "$UPSERT_BATCH")
if [[ $REMAINING -gt 0 ]]; then
  upsert_batch
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Done!"
echo "  Collection : $COLLECTION ($EMBED_DIM-dim vectors, Cosine)"
echo "  Chunks     : $TOTAL_CHUNKS"
echo "  Embedded   : $PROCESSED"
if [[ $FAILED -gt 0 ]]; then
  echo "  Failed     : $FAILED"
fi
echo "═══════════════════════════════════════════════════════════"
