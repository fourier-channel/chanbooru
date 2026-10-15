#!/usr/bin/env bash
# GATE 3 ACCEPTANCE (fourier-basis docs/design/GATE3_MATRIX_POSTS.md): EXPLAIN
# ANALYZE of every query the brief names, for viewers in 1, 100 and 5,000
# rooms, against the scratch test bed script/perf/gate3_build.sql makes.
#   bash script/perf/gate3_measure.sh [shape]     shape: overlap (default) | or
# overlap: room_ids && ARRAY[0, <viewer's rooms>] -- non-Matrix posts carry {0}
# or:      room_ids = '{0}' OR room_ids && ARRAY[<viewer's rooms>]
set -euo pipefail
SHAPE="${1:-overlap}"
PSQL=(docker compose -f docker-compose.dev.yaml exec -T postgres psql -U danbooru -d danbooru_gate3_perf -At)
declare -A VIEWERS=(
  [1]="SELECT ARRAY[50]"
  [100]="SELECT array_agg(r) FROM generate_series(37, 10000, 100) r"
  [5000]="SELECT array_agg(r) FROM generate_series(2, 10000, 2) r"
)
TAGS='{t2}'          # common (most frequent tag in the bed)
MID='{t300}'         # mid
RARE='{t40000}'      # rare
for n in 1 100 5000; do
  if [ "$SHAPE" = overlap ]; then
    vis="room_ids && (SELECT array_prepend(0, ($(echo "${VIEWERS[$n]}"))))"
  else
    vis="(room_ids = '{0}' OR room_ids && ($(echo "${VIEWERS[$n]}")))"
  fi
  base="FROM posts WHERE NOT is_deleted AND $vis"
  pivot=$("${PSQL[@]}" -c "SELECT max(id) - 500000 FROM posts")
  declare -a Q=(
    "newest|SELECT id $base ORDER BY id DESC LIMIT 20"
    "common tag|SELECT id $base AND string_to_array(tag_string, ' ') @> '$TAGS' ORDER BY id DESC LIMIT 20"
    "mid tag|SELECT id $base AND string_to_array(tag_string, ' ') @> '$MID' ORDER BY id DESC LIMIT 20"
    "rare tag|SELECT id $base AND string_to_array(tag_string, ' ') @> '$RARE' ORDER BY id DESC LIMIT 20"
    "count, rare tag|SELECT count(*) $base AND string_to_array(tag_string, ' ') @> '$RARE'"
    "count, mid tag|SELECT count(*) $base AND string_to_array(tag_string, ' ') @> '$MID'"
    "previous post|SELECT id $base AND id < $pivot ORDER BY id DESC LIMIT 1"
    "next post|SELECT id $base AND id > $pivot ORDER BY id ASC LIMIT 1"
    "post page|SELECT id $base AND id = $pivot"
  )
  for q in "${Q[@]}"; do
    label=${q%%|*}; sql=${q#*|}
    ms=$("${PSQL[@]}" -c "EXPLAIN (ANALYZE, FORMAT JSON) $sql" | python3 -c 'import json,sys; print(round(json.load(sys.stdin)[0]["Execution Time"], 1))')
    printf "%-6s rooms=%-5s %-16s %9s ms\n" "$SHAPE" "$n" "$label" "$ms"
  done
done
