#!/usr/bin/env bash
# W0 oracle script — shim cross-reference.
#
# For every zd_* export in src/zenoh_dart.h:
#   zd_symbol,dart_called,z_calls
# where z_calls is the ;-joined set of z_/zc_/ze_ symbols invoked in the
# function body (brace-matched in zenoh_dart.c) and dart_called is yes/no
# per `bindings.<zd_symbol>` usage in package/lib/src/*.dart.
#
# Also emits (to FD 3 if redirected, else suppressed) a reverse index
#   z_symbol -> zd wrappers
# used to pre-fill the master matrix "shim" column:
#   ./census_shim.sh 3>reverse_index.csv
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HDR="$REPO_ROOT/src/zenoh_dart.h"
SRC="$REPO_ROOT/src/zenoh_dart.c"
DART_DIR="$REPO_ROOT/package/lib/src"

exports="$(grep -hoE 'zd_[a-z0-9_]+' "$HDR" | sort -u)"

echo "zd_symbol,dart_called,z_calls"
declare -A REV
for fn in $exports; do
  # function body: from the definition line (name followed by '(' and not ';'
  # on the prototype) to the matching closing brace at depth 0.
  body="$(awk -v fn="$fn" '
    !found && $0 ~ fn"\\(" && $0 !~ /;[ \t]*$/ { found=1 }
    found {
      print
      n = gsub(/{/, "{"); m = gsub(/}/, "}")
      depth += n - m
      if (started && depth <= 0) exit
      if (n > 0) started = 1
    }' "$SRC")"
  zcalls="$(grep -oE '\b(z|zc|ze)_[a-z0-9_]+\(' <<<"$body" \
            | sed 's/($//; s/(//' | sort -u | grep -vE '^(z|zc|ze)_moved' | paste -sd';' -)" || zcalls=""
  if grep -rq "\b$fn\b" "$DART_DIR" --include="*.dart" --exclude="bindings.dart"; then dart=yes; else dart=no; fi
  printf '%s,%s,"%s"\n' "$fn" "$dart" "$zcalls"
  IFS=';' read -ra ZC <<<"$zcalls"
  for z in "${ZC[@]:-}"; do [[ -n $z ]] && REV[$z]+="${REV[$z]:+;}$fn"; done
done

# reverse index on FD 3 when the caller opened it
if { true >&3; } 2>/dev/null; then
  echo "z_symbol,zd_wrappers" >&3
  for z in "${!REV[@]}"; do printf '%s,"%s"\n' "$z" "${REV[$z]}"; done | sort >&3
fi
