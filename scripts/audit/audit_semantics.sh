#!/usr/bin/env bash
# W2 semantics audit — mechanical pass. READ-ONLY: emits findings, changes nothing.
#
# Check 1 (consume): for every zenoh-c symbol with z_moved_* params that the
#   shim calls, verify the call site wraps each consumed argument in *_move(),
#   and report which Dart wrappers forward ownership (candidate markConsumed
#   sites) for human cross-check.
# Check 2 (rc-discard): z_result_t-returning calls used as bare statements in
#   the shim (result silently discarded — the v0.18.1 bug pattern).
#
# Output: two CSV blocks on stdout, '== CHECK1 ==' / '== CHECK2 ==' delimited.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HDR="$REPO_ROOT/extern/zenoh-c/include/zenoh_commons.h"
SRC="$REPO_ROOT/src/zenoh_dart.c"
DART_DIR="$REPO_ROOT/package/lib/src"

# ---- consuming symbols: name -> consumed param count ------------------------
CONSUMERS="$(awk '
  /ZENOHC_API/ { collecting = 1; buf = "" }
  collecting {
    buf = buf " " $0
    if ($0 ~ /;/) {
      if (buf ~ /(z|zc|ze)_moved_[a-z0-9_]+_t/) {
        sym = buf; sub(/\(.*$/, "", sym); sub(/^.*[ \*]/, "", sym)
        n = gsub(/(z|zc|ze)_moved_[a-z0-9_]+_t/, "&", buf)
        print sym "," n
      }
      collecting = 0
    }
  }' "$HDR" | sort -u)"

echo "== CHECK1: consume sites =="
echo "zd_function,consuming_call,consumed_params,move_wraps_in_body,dart_markConsumed_nearby"
grep -oE '^[A-Za-z_ \*]+zd_[a-z0-9_]+\(' "$SRC" | grep -oE 'zd_[a-z0-9_]+' | sort -u | while read -r fn; do
  body="$(awk -v fn="$fn" '
    !found && $0 ~ "[ \\*]"fn"\\(" && $0 !~ /;[ \t]*$/ { found=1 }
    found { print; n=gsub(/{/,"{"); m=gsub(/}/,"}"); depth+=n-m; if (started && depth<=0) exit; if (n>0) started=1 }' "$SRC")"
  [[ -z $body ]] && continue
  while IFS=, read -r csym ccount; do
    [[ -z $csym ]] && continue
    if grep -qE "\b$csym\(" <<<"$body"; then
      moves="$(grep -oE '(z|zc|ze)_[a-z0-9_]+_move\(' <<<"$body" | wc -l)"
      # Dart: does any wrapper file call bindings.<fn> AND markConsumed in the same file?
      dart="n-a"
      df="$(grep -rl "bindings\.$fn\b" "$DART_DIR" 2>/dev/null | head -1 || true)"
      if [[ -n $df ]]; then
        if grep -q 'markConsumed' "$df"; then dart="yes($(basename "$df"))"; else dart="NO($(basename "$df"))"; fi
      fi
      printf '%s,%s,%s,%s,%s\n' "$fn" "$csym" "$ccount" "$moves" "$dart"
    fi
  done <<<"$CONSUMERS"
done

# ---- result-returning symbols ----------------------------------------------
RESULTS="$(awk '
  /ZENOHC_API/ { collecting = 1; buf = "" }
  collecting {
    buf = buf " " $0
    if ($0 ~ /;/) {
      if (buf ~ /ZENOHC_API[ ]+z_result_t/) {
        sym = buf; sub(/\(.*$/, "", sym); sub(/^.*[ \*]/, "", sym); print sym
      }
      collecting = 0
    }
  }' "$HDR" | sort -u)"

echo "== CHECK2: rc-discarded calls =="
echo "line,call"
while read -r sym; do
  [[ -z $sym ]] && continue
  # bare-statement call: line starts (after indent) with the symbol, and the
  # line does not assign, compare, return, or sit inside an if/while condition.
  grep -nE "^[ \t]+(\(void\) *)?$sym\(" "$SRC" \
    | grep -vE '=[^=]|if *\(|while *\(|return|rc|res' || true
done <<<"$RESULTS" | sed 's/:/,/' | sort -t, -k1,1n
