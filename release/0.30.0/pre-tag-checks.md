# S8 — the pre-tag checks, `0.30.0`

**Stage:** S8 of `development/release/release-procedure.md` (A2; P09, P40–P47), run by CB on 2026-09-16 **in a fresh clone of
the pushed branch** — `git clone --branch release/0.30.0 https://github.com/bluecorn/zenoh_dart.git`, HEAD
**`9ddb4ed1fa663e1ceca9987197a57429b946a793`**.

⛔ **No tag exists.** These checks run **before** the tag, inside gate 3, so the tag never precedes the dry-run.

## The push, verified at the remote

`git ls-remote --heads`, never the push output:

```
9ddb4ed1fa663e1ceca9987197a57429b946a793  refs/heads/release/0.30.0
7c197cc93fadc7acc03ac59bb3ecd179a65975a3  refs/heads/main        ← unchanged
```

**Tags at the remote:** `v0.18.0`, `v0.18.1`, `v0.19.0`, `v0.20.0`, `v1.0.0-rc.1`. **No `v0.30.0`.**
And the branch is still cut from the public tip: `A^` equals `main` exactly.

## P40 — the protection, read rather than remembered

| setting | reading |
|---|---|
| merge methods | `allow_merge_commit: true`, `allow_squash_merge: false`, `allow_rebase_merge: false`, `delete_branch_on_merge: false` |
| ruleset `22925074` **protect-main** | target `refs/heads/main` **only**; rules `deletion`, `non_fast_forward`, `pull_request` (`allowed_merge_methods: ["merge"]`, 0 required approvals, **`require_extra_approval_for_unattributed_changes: true`**); **no bypass actors**. ⭐ It does not cover `release/*`, which is why the push was accepted |
| ruleset `22925076` **protect-release-tags** | target `refs/tags/v*`; rules **`deletion` and `update` only**; no bypass actors |

⭐ **The reading this release needed:** `protect-release-tags` carries **no `creation` rule**, and it constrains nothing about
which commit a tag points at. **So `v0.30.0` may be created, on this branch's tip, which is not on `main`.** ⚠️ Read at this
check; not carried over from the previous release.

## P41 — public hygiene

| check | reading |
|---|---|
| `git status --porcelain` | **empty** |
| `package/pubspec.lock` tracked | **no** |
| `.fvmrc` byte-equal to E′'s | **equal** |
| the gitlink equals `build-pins/zenoh-core.pin` | `7b8478618861972b9f0115da75e694c9f0a2af5a`, equal |
| `package/{LICENSE,README.md,CHANGELOG.md}` | all present |
| the natives survived the round trip | 18 tracked paths; `native_manifest.py check` → **all 16 equal the manifest** |

## P42 — the publish dry-run's file list

**Exit 0**, from `package/` in the fresh clone. Top level: `CHANGELOG.md`, `LICENSE`, `README.md`,
`analysis_options.yaml`, `doc/`, `example/`, `hook/`, `lib/`, **`native/`**, `pubspec.yaml`.
**`native/` carries all 16 libraries, `manifest.json` (69 KB) and `build-environment.txt`.**
⛔ **Not listed:** `test/`, `dart_test.yaml`, `ffigen.yaml` — each read **0**.

**0 warnings and 2 hints.** ⭐ **The S2 record left a question open rather than predicting it — *"whether the two hints alone
still produce a non-zero exit is read there, not predicted here."* It is answered: exit 0.** The S2 warning was the dry-run
mode's own artefact (that mode stages without committing) and is gone here, as that record said it would be.

**The two hints, dispositioned in writing:**

| hint | disposition |
|---|---|
| *"The latest published version is 1.0.0-rc.1. Your version 0.30.0 is earlier than that."* | **Expected, and it is the release.** pub orders `1.0.0-rc.1` above `0.30.0` while pub.dev's *latest stable* is `0.20.0`. Publishing a stable `0.30.0` is exactly what makes a bare `dart pub add` resolve to the current state. |
| *"The previous version is 0.20.0 … not an incremental update … consider 1.0.0 / 0.21.0 / 0.20.1"* | **Expected.** The developer ruled the number: pub's caret below 1.0 is same-minor, so any minor bump above `0.20` already keeps `^0.20.0` consumers where they are, and the number is a size signal only. `1.0.0` waits on the API freeze. |

## P43 — pana

**`pana` 0.23.19**, on a **copy** of the branch's `package/` (pana writes into what it scores). **160 / 160.**
Licence detected **`Apache-2.0`**. Every section at full marks: file conventions 30/30, documentation 20/20, platform support
20/20, static analysis 50/50, dependencies 40/40. **No deduction to disposition.**

## ⏰ P43/P09 — one finding with a deadline, and it is not this release's to fix

pana's dependency section is at full marks **with a note**:

> *"The constraint `^1.2.1` on `code_assets` does not support the stable version `2.0.0`, that was published **29 days ago**.
> When `code_assets` is 30 days old, this package will no longer be awarded points in this category."*

⭐ **Ten points turn on a date.** Published now, `0.30.0` scores 160/160; published a day or two later it scores 150/160, and
that score is what pub.dev shows as the package's headline once this version becomes the latest.

**P09 — dependency currency**, from `fvm dart pub outdated`:

| dependency | current | resolvable | justified beside it in the pubspec? |
|---|---|---|---|
| `code_assets` (direct) | `^1.2.1` | **2.0.0** | ⛔ **no** |
| `ffigen` (dev) | `21.0.0` | 22.0.0 | ⛔ no |
| `very_good_analysis` (dev) | `^10.3.0` | 11.0.0 | ⛔ no |
| `hooks`, `meta` | held deliberately | — | ✅ yes, each with its reason |

▶ **Recorded as R26 debt, which the procedure's own cell permits at a candidate** (*"recorded; holds justified or listed as R26
debt"*). ⛔ **The pubspec text is CI's, not CB's**, so this is routed, not fixed here. **It should be raised before the next
release, or that release scores 150/160.**

## P44 — API docs build

`fvm dart doc --dry-run`: **0 errors**, **76 warnings**, exit 0. ⭐ **All 76 are one class** — *"ambiguous reexport …
canonicalization candidates: (zenoh_unstable, zenoh)"* — which is structural to the two entry points deliberately re-exporting
the same symbols, not a defect in any doc comment. **The class is triaged and is the one roadmap R23 closes before `1.0.0`.**

## P45, P46, P47

| # | instrument | reading |
|---|---|---|
| P45 | `fvm dart format --output=none --set-exit-if-changed lib example hook` | **86 files, 0 changed**, exit 0 |
| P46 | the dry-run's total, and the listed files | compressed **43 MB** (< 100 MiB) · uncompressed **104.1 MiB** (< 256 MiB) · **325 files** (< 65536) · `pubspec.yaml` **3602 B** (< 128 KiB) · `README.md` **8076 B** and `CHANGELOG.md` **39588 B** (both < 256 KiB) |
| P47 | the dry-run's leak validator | **reported nothing** |

## What is not done here

⛔ **No tag, no export tag, no publish preparation.** Those are S9 and S10, after CA's gate-3 verdict.
⭐ When `v0.30.0` is cut, its message must carry the aggregate on a `manifest:` line — the CHANGELOG's claim that *"both release
tags"* carry the same value becomes true only then.
