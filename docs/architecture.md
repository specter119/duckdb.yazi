# Architecture

This document describes the internal structure of `main.lua` for contributors
and AI agents working on the plugin. It is intentionally brief — read the code
alongside this document.

---

## 1. Plugin lifecycle

Yazi calls three entry points for each file the user hovers over:

```
preload(job)  →  runs in background, builds the parquet cache
peek(job)     →  renders the preview panel (called repeatedly on scroll)
seek(job)     →  translates scroll events into peek() calls
entry(job)    →  handles keymap actions (column scroll, open in duckdb)
```

`preload` and `peek` run concurrently. The plugin coordinates them through a
shared state machine (see §3).

---

## 2. Query routing

Every preview goes through this decision tree:

```
peek(job)
│
├── is_plain_text? (single-column .txt detected via read_csv count)
│   └── delegate to built-in `code` previewer
│
├── file_type == "duckdb"?  (includes SQLite .db via DuckDB's SQLite scanner)
│   └── generate_db_query()  →  duckdb_tables() + duckdb_columns()
│
├── cache ready? (parquet cache exists and not preloading/bad)
│   └── target = cache_url  →  query the parquet cache
│
└── cache not ready
    ├── mode == "standard"   →  generate_standard_query()  (original file)
    └── mode == "summarized" →  show placeholder, wait for cache, re-peek
```

### Mode selection

| Mode | Query generator | Data source |
|------|----------------|-------------|
| `standard` | `generate_standard_query` | paginated `FROM file LIMIT n OFFSET m` via `columns(lambda …)` |
| `summarized` | `generate_summarized_query` | `SUMMARIZE FROM file` wrapped in a formatting CTE |
| `db-view` | `generate_db_query` | `duckdb_tables()` + `duckdb_columns()` system functions |

Mode is toggled by `seek()` when the user scrolls past the top of the file.

### Column scrolling

Both `standard` and `summarized` modes support horizontal column scrolling via
the `scrolled_columns` state variable. Scrolling is also supported in `db-view`
(scrolls through metadata fields, then through column name lists).

---

## 3. Cache state machine

The plugin maintains four boolean sets in Yazi's shared state:

| Set | Set by | Cleared by | Meaning |
|-----|--------|------------|---------|
| `preloading` | `create_cache` start | `finish_preload` | Cache write is in progress |
| `completed` | `finish_preload` | `peek` after waiting | Cache write has finished |
| `bad_cache` | `finish_preload` (on error), `peek` (on read error) | never | Cache is corrupt; fall back to original file |
| `is_plain_text` | `is_plain_text()` | never | File is single-column .txt; bypass DuckDB |

### Typical flow for a non-parquet file (e.g., CSV)

```
preload:  add "preloading"
          run SUMMARIZE → COPY to cache.parquet
          remove "preloading", add "completed"

peek (while preloading):
          use_cache = false  (preloading flag set)
          run SUMMARIZE on original file → show placeholder
          wait until "completed" is set
          clear "completed", set re_peek = true
          re-peek → now cache exists → use_cache = true → show from cache

peek (after cache ready):
          use_cache = true
          query cache.parquet → render
```

### Parquet files skip the wait

For `.parquet` files, `peek` uses `parquet_metadata()` for fast preliminary
statistics even before the cache is ready, so no placeholder wait is needed.

---

## 4. Cache file layout

Cache paths are derived from Yazi's `ya.file_cache(job)` with a version salt:

```
<yazi_cache_dir>/<content_hash>_standard.parquet
<yazi_cache_dir>/<content_hash>_summarized.parquet
```

The version salt (`cache_version = 3` in `get_cache_path`) must be incremented
whenever the cached schema changes, so stale caches are automatically ignored.

---

## 5. File type detection

`check_file_type(url)` maps the file extension to an internal type token:

| Extensions | Token | DuckDB data source |
|------------|-------|--------------------|
| `.csv`, `.tsv` | `csv` | bare path (DuckDB auto-detects) |
| `.json`, `.jsonl`, `.ndjson` | `json` | bare path (auto-detects array vs. NDJSON) |
| `.parquet` | `parquet` | bare path |
| `.xlsx` | `excel` | `st_read(path)` via spatial extension |
| `.duckdb`, `.db` | `duckdb` | `duckdb -readonly path` |
| `.txt` | `text` | `read_csv(path)` (then plain-text check) |

When target is a parquet cache, the type is always `"cache"` which also uses
a bare path, letting DuckDB auto-detect parquet format.
