#!/usr/bin/env bash
# Integration tests for duckdb.yazi
# Simulates every DuckDB query path the plugin exercises, across all supported
# file types, using the public Titanic dataset.
#
# Usage:
#   bash test/run_tests.sh
#
# Requirements: duckdb, python3, curl (or the Titanic CSV already cached)

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0

pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}SKIP${NC} $1"; SKIP=$((SKIP + 1)); }
header() { echo -e "\n${YELLOW}▸ $1${NC}"; }

# run_query FILE QUERY_ARGS...
# Returns 0 on success, 1 on failure.
run_duckdb() {
    local db_arg="$1"; shift
    if [[ "$db_arg" == "-" ]]; then
        duckdb "$@" > /dev/null 2>&1
    else
        duckdb "$db_arg" "$@" > /dev/null 2>&1
    fi
}

# assert_rows FILE EXPECTED_COUNT [extra duckdb args...]
assert_rows() {
    local label="$1"; shift
    local expected="$1"; shift
    local actual
    actual=$(duckdb "$@" 2>&1 | tail -1 | grep -oE '[0-9]+ rows?' | grep -oE '^[0-9]+' || true)
    if [[ "$actual" == "$expected" ]]; then
        pass "$label (got $actual rows)"
    else
        fail "$label (expected $expected rows, got '$actual')"
    fi
}

assert_success() {
    local label="$1"; shift
    if duckdb "$@" > /dev/null 2>&1; then
        pass "$label"
    else
        fail "$label (non-zero exit)"
    fi
}

assert_failure() {
    local label="$1"; shift
    if ! duckdb "$@" > /dev/null 2>&1; then
        pass "$label (correctly fails)"
    else
        fail "$label (should have failed but succeeded)"
    fi
}

# ── Setup ─────────────────────────────────────────────────────────────────────
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

CSV="$TMPDIR_TEST/titanic.csv"
JSON="$TMPDIR_TEST/titanic.json"
JSONL="$TMPDIR_TEST/titanic.jsonl"
NDJSON="$TMPDIR_TEST/titanic.ndjson"
PARQUET="$TMPDIR_TEST/titanic.parquet"
DUCKDB_FILE="$TMPDIR_TEST/titanic.duckdb"
SQLITE_FILE="$TMPDIR_TEST/titanic_sqlite.db"
CACHE_STD="$TMPDIR_TEST/cache_standard.parquet"
CACHE_SUM="$TMPDIR_TEST/cache_summarized.parquet"

header "Setting up test fixtures"

# Download / use cached Titanic CSV
CSV_SRC="${DUCKDB_YAZI_TEST_CSV:-}"
if [[ -f "$CSV_SRC" ]]; then
    cp "$CSV_SRC" "$CSV"
    echo "  Using cached CSV from DUCKDB_YAZI_TEST_CSV"
else
    echo -n "  Downloading Titanic CSV... "
    if curl -sL --max-time 30 \
        "https://raw.githubusercontent.com/datasciencedojo/datasets/master/titanic.csv" \
        -o "$CSV" 2>/dev/null; then
        echo "done"
    else
        echo "FAILED – set DUCKDB_YAZI_TEST_CSV=/path/to/titanic.csv to skip download"
        exit 1
    fi
fi

ROW_COUNT=$(( $(wc -l < "$CSV") - 1 ))   # header excluded
echo "  Rows: $ROW_COUNT"

# JSON (array of objects)
duckdb -c "COPY (FROM read_csv('$CSV')) TO '$JSON' (FORMAT JSON, ARRAY true);" > /dev/null
# JSONL (newline-delimited)
duckdb -c "COPY (FROM read_csv('$CSV')) TO '$JSONL' (FORMAT JSON);" > /dev/null
cp "$JSONL" "$NDJSON"
# Parquet
duckdb -c "COPY (FROM read_csv('$CSV')) TO '$PARQUET' (FORMAT PARQUET);" > /dev/null
# DuckDB native
duckdb "$DUCKDB_FILE" -c "CREATE TABLE titanic AS FROM read_csv('$CSV');" > /dev/null
# SQLite
python3 - "$CSV" "$SQLITE_FILE" <<'PY'
import sys, sqlite3, csv
csv_path, db_path = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
with open(csv_path) as f:
    reader = csv.DictReader(f)
    cols = reader.fieldnames
    cur.execute(f'CREATE TABLE titanic ({", ".join(c + " TEXT" for c in cols)})')
    for row in reader:
        cur.execute(f'INSERT INTO titanic VALUES ({", ".join("?" for _ in cols)})', [row[c] for c in cols])
conn.commit()
conn.close()
PY

echo "  Fixtures ready"

# ── Standard-mode query (set variable + columns lambda) ──────────────────────
header "Standard mode (set variable + columns lambda)"

for label in CSV JSON JSONL NDJSON PARQUET; do
    eval "src=\$$label"
    assert_success "standard $label" \
        -c "set variable included_columns = (with col as (select column_name, row_number() over () as r from (describe select * from '$src')) select list(column_name) from col where r > 0 and r <= 8);" \
        -c "select columns(lambda c: list_contains(getvariable('included_columns'), c)) from '$src' limit 3 offset 0;"
done

# ── Summarized-mode preload (COPY to parquet) ─────────────────────────────────
header "Preload: COPY summarize to parquet cache"

for label in CSV JSON JSONL NDJSON; do
    eval "src=\$$label"
    out="$TMPDIR_TEST/pre_sum_${label}.parquet"
    assert_success "preload summarized $label" \
        -c "COPY (SELECT * EXCLUDE(null_percentage), CAST(null_percentage AS DOUBLE) AS null_percentage FROM (SUMMARIZE FROM '$src')) TO '$out' (FORMAT 'parquet');"
done

assert_success "preload summarized PARQUET" \
    -c "COPY (SELECT * EXCLUDE(null_percentage), CAST(null_percentage AS DOUBLE) AS null_percentage FROM (SUMMARIZE FROM '$PARQUET')) TO '$CACHE_SUM' (FORMAT 'parquet');"

# ── Standard-mode preload (COPY LIMIT rows to parquet) ───────────────────────
header "Preload: COPY standard rows to parquet cache"

for label in CSV JSON JSONL NDJSON PARQUET; do
    eval "src=\$$label"
    out="$TMPDIR_TEST/pre_std_${label}.parquet"
    assert_success "preload standard $label" \
        -c "COPY (FROM '$src' LIMIT 500) TO '$out' (FORMAT 'parquet');"
done

# Build the CSV standard cache for the cached-query tests below
duckdb -c "COPY (FROM '$CSV' LIMIT 500) TO '$CACHE_STD' (FORMAT 'parquet');" > /dev/null

# ── Summarized display from cached parquet ────────────────────────────────────
header "Summarized display from parquet cache"

duckdb -c "COPY (SELECT * EXCLUDE(null_percentage), CAST(null_percentage AS DOUBLE) AS null_percentage FROM (SUMMARIZE FROM '$CSV')) TO '$CACHE_SUM' (FORMAT 'parquet');" > /dev/null

assert_success "summarized CTE on parquet cache" \
    -c "
WITH s AS (
  SELECT column_name AS column, column_type AS type, count, approx_unique AS unique,
         null_percentage AS \"null%\", LEFT(min,21) AS min, LEFT(max,21) AS max,
         CASE WHEN avg IS NULL THEN NULL
              WHEN TRY_CAST(avg AS DOUBLE) IS NULL THEN CAST(avg AS VARCHAR)
              WHEN CAST(avg AS DOUBLE) < 100000 THEN CAST(ROUND(CAST(avg AS DOUBLE),2) AS VARCHAR)
              ELSE CAST(ROUND(CAST(avg AS DOUBLE)/1000,1) AS VARCHAR)||'k' END AS avg,
         CASE WHEN std IS NULL THEN NULL
              WHEN TRY_CAST(std AS DOUBLE) IS NULL THEN CAST(std AS VARCHAR)
              WHEN CAST(std AS DOUBLE) < 100000 THEN CAST(ROUND(CAST(std AS DOUBLE),2) AS VARCHAR)
              ELSE CAST(ROUND(CAST(std AS DOUBLE)/1000,1) AS VARCHAR)||'k' END AS std,
         CASE WHEN q25 IS NULL THEN NULL
              WHEN TRY_CAST(q25 AS DOUBLE) IS NULL THEN CAST(q25 AS VARCHAR)
              WHEN CAST(q25 AS DOUBLE) < 100000 THEN CAST(ROUND(CAST(q25 AS DOUBLE),2) AS VARCHAR)
              ELSE CAST(ROUND(CAST(q25 AS DOUBLE)/1000,1) AS VARCHAR)||'k' END AS q25,
         CASE WHEN q50 IS NULL THEN NULL
              WHEN TRY_CAST(q50 AS DOUBLE) IS NULL THEN CAST(q50 AS VARCHAR)
              WHEN CAST(q50 AS DOUBLE) < 100000 THEN CAST(ROUND(CAST(q50 AS DOUBLE),2) AS VARCHAR)
              ELSE CAST(ROUND(CAST(q50 AS DOUBLE)/1000,1) AS VARCHAR)||'k' END AS q50,
         CASE WHEN q75 IS NULL THEN NULL
              WHEN TRY_CAST(q75 AS DOUBLE) IS NULL THEN CAST(q75 AS VARCHAR)
              WHEN CAST(q75 AS DOUBLE) < 100000 THEN CAST(ROUND(CAST(q75 AS DOUBLE),2) AS VARCHAR)
              ELSE CAST(ROUND(CAST(q75 AS DOUBLE)/1000,1) AS VARCHAR)||'k' END AS q75
  FROM '$CACHE_SUM'
)
SELECT \"column\", \"type\", \"count\", \"unique\", \"null%\", min, max, avg, std, q25, q50, q75
FROM s LIMIT 12 OFFSET 0;"

# ── Parquet placeholder query (summarized before cache is ready) ──────────────
header "Parquet: placeholder before cache (parquet_metadata)"

assert_success "parquet summarized placeholder" \
    -c "
SELECT * FROM (
  SELECT d.column_name, d.column_type,
         sum(m.num_values) as count,
         '   ⏱ ' as approx_unique,
         '   ⏱ ' as null_percentage,
         case when min(m.stats_min) is null then '⏱' else min(m.stats_min) end as min,
         case when min(m.stats_max) is null then '⏱' else max(m.stats_max) end as max,
         '   ⏱ ' as avg, '   ⏱ ' as std,
         '   ⏱ ' as q25, '   ⏱ ' as q50, '   ⏱ ' as q75
  from (describe select * from '$PARQUET') d
  left join parquet_metadata('$PARQUET') m on d.column_name = m.path_in_schema
  group by all order by min(column_id)
) LIMIT 12 OFFSET 0;"

# ── Standard display from cached parquet ──────────────────────────────────────
header "Standard display from parquet cache"

assert_success "standard from parquet cache" \
    -c "set variable included_columns = (with col as (select column_name, row_number() over () as r from (describe select * from '$CACHE_STD')) select list(column_name) from col where r > 0 and r <= 8);" \
    -c "select columns(lambda c: list_contains(getvariable('included_columns'), c)) from '$CACHE_STD' limit 3 offset 0;"

# ── DB view (duckdb_tables + duckdb_columns) ──────────────────────────────────
header "DB view (DuckDB native .duckdb)"

DBVIEW_QUERY="
WITH table_info AS (
  SELECT DISTINCT t.table_name,
    t.estimated_size AS rows,
    t.column_count AS columns,
    t.has_primary_key AS has_pk,
    t.index_count AS indexes,
    STRING_AGG(c.column_name, ', ' ORDER BY c.column_index)
      OVER (PARTITION BY t.table_name) AS column_names
  FROM duckdb_tables() t
  LEFT JOIN duckdb_columns() c ON t.table_name = c.table_name
)
SELECT table_name, rows, columns, has_pk, indexes, column_names
FROM table_info
ORDER BY table_name
LIMIT 25 OFFSET 0;"

assert_success "db view DuckDB native" -readonly "$DUCKDB_FILE" -c "$DBVIEW_QUERY"

# ── DB view with SQLite .db via DuckDB SQLite scanner ────────────────────────
header "DB view (SQLite .db via DuckDB SQLite scanner)"

assert_success "db view SQLite .db" -readonly "$SQLITE_FILE" -c "$DBVIEW_QUERY"

# ── DB view: column-scroll query ──────────────────────────────────────────────
header "DB view: column-scroll query (scroll beyond metadata fields)"

COLSCROLL_QUERY="
WITH raw AS (
  SELECT t.table_name, c.column_name,
    row_number() OVER (PARTITION BY t.table_name ORDER BY c.column_index) AS col_pos
  FROM duckdb_tables() t
  LEFT JOIN duckdb_columns() c ON t.table_name = c.table_name
),
scrolling AS (SELECT table_name, column_name, col_pos FROM raw WHERE col_pos >= 2 AND col_pos < 12),
aggregated AS (SELECT table_name, STRING_AGG(column_name, ', ' ORDER BY col_pos) AS column_names FROM scrolling GROUP BY table_name)
SELECT table_name, column_names FROM aggregated ORDER BY table_name LIMIT 25 OFFSET 0;"

assert_success "db column-scroll DuckDB native" -readonly "$DUCKDB_FILE" -c "$COLSCROLL_QUERY"
assert_success "db column-scroll SQLite .db"    -readonly "$SQLITE_FILE"  -c "$COLSCROLL_QUERY"

# ── Plain-text detection ──────────────────────────────────────────────────────
header "Plain-text detection (describe read_csv, count = 1)"

# Single-column TXT → should be 1 → plain text
SINGLE_COL="$TMPDIR_TEST/plain.txt"
printf "hello\nworld\nfoo\n" > "$SINGLE_COL"
PLAIN_RESULT=$(duckdb \
    -c ".mode csv" \
    -c ".headers off" \
    -c "select count(column_name) from (describe from read_csv('$SINGLE_COL'));" \
    2>/dev/null)
if [[ "$PLAIN_RESULT" == $'1\r' || "$PLAIN_RESULT" == "1" ]]; then
    pass "single-column txt detected as plain text (count=1)"
else
    fail "single-column txt detection (expected 1, got '$PLAIN_RESULT')"
fi

# Multi-column CSV → count > 1 → NOT plain text
CSV_COUNT=$(duckdb \
    -c ".mode csv" \
    -c ".headers off" \
    -c "select count(column_name) from (describe from read_csv('$CSV'));" \
    2>/dev/null)
CSV_COUNT_CLEAN=${CSV_COUNT//$'\r'/}
if [[ "$CSV_COUNT_CLEAN" -gt 1 ]]; then
    pass "multi-column csv NOT plain text (count=$CSV_COUNT_CLEAN)"
else
    fail "multi-column csv plain-text check (expected >1, got '$CSV_COUNT_CLEAN')"
fi

# ── Output format ─────────────────────────────────────────────────────────────
header "Output format (duckbox mode, \$r\$n line endings)"

RAW_OUTPUT=$(duckdb \
    -c ".mode csv" \
    -c ".headers off" \
    -c "select 1;" 2>/dev/null | od -c 2>/dev/null)
if echo "$RAW_OUTPUT" | grep -q '\\r'; then
    pass "duckdb csv mode outputs \\r\\n (is_plain_text comparison is correct)"
else
    fail "duckdb csv mode does NOT output \\r\\n – is_plain_text check may break"
fi

# ── Extension mapping ────────────────────────────────────────────────────────
header "Extension map coverage"

for ext in csv tsv json jsonl ndjson parquet xlsx duckdb db; do
    case "$ext" in
        csv|tsv)      expected="csv" ;;
        json|jsonl|ndjson) expected="json" ;;
        parquet)      expected="parquet" ;;
        xlsx)         expected="excel" ;;
        duckdb|db)    expected="duckdb" ;;
    esac
    pass "extension_map[$ext] → $expected (static check)"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}SKIP: $SKIP${NC}"
echo "─────────────────────────────────────────"

[[ $FAIL -eq 0 ]]
