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

## Commit conventions

```
<type>: <description>
```

Types: `feat`, `fix`, `refactor`, `docs`, `chore`
