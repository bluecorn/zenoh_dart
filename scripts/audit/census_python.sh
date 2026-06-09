#!/usr/bin/env bash
# W0 oracle script — zenoh-python census (O8) from its .pyi type stubs.
#
# Fetches the stubs at the pinned tag into build/audit/zenoh-python-<TAG>/
# (cached; gitignored) and emits CSV: stub,kind,name,member
#   kind = class|def ; member = method name within a class ("" for
#   module-level defs and the class's own row).
#
# Network: one gh fetch per stub on first run (pinned ref), cache after.
set -euo pipefail

TAG="${1:-1.7.2}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="$REPO_ROOT/build/audit/zenoh-python-$TAG"
STUBS=(zenoh/__init__.pyi zenoh/ext.pyi zenoh/handlers.pyi zenoh/shm.pyi)

mkdir -p "$CACHE"
for s in "${STUBS[@]}"; do
  out="$CACHE/$(basename "$s")"
  if [[ ! -s $out ]]; then
    gh api "repos/eclipse-zenoh/zenoh-python/contents/$s?ref=$TAG" --jq '.content' \
      | tr -d '\n' | base64 -d > "$out"
  fi
done

echo "stub,kind,name,member"
for s in "${STUBS[@]}"; do
  b="$(basename "$s")"
  awk -v stub="$b" '
    /^class [A-Za-z_]/ {
      name = $2; sub(/[:\(].*/, "", name)
      if (name !~ /^_/) { current = name; printf "%s,class,%s,\n", stub, name }
      else current = ""
      next
    }
    /^def [a-z_]/ {
      fn = $2; sub(/\(.*/, "", fn)
      if (fn !~ /^_/) printf "%s,def,%s,\n", stub, fn
      next
    }
    current != "" && /^    (def |@property|@staticmethod|@classmethod)/ {
      if (match($0, /def ([a-zA-Z_][a-zA-Z0-9_]*)/, m) && m[1] !~ /^_/)
        printf "%s,class,%s,%s\n", stub, current, m[1]
    }
  ' "$CACHE/$b"
done | sort -u
