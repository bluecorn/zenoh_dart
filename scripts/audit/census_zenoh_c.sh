#!/usr/bin/env bash
# W0 oracle script — zenoh-c census (O1 + O2).
#
# Parses:
#   O1: extern/zenoh-c/include/zenoh_commons.h  (cbindgen output — THE C API)
#   O2: extern/zenoh-c/docs/api.rst             (upstream-curated taxonomy)
#
# Emits CSV on stdout:
#   symbol,taxonomy_section,consumed_params,n_params,documented
#
# consumed_params: ;-joined parameter names whose type is z_moved_*_t /
# zc_moved_*_t / ze_moved_*_t — cbindgen mechanically encodes consume
# (z_move) semantics in these types, so this column drives the W2
# move/markConsumed audit.
#
# documented: yes if the symbol appears in api.rst (doxygenfunction),
# no otherwise (header-only symbols are flagged for human triage).
#
# Deterministic; no network. Re-run on a new tag for an upgrade delta.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HDR="$REPO_ROOT/extern/zenoh-c/include/zenoh_commons.h"
RST="$REPO_ROOT/extern/zenoh-c/docs/api.rst"
[[ -f $HDR && -f $RST ]] || { echo "oracles missing — init extern/zenoh-c" >&2; exit 1; }

# --- pass 1: api.rst -> "function section" map -------------------------------
# Section = the most recent line underlined with === or --- (concept level);
# ^^^ sub-headers (Types/Functions) are ignored.
RST_MAP="$(awk '
  { lines[NR] = $0 }
  END {
    section = "UNSECTIONED"
    for (i = 1; i < NR; i++) {
      if (lines[i+1] ~ /^=+$/ || lines[i+1] ~ /^-+$/) {
        # api.rst inconsistently underlines the structural sub-headers
        # (Types/Functions) with --- in places; never treat them as sections.
        if (lines[i] ~ /^[A-Za-z]/ && lines[i] != "Functions" && lines[i] != "Types")
          section = lines[i]
      }
      if (lines[i] ~ /^\.\. doxygenfunction:: /) {
        fn = lines[i]; sub(/^\.\. doxygenfunction:: /, "", fn)
        gsub(/[ \t\r]+$/, "", fn)
        print fn "\t" section
      }
    }
  }' "$RST")"

# --- pass 2: header -> declarations -----------------------------------------
# Join physical lines of each declaration (ZENOHC_API ... ;) then parse.
DECLS="$(awk '
  /ZENOHC_API/ { collecting = 1; buf = "" }
  collecting {
    buf = buf " " $0
    if ($0 ~ /;/) { print buf; collecting = 0 }
  }' "$HDR")"

# --- pass 3: emit CSV ---------------------------------------------------------
echo "symbol,taxonomy_section,consumed_params,n_params,documented"
while IFS= read -r decl; do
  # symbol = identifier immediately before the first '('
  sym="$(sed -E 's/^.*[ \*]([A-Za-z_][A-Za-z0-9_]*)\(.*$/\1/' <<<"$decl")"
  [[ $sym =~ ^(z_|zc_|ze_|zp_)[a-z0-9_]+$ ]] || continue
  params="$(sed -E 's/^[^(]*\((.*)\).*$/\1/' <<<"$decl")"
  n_params=0; consumed=""
  if [[ -n ${params// /} && ${params// /} != "void" ]]; then
    IFS=',' read -ra PA <<<"$params"
    n_params=${#PA[@]}
    for p in "${PA[@]}"; do
      if [[ $p =~ (z|zc|ze)_moved_[a-z0-9_]+_t ]]; then
        pname="$(sed -E 's/^.*[ \*]([A-Za-z_][A-Za-z0-9_]*) *$/\1/' <<<"$p")"
        consumed+="${consumed:+;}${pname}"
      fi
    done
  fi
  section="$(awk -F'\t' -v s="$sym" '$1==s{print $2; exit}' <<<"$RST_MAP")"
  documented=yes
  [[ -z $section ]] && { section="UNDOCUMENTED-IN-API.RST"; documented=no; }
  printf '%s,"%s","%s",%d,%s\n' "$sym" "$section" "$consumed" "$n_params" "$documented"
done <<<"$DECLS" | sort -t, -k2,2 -k1,1
