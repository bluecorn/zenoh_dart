# S5 — rebuild-and-compare, `1.0.0-rc.1`, iteration 4 — DISCHARGED under A2a

> **Where the cited tools live.** `native_manifest.py` and the stage scripts are committed in the private development repository,
> `bluecorn/zenoh_dart_dev`, on `release-record/1.0.0-rc.1` (`iteration-4/runners/`); this repository does not carry that tree.

**Stage:** S5 of `development/release/release-procedure.md` (A2; P28). **Not run as a separate rebuild in this iteration:
discharged by A2a's S5 row**, whose four conditions all hold and are recorded here, run by CB on 2026-09-15.
**Object:** **N = `88a7314bb2e9e1d10642a895773b70944832ae26`**, the natives commit on this branch, built from
**A = `b96458b`** (dev E = `036c8e1`).

## The discharge conditions, each read

| condition (A2a, S5) | instrument | reading |
|---|---|---|
| the build-input path diff from the anchor iteration's E is empty | `git diff --quiet 215c3bb 036c8e1 -- <path>` over `src`, `CMakeLists.txt`, `CMakePresets.json`, `build-pins`, `scripts`, `.fvmrc`; the gitlink by `git ls-tree` on both | **exit 0 for every path; the gitlink `7b847861…` on both.** Control: the same test over `CHANGELOG.md` → exit 1 |
| S4's comparison reads all 16 libraries equal to the anchor iteration's N | `native_manifest.py check --manifest <iteration 3's N manifest>` in this build clone, after this manifest was written; the two `aggregate_sha256` values | **16 of 16 `OK`**, *"all 16 libraries equal the manifest"*; aggregates **equal** (`7255a8212c95f99546c7fe9d5476ee76dc33705bf8177c66c062c24eea098e1f`). Second mechanism: the sixteen manifest entries compared field-for-field → **0 differ**; of the once-fields only `source_commit` and `dev_commit` differ |
| the anchor iteration's own S5 ran in full | iteration 3's `rebuild-compare.md` (this path at `50b60c5` on its branch; preserved in dev at `iteration-3/public/`) | **it did** — a fresh clone of its N at a 62-character root, every library rebuilt, 16 of 16 byte-identical by three mechanisms |
| the new build root is at a path length different from every earlier root | `printf '%s' "$PWD" \| awk '{print length}'` in the S4 runner's head step | **61** — against 49, 51, 55, 60 and 62 for the five earlier roots |

## What the discharge rests on, stated

**S4 itself was a clean rebuild of the same inputs** — in a sixth fresh clone, at a sixth commit and a sixth path length, on a host
under a different load than iteration 3's (a game at about 270% CPU throughout; one-minute load 0.73–9.25 over 20 samples) — **and
it reproduced iteration 3's sixteen libraries byte for byte.** That is the reading a separate S5 rebuild would produce, taken once
rather than twice. **Discharge cannot chain:** iteration 3's S5 ran in full, so it anchors this discharge; **this iteration's S5 did
not run in full, so it cannot anchor the next iteration's** — the next one rebuilds.

**Across the candidate's four iterations,** these sixteen libraries have now been produced six times on this host — iteration 1's
build and rebuild, iteration 2's build, iteration 3's build and rebuild, iteration 4's build — from six clones at six path
lengths, with the same sha256 for every library each time (aggregate `7255a821…`, the manifest's).

## What this does not establish

- **A second host.** Same machine, same toolchain installation — roadmap R30, a `1.0.0` row.
- **A build without network or warm caches.** Cargo used this host's registry and git caches — roadmap R28, a `1.0.0` row.
