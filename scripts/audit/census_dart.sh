#!/usr/bin/env bash
# W0 oracle script — Dart public-surface census.
#
# Emits CSV: kind,name,member
#   kind   = class|enum
#   member = public method/getter/setter/factory/field name ("" on the
#            type's own row)
#
# Regex-approximation (no analyzer dependency) — adequate for presence
# columns; W1 humans consult the source for anything ambiguous.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DART_DIR="$REPO_ROOT/package/lib/src"

echo "kind,name,member"
for f in "$DART_DIR"/*.dart; do
  [[ $(basename "$f") == bindings.dart ]] && continue
  awk '
    /^class [A-Z]/ || /^enum [A-Z]/ {
      kind = $1; name = $2; sub(/[<{(].*/, "", name)
      if (name !~ /^_/) { current = name; printf "%s,%s,\n", kind, name }
      else current = ""
      next
    }
    current != "" {
      # public members: methods, getters/setters, factories, final fields
      if (match($0, /^  (static )?(final |const )?[A-Za-z_][A-Za-z0-9_<>,\? ]*[ \t]+(get |set )?([a-z][A-Za-z0-9_]*)[ \t]*[({=;]/, m)) {
        if (m[4] !~ /^_/) printf "%s,%s,%s\n", kind, current, m[4]
      }
      else if (match($0, /^  factory ([A-Z][A-Za-z0-9_]*)\.?([a-zA-Z0-9_]*)/, m)) {
        printf "%s,%s,factory:%s\n", kind, current, (m[2] != "" ? m[2] : "unnamed")
      }
    }
  ' "$f"
done | sort -u
