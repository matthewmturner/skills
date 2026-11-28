---
name: embeddings-ingest
description: Extract text from documents (PDF, TXT, MD, code files, CSV, JSON, XML, etc.), chunk the text, create embeddings with llama-embedding (llama.cpp, nomic-embed-text-v1.5), and upload to a local Qdrant vector database. Use when ingesting documents for semantic search, RAG pipelines, or vector storage.
---

# Document Embeddings

Pipeline: **extract** → **chunk** → **embed** → **upsert to Qdrant**.

## Prerequisites

- `llama-embedding` (from llama.cpp) — for creating embeddings
- `pdftotext` (from poppler) — for PDF extraction
- `jq` — for JSON construction
- `curl` — for Qdrant REST API calls
- Qdrant running locally (default: `http://localhost:6333`)

The embedding model is downloaded automatically from Hugging Face on first run.

## Usage

```bash
scripts/pipeline.sh -d <document> [options]
```

### Required Arguments

| Flag | Description |
|------|-------------|
| `-d PATH` | Document file or directory to embed |

### Optional Arguments

| Flag | Default | Description |
|------|---------|-------------|
| `--hf REPO` | `nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M` | HuggingFace repo + quantization |
| `-s NUM` | 500 | Chunk size in words |
| `-o NUM` | 50 | Chunk overlap in words |
| `-n` | off | Do NOT store full text in payload (metadata only) |
| `-u URL` | `http://localhost:6333` | Qdrant server URL |
| `-p POOL` | `mean` | Pooling strategy (`mean`, `cls`, `last`, `none`, `rank`) |
| `-g NUM` | `auto` | GPU layers to offload (`0`=CPU only, `all`=full offload) |
| `--delete` | off | Delete existing points for this document before re-ingesting |
| `--force-create` | off | Recreate the Qdrant collection even if it already exists |

### Examples

```bash
# Embed a single PDF, default model (nomic-embed-text-v1.5 Q4_K_M)
scripts/pipeline.sh -d report.pdf

# Embed a directory of Markdown files
scripts/pipeline.sh -d ./docs/

# Embed with custom chunking, no full text stored
scripts/pipeline.sh -d notes.pdf -s 300 -o 30 -n

# Embed with GPU offload, delete old points first
scripts/pipeline.sh -d data.json -g all --delete
```

## Supported File Types

| Extension | Extraction Method |
|-----------|------------------|
| `.pdf` | `pdftotext` (poppler) |
| `.txt`, `.md`, `.rst`, `.tex` | Direct read |
| `.py`, `.js`, `.ts`, `.java`, `.c`, `.cpp`, `.go`, `.rs`, `.rb`, `.sh` | Direct read |
| `.csv`, `.json`, `.xml`, `.yaml`, `.yml`, `.toml` | Direct read |
| `.html`, `.htm` | Direct read |
| All other files | Direct read (raw text attempt) |

Directories are supported — all files are processed recursively.

## How It Works

1. **Extract** — PDFs are converted with `pdftotext`; all other files are read as raw text.
2. **Chunk** — Text is split into word-based chunks (default 500 words) with configurable overlap (default 50 words) using a sliding window.
3. **Embed** — Each chunk is passed to `llama-embedding` via `-hf` (downloads/caches from Hugging Face automatically).
4. **Upsert** — Embeddings are batched (64 per request) and uploaded to Qdrant via its REST API.

### Model

The default model is `nomic-embed-text-v1.5` (Q4_K_M quantization, 768-dim vectors).
It is downloaded on first use and cached by llama.cpp — subsequent runs use the local copy.

To use a different model:
```bash
scripts/pipeline.sh -d doc.pdf --hf nomic-ai/nomic-embed-text-v1.5-GGUF:Q8_0
```

### Collection Naming

The Qdrant collection name is derived from the HuggingFace repo:
- `nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M` → `nomic-ai-nomic-embed-text-v1.5-gguf-q4-k-m`

### Payload Structure

**With full text** (default):
```json
{
  "source_file": "report.pdf",
  "chunk_index": 3,
  "text": "The full chunk content here...",
  "word_range": [1400, 1850]
}
```

**Without full text** (`-n` flag):
```json
{
  "source_file": "report.pdf",
  "chunk_index": 3,
  "word_range": [1400, 1850]
}
```

Point IDs are deterministic (SHA-256 of `source_file + chunk_index`), making re-ingestion idempotent.

## Performance Notes

- The model downloads on first use (~200MB for Q4_K_M) and is cached locally by llama.cpp.
- For very large documents (1000+ chunks), consider running `llama-server` for faster batched embedding.

## Errors

The script validates:
- Document/file exists
- Qdrant is reachable at the specified URL
- Embedding output is valid JSON
