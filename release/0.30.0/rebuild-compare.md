# S5 — rebuild-and-compare, `0.30.0`

> **Where the cited tools live.** `native_manifest.py` and the stage runners are committed in the private development
> repository, `bluecorn/zenoh_dart_dev`, on `release-record/0.30.0` (`development/release/0.30.0/`); this repository does not
> carry that tree.

**Stage:** S5 of `development/release/release-procedure.md` (A2; P28). ⭐ **RUN IN FULL**, run by CB on 2026-09-16.
**Object:** **N = `fd73f75dd7aca25e50efc54c88c8c1d13f789fc6`**, the natives commit on this branch, built from **A = `673e669`**
(dev E = `8fb1a3b`).

**Why in full, rather than discharged:** this is a release's first pass, so every stage runs in full by default — A2a governs
fix iterations inside a release and has no anchor here. And A2a's own anti-chaining sentence points the same way: the previous
release's last iteration discharged its S5, so *"the next one rebuilds"*. It cost twenty minutes.

## How

A **fresh clone of N** into a root of **50 characters** — a length no earlier build of these libraries has used (45 at this
release's S4; 49, 51, 55, 60, 61, 62 at the candidate's six). ⛔ **Every `.so` was deleted before the rebuild started**, so a
library that failed to build could not survive as a stale copy and compare equal to itself; the emptied tree is recorded in
`s5-clear.log`. Then the submodule, both Linux presets, `scripts/build_zenoh_android.sh`, and
`scripts/check_native_pins.sh --all-shipped`. Rebuild time **20 min 29 s** (08:53:40–09:14:12 UTC).

## The comparison — three mechanisms, and they must agree

| # | mechanism | reading |
|---|---|---|
| 1 | `native_manifest.py check --manifest <N's manifest>` in the rebuild clone — re-reads every library from disk, every field | **16 of 16 `OK`** · *"all 16 libraries equal the manifest"* |
| 2 | `sha256sum` over every `.so` in each tree, independently, the two listings `diff`ed | **16 lines each, diff empty** |
| 3 | `cmp` byte-for-byte, file by file | **16 identical, 0 differ** |

⭐ **Three mechanisms, three agreements.** Mechanism 1 goes through the manifest's recorded fields; 2 and 3 never read the
manifest at all, so a fault in it cannot make them agree.

**Cumulatively:** these sixteen libraries have now been produced **eight** times on this host — six across the candidate's four
iterations, plus this release's S4 and S5 — from eight clones at eight root lengths, with the same aggregate every time:
`7255a8212c95f99546c7fe9d5476ee76dc33705bf8177c66c062c24eea098e1f`.

## What this does not establish

- **A second host.** Same machine, same toolchain installation — roadmap R30, a `1.0.0` row.
- **A build without network or warm caches.** Cargo used this host's registry and git caches — roadmap R28, a `1.0.0` row.
