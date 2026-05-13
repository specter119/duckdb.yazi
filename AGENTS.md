# AGENTS.md

## Scope

All plugin logic lives in `main.lua`. `README.md` is user-facing documentation.
Do not add new files to the repo root.

## Key constraints

- Lua runs inside Yazi's runtime — do not `require` standard Lua libs or add
  external Lua dependencies.
- Any non-empty stderr from `duckdb` is treated as a fatal error and produces a
  blank preview. **Never use the deprecated `->` lambda syntax** in DuckDB
  queries; use `lambda c: ...` (required for DuckDB ≥ 1.5).
- `init.lua` does not live in this repo — users create their own in their Yazi
  config directory. Do not add one here.
- `cache_version` in `get_cache_path()` must be bumped whenever the cached
  output schema changes.
- `.db` files are opened with `duckdb -readonly`; DuckDB transparently reads
  both DuckDB-native and SQLite `.db` files via its built-in SQLite scanner.

## Yazi documentation references

- Plugin API overview: <https://yazi-rs.github.io/docs/plugins/overview>
- Previewers: <https://yazi-rs.github.io/docs/plugins/previewer>
- Preloaders: <https://yazi-rs.github.io/docs/plugins/preloader>
- Utilities (`ya.*`, `fs.*`, `Command`, `Url`, `ui.*`): <https://yazi-rs.github.io/docs/plugins/utils>
- `yazi.toml` plugin configuration: <https://yazi-rs.github.io/docs/configuration/yazi>
- `keymap.toml` reference: <https://yazi-rs.github.io/docs/configuration/keymap>
- Yazi changelog: <https://github.com/sxyazi/yazi/blob/main/CHANGELOG.md>
- Yazi latest release: `gh api repos/sxyazi/yazi/releases/latest --jq '.tag_name'`

## DuckDB documentation references

- CLI dot commands: <https://duckdb.org/docs/stable/clients/cli/dot_commands>
- `SUMMARIZE`: <https://duckdb.org/docs/guides/meta/summarize>
- JSON reader: <https://duckdb.org/docs/data/json/overview>
- `lambda` syntax (DuckDB ≥ 1.5): <https://duckdb.org/docs/sql/functions/lambda>

## Version compatibility

The `-- @since YY.M.D` header at the top of `main.lua` records the minimum
compatible Yazi version. Check this against the installed version whenever the
Yazi API changes.

To check locally:

```bash
yazi --version                                              # installed version
gh api repos/sxyazi/yazi/releases/latest --jq '.tag_name'  # latest release
gh api repos/sxyazi/yazi/releases/latest --jq '.body'      # release notes
```

When Yazi releases a new version, review the changelog for breaking API
changes and update the `@since` header if the minimum version changes. Key
Yazi APIs used by this plugin: `ya.sync`, `ya.sleep`, `ya.emit`, `ya.err`,
`ya.dbg`, `ya.preview_widget`, `ya.file_cache`, `Command`, `Url`, `fs.cha`,
`fs.remove`, `ui.Text.parse`, `cx.active`.

## Commit conventions

```
<type>: <description>
```

Types: `feat`, `fix`, `refactor`, `docs`, `chore`
