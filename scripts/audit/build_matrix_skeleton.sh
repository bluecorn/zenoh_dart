#!/usr/bin/env bash
# W0 — assemble the master census-matrix SKELETON (W1's input).
#
# One row per zenoh-c symbol (the denominator), pre-filled with every
# mechanically derivable column; human-judgment columns left blank:
#
#   symbol,taxonomy_section,consumed_params,documented,
#   shim_wrappers,dart_called,            <- prefilled from census_shim
#   cpp,kotlin,python,rfc_stage,          <- HUMAN (consult inventories)
#   disposition,evidence                  <- HUMAN
#
# Usage: ./build_matrix_skeleton.sh > ../../development/reference/zenoh-api-census-1.7.2-skeleton.csv
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$HERE/census_zenoh_c.sh" > "$TMP/zc.csv"
"$HERE/census_shim.sh" 3>"$TMP/rev.csv" > "$TMP/shim.csv"

echo "symbol,taxonomy_section,consumed_params,documented,shim_wrappers,dart_called,cpp,kotlin,python,rfc_stage,disposition,evidence"
tail -n +2 "$TMP/zc.csv" | while IFS= read -r line; do
  sym="${line%%,*}"
  rest="${line#*,}"
  wrappers="$(awk -F'^"|","|"$' -v s="$sym" 'BEGIN{FS=","} $1==s{gsub(/"/,"",$2); print $2; exit}' "$TMP/rev.csv")" || wrappers=""
  dart=no
  if [[ -n $wrappers ]]; then
    IFS=';' read -ra W <<<"$wrappers"
    for w in "${W[@]}"; do
      if awk -F, -v z="$w" '$1==z && $2=="yes"{found=1} END{exit !found}' "$TMP/shim.csv"; then dart=yes; break; fi
    done
  fi
  printf '%s,%s,"%s",%s,,,,,\n' "$sym" "$rest" "$wrappers" "$dart"
done
