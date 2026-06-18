---
name: embeddings-query
description: Query embeddings stored in a local Qdrant vector database. Supports retrieving a point by ID, semantic search (nearest-neighbor), and scrolling through a collection. Use after ingesting documents with the embeddings-ingest skill.
---

# Query Embeddings

Retrieve stored embeddings, search by semantic similarity, or scroll through a Qdrant collection.

## Prerequisites

- `llama-embedding` (from llama.cpp) — for creating query embeddings (search mode)
- `curl` — for Qdrant REST API calls
- `jq` — for formatting JSON output
- Qdrant running locally (default: `http://localhost:6333`)

## Usage

```bash
scripts/query.sh -c <collection> [mode] [options]
```

### Required Arguments

| Flag | Description |
|------|-------------|
| `-c NAME` | Qdrant collection name |

### Modes (pick one)

| Flag | Description |
|------|-------------|
| *(none)* | **Scroll** — list points in the collection (paginated) |
| `-i ID` | **Get by ID** — retrieve a specific point |
| `-q TEXT` | **Search** — semantic nearest-neighbor search |

### Optional Arguments

| Flag | Default | Description |
|------|---------|-------------|
| `-n NUM` | 5 | Number of results to return |
| `-o TOKEN` | — | Scroll offset (use token from previous page) |
| `-u URL` | `http://localhost:6333` | Qdrant server URL |
| `--hf REPO` | `nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M` | HuggingFace model for embedding queries |
| `-p POOL` | `mean` | Pooling strategy |
| `-g NUM` | `auto` | GPU layers |
| `--no-payload` | off | Exclude payload from results |
| `--raw` | off | Output raw JSON (no formatting) |

### Examples

```bash
# Scroll — list first page of points
scripts/query.sh -c nomic-ai-nomic-embed-text-v1.5-gguf-q4-k-m

# Scroll with pagination
scripts/query.sh -c nomic-ai-nomic-embed-text-v1.5-gguf-q4-k-m -n 20
# Then next page with the offset token:
scripts/query.sh -c nomic-ai-nomic-embed-text-v1.5-gguf-q4-k-m -n 20 -o 2a3f1b4c

# Get a specific point by ID
scripts/query.sh -c nomic-ai-nomic-embed-text-v1.5-gguf-q4-k-m -i 2a3f1b4c

# Semantic search
scripts/query.sh -c nomic-ai-nomic-embed-text-v1.5-gguf-q4-k-m \
  -q "What is the company revenue for 2024?"

# Search with more results
scripts/query.sh -c nomic-ai-nomic-embed-text-v1.5-gguf-q4-k-m \
  -q "machine learning pipeline" -n 10
```

## Output Format

Results are displayed in a table:

```
  #    ID              SOURCE               CHUNK   SCORE    TEXT
  ──────────────────────────────────────────────────────────────────────────
  1    a1b2c3d4        report.pdf           3       0.923    Q3 revenue increased by...
  2    f5e6d7c8        report.pdf           2       0.891    Total revenue for 2024...
  3    9g0h1i2j        summary.txt          0       0.846    The company reported...
```

## Collection Names

Collection names are derived from the embedding model used during ingestion:
- `nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M` → `nomic-ai-nomic-embed-text-v1.5-gguf-q4-k-m`

The same model must be used for searching as was used for ingestion to get meaningful results.
