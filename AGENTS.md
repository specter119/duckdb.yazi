# AGENTS.md

## Project scope

This is a **Yazi previewer/preloader plugin** that uses the DuckDB CLI to
preview data files directly inside the Yazi file manager. The scope is:

- Previewing tabular data files (CSV, TSV, JSON, JSONL/NDJSON, Parquet, Excel)
  in two modes: *standard* (raw rows) and *summarized* (column statistics)
- Previewing DuckDB databases and SQLite `.db` files (table list with metadata)
- Horizontal/vertical scrolling of the preview within Yazi
- Caching preview output for performance
- Opening files in the DuckDB CLI or DuckDB UI from within Yazi

Out of scope: modifying DuckDB itself, supporting non-tabular file formats,
providing a standalone CLI tool.

## Development conventions

### Lua runtime constraints
- The plugin runs inside **Yazi's Lua runtime** — do not `require` standard Lua
  libraries or add external Lua dependencies. Only Yazi-provided globals are
  available (`ya.*`, `fs.*`, `Command`, `Url`, `ui.*`, `cx.*`).
- `init.lua` does **not** live in this repo — users create their own. Do not
  add one here.

### DuckDB query conventions
- Always use `lambda c: ...` syntax for lambda expressions (DuckDB ≥ 1.5).
  Never use the deprecated `->` shorthand.
- Any non-empty `stderr` from the DuckDB process is treated as a fatal error.
  Test queries manually with `duckdb -c "..."` before embedding them.
- Use `.mode duckbox` for display output and `.mode csv`/`.headers off` for
  machine-readable output within the plugin.

### File layout
- All plugin logic lives in `main.lua`.
- `README.md` is user-facing documentation; keep it in sync with supported
  file types and configuration options.
- `test/run_tests.sh` is the integration test suite — run it after changes.
- Do not add new files to the repo root.

### Testing
Run `bash test/run_tests.sh` after every non-trivial change. The suite covers
all supported file types and query modes using the public Titanic dataset.
Set `DUCKDB_YAZI_TEST_CSV=/path/to/titanic.csv` to skip the download.

## API and SDK references

### Yazi plugin API
- Overview: <https://yazi-rs.github.io/docs/plugins/overview>
- Previewer contract: <https://yazi-rs.github.io/docs/plugins/previewer>
- Preloader contract: <https://yazi-rs.github.io/docs/plugins/preloader>
- Utilities (`ya.*`, `fs.*`, `Command`, `Url`, `ui.*`): <https://yazi-rs.github.io/docs/plugins/utils>
- `yazi.toml` configuration: <https://yazi-rs.github.io/docs/configuration/yazi>
- `keymap.toml` reference: <https://yazi-rs.github.io/docs/configuration/keymap>
- Changelog: <https://github.com/sxyazi/yazi/blob/main/CHANGELOG.md>

### DuckDB CLI
- Dot commands (`.mode`, `.maxwidth`, etc.): <https://duckdb.org/docs/stable/clients/cli/dot_commands>
- `SUMMARIZE`: <https://duckdb.org/docs/guides/meta/summarize>
- JSON reader (auto-detects array vs. NDJSON): <https://duckdb.org/docs/data/json/overview>
- `lambda` syntax: <https://duckdb.org/docs/sql/functions/lambda>
- `parquet_metadata()`: <https://duckdb.org/docs/data/parquet/metadata>

## Version compatibility

The `-- @since YY.M.D` header in `main.lua` records the minimum compatible
Yazi version. When Yazi ships a new release, check the changelog for breaking
API changes and update the header if needed.

```bash
yazi --version                                              # installed version
gh api repos/sxyazi/yazi/releases/latest --jq '.tag_name'  # latest upstream
gh api repos/sxyazi/yazi/releases/latest --jq '.body'      # release notes
```

## Commit conventions

```
<type>: <description>
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`

