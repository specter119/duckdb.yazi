# AGENTS.md — duckdb.yazi

Guidance for AI agents (and human contributors) working on this codebase.

## Repository layout

```
duckdb.yazi/
├── main.lua      # Single-file Lua plugin (~620 lines)
├── README.md     # Installation + config docs
└── AGENTS.md     # This file
```

Everything lives in `main.lua`. There is no build step, test suite, or
external Lua dependencies.

## Runtime environment

- **Language**: Lua, executed by [Yazi](https://github.com/sxyazi/yazi)'s
  built-in Lua runtime (not standalone `lua`/`luajit`).
- **External binary**: `duckdb` CLI must be on `$PATH`.
- **Yazi APIs used**: `ya.*`, `ui.*`, `fs.*`, `Command`, `Url` — all provided
  by Yazi at runtime. Do not attempt to `require` standard Lua libs.

## Architecture overview

`main.lua` exposes a single module `M` with two public entry points:

| Entry point | Trigger | Purpose |
|---|---|---|
| `M:setup(opts)` | `init.lua` at startup | Store user options into shared sync state |
| `M:entry(job)` | Yazi key/preview event | Route to column-scroll, open-in-duckdb, or preview peek |

### Shared sync state

Yazi plugins are multi-async; mutable state is managed through
`ya.sync(function(state, ...) ... end)`. The helper wrappers are:

- `set_opts(key, value)` / `get_opts(key)` — plugin options and runtime state
- `add_to_list / remove_from_list / is_on_list(category, key)` — set-like
  membership (used for `preloading` and `bad_cache` tracking)

### Preview pipeline (`M:peek`)

```
prepare_peek_context(job)
  └─ resolves target (cache file or original), mode, scroll position
       └─ generate_peek_query(target, job, limit, offset, file_type, cache_str)
            ├─ generate_db_query()          — .db / .duckdb files
            ├─ generate_standard_query()    — standard table view
            └─ generate_summarized_query()  — SUMMARIZE view
run_query(job, query, target, file_type)
  └─ spawns `duckdb` CLI, captures stdout/stderr
output_is_valid(output, mode, job)
  └─ treats ANY non-empty stderr as fatal (DuckDB warnings break output)
render_output(output, job)
  └─ ya.preview_widget with ANSI-color-aware text
```

### Caching (`M:preload`)

Preload runs in background and writes two Parquet cache files per file
(standard + summarized).  Cache paths are derived from `ya.file_cache(job)`
with a synthetic `skip = 1_000_000 + cache_version` sentinel.

`cache_version = 3` (line ~258) — bump this when the cached schema changes
to force cache invalidation for all users.

### Column scrolling

`M:entry` receives `+1` / `-1` args from keymap bindings.  It increments
`scrolled_columns` in sync state and calls `ya.emit("seek", {...})` to
trigger a re-peek.  The scroll position is reset to 0 whenever `job.skip`
is 0 (new file selected) or mode is toggled.

## Version compatibility notes

### DuckDB >= 1.5

The lambda syntax changed.  Always use the new form:

```lua
-- CORRECT (DuckDB 1.5+)
"columns(lambda c: list_contains(...))"

-- WRONG — emits a deprecation WARNING to stderr, which output_is_valid()
-- treats as fatal, producing a blank (silent) preview
"columns(c -> list_contains(...))"
```

### Yazi >= 26.x

In `yazi.toml` previewer/preloader rules, use **`mime`** for file types with a
stable MIME type, and **`url`** (glob on filename) for the rest:

```toml
prepend_previewers = [
  { mime = "text/csv",                                                           run = "duckdb" },
  { mime = "text/tab-separated-values",                                          run = "duckdb" },
  { mime = "application/json",                                                   run = "duckdb" },
  { mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", run = "duckdb" },
  { url  = "*.parquet", run = "duckdb" },  -- no standard MIME type
  { url  = "*.txt",     run = "duckdb" },  -- text/plain is too broad
  { url  = "*.db",      run = "duckdb" },  -- no standard MIME type
  { url  = "*.duckdb",  run = "duckdb" },  -- no standard MIME type
]
```

The old `name` key (pre-26.x) is silently ignored — files fall through to raw
text rendering with no error shown to the user.

### Yazi plugin manager

The install command changed:

```sh
# CORRECT
ya pkg add wylie102/duckdb

# OUTDATED
ya pack -a wylie102/duckdb
```

## Making changes

1. **Edit only `main.lua`** for behaviour changes.
2. **Edit only `README.md`** for documentation/config changes.
3. Validate the lambda syntax in any new DuckDB query:  avoid `->` lambdas.
4. Do not add files that Yazi's plugin loader doesn't expect
   (no `init.lua` in the repo — users create their own in their config dir).
5. After changing cached output shape, bump `cache_version` in `get_cache_path`.

## Testing (manual)

There is no automated test suite.  Manual smoke-test checklist:

- [ ] CSV, TSV, JSON, Parquet, XLSX, `.db`, `.duckdb` files all preview
- [ ] Row scrolling (`J`/`K`) and column scrolling (`H`/`L`) work
- [ ] Mode toggle (press `K` at top of file) switches standard ↔ summarized
- [ ] `go` / `gu` keymaps open duckdb CLI / duckdb UI
- [ ] No warnings appear in `yazi --log` output

## Commit conventions

```
<type>: <description>

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
```

Types: `feat`, `fix`, `refactor`, `docs`, `chore`

## Out of scope

- Do not add runtime Lua dependencies.
- Do not add a build system or CI configuration without discussion.
- Do not change the public `setup()` option names without a README update
  and a migration note.
