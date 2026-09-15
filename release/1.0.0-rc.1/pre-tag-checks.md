# S8 — the pre-tag checks, `1.0.0-rc.1`

**Stage:** S8 of `development/release/release-procedure.md` (A2; P40–P47, with P09), run by CB on 2026-09-15 **in a fresh clone of
the pushed branch** — `git clone --branch release/1.0.0-rc.1 https://github.com/bluecorn/zenoh_dart.git`, HEAD asserted equal to
**R = `6d18a3fd2a70f9a6de426cf8220a1eb44f7f53c6`**, `git status --porcelain` 0 lines before anything ran.
**The push:** at 07:16:21 UTC, from the build clone, `git push public release/1.0.0-rc.1:refs/heads/release/1.0.0-rc.1`, after
four guards (on the branch; HEAD = R; exactly three commits over `5f65688`; nothing staged, the pubspec unflipped; no
`release/1.0.0-rc.1` on the remote yet). **Verified by `git ls-remote`, never by the push output:** `refs/heads/release/1.0.0-rc.1`
= `6d18a3f`; `main` still `5f65688`; no `v1*` tag. **The first write to the public repository in this release.** The pull request
is **#4**, `release/1.0.0-rc.1` → `main`. **This record is the only commit after R on the branch** (`git diff --name-only R HEAD`
→ this file).

⛔ **Not done here, by the procedure's order:** the tag (S9, after CA's merge at gate 3), the publish (gate 4, the developer), the
heavy passes (S11b, on the published tree).

## P40 — protection read, not remembered

`gh api repos/bluecorn/zenoh_dart/rulesets`, each ruleset by id, and the repository's merge settings, read 07:16 UTC:

| object | reading |
|---|---|
| ruleset `22925074` **protect-main** | target branch, active, `refs/heads/main`; rules **deletion**, **non_fast_forward**, **pull_request** — `required_approving_review_count: 0`, `allowed_merge_methods: ["merge"]`, `dismiss_stale_reviews_on_push: false`, `require_code_owner_review: false`, `require_last_push_approval: false`, `required_review_thread_resolution: false`, ⚠️ **`require_extra_approval_for_unattributed_changes: true`**; `bypass_actors: []`; last updated 2026-09-11 |
| ruleset `22925076` **protect-release-tags** | target tag, active, `refs/tags/v*`; rules **deletion**, **update**; `bypass_actors: []` |
| repository settings | `allow_merge_commit: true` · `allow_squash_merge: false` · `allow_rebase_merge: false` · `allow_auto_merge: false` · `delete_branch_on_merge: false` |
| workflows | `.github/` → **0** files on `main` and **0** on the branch: no check fires on the PR (ruling 5; P62 not at `rc.1`) |

⚠️ **`require_extra_approval_for_unattributed_changes` is undescribed by GitHub's REST documentation** (A7). Every commit on this
branch is authored and committed by the release station's account, so nothing on it is unattributed as far as CB can tell. **If
the merge is blocked, read that setting first.**

## P41 — public hygiene, in the check clone

| check | reading |
|---|---|
| `git status --porcelain` | **0** lines |
| `git ls-files --error-unmatch package/pubspec.lock` | **fails (exit 1)** — untracked; control: the same on `package/pubspec.yaml` succeeds |
| `.fvmrc` against E's (`git show 036c8e1:.fvmrc`, `cmp`) | **byte-equal** (`{"flutter": "3.47.1"}`) |
| the gitlink against the pin | `7b8478618861972b9f0115da75e694c9f0a2af5a` = `ZENOH_C_SUBMODULE_COMMIT` |
| `package/LICENSE`, `package/README.md`, `package/CHANGELOG.md` | **all present** |
| tracked under `package/native/` | **18** — sixteen libraries, `manifest.json`, `build-environment.txt` |

## P42 — the publish dry-run's file list

`fvm dart pub get` (exit 0, Dart 3.13.1), then **`fvm dart pub publish --dry-run`** in `package/`: **exit 0, *"Package has 0
warnings"*** — the one warning S2's rehearsal carried (*"93 checked-in files are modified in git"*) was the staged, uncommitted
tree; in a fresh clone of the pushed commit it is gone. **112 files.** Top level: `CHANGELOG.md` (36 KB), `LICENSE` (11 KB),
`README.md` (7 KB), `analysis_options.yaml`, `doc/`, `example/`, `hook/`, `lib/`, `native/`, `pubspec.yaml` (3 KB).
**`native/`:** the sixteen libraries, each listed with its size (the largest `linux/x86_64/unstable/libzenohc.so`, 14 MB),
`manifest.json` (69 KB) and `build-environment.txt`. **Absent, by search of the listing:** `test/`, `dart_test.yaml`,
`ffigen.yaml`. *"Total compressed archive size: 43 MB."* **Every warning dispositioned: there are none.**

## P43 — pana 0.23.19

On an archive copy of the branch (`git archive HEAD | tar -x`, pana run in its `package/` — pana writes into what it scores):
**160 / 160.** Follow Dart file conventions 30/30 · Provide documentation 20/20 · Platform support 20/20 (`platform:android`,
`platform:linux`) · Pass static analysis 50/50 · Support up-to-date dependencies 40/40, *partial* on one note, verbatim: *"The
constraint `^1.2.1` on code_assets does not support the stable version `2.0.0`, that was published 27 days ago."* Licence tags:
**`license:apache-2.0`**, `license:fsf-libre`, `license:osi-approved`. ⚠️ **pana's "27 days" has now read 27 on two consecutive
days** (iteration 3's rehearsal 2026-09-14, S2's and this one 2026-09-15) — it is not a clock; the points it warns about lapse on
pub.dev's own reckoning. See P09.

## P44 — API docs build

`fvm dart doc --dry-run` in `package/`: **exit 0; 0 errors; 76 warnings, all one class** — *"ambiguous reexport of
`<library>.<Name>`, canonicalization candidates: (zenoh_unstable, zenoh) -> zenoh (confidence 0.001)"*. **Triaged:** both doors
(`zenoh.dart`, `zenoh_unstable.dart`) export the same names, dartdoc picks the `zenoh` page for each with near-zero confidence, and
the consumer-visible effect is which door's page documents a class (the same reading the newcomer read took). One class, 76
instances; **R23 closes it at `1.0.0`.**

## P45 — formatter on the branch

`fvm dart format --output=none --set-exit-if-changed package/lib package/example package/test package/hook`: **exit 0, *"Formatted
283 files (0 changed)"*.**
⚠️ **Disclosed:** the **first** run, taken before `pub get`, read **exit 1, *"283 files (88 changed)"***. With no
`.dart_tool/package_config.json` the formatter resolves the language version differently and would reformat 88 files in another
style; after `pub get` it reads 0 changed — the same as P04 at E in dev, which ran after `pub get` implicitly. **The instrument
needs `pub get` first; P04's row says so only by accident of order.** ▶ For the procedure. **283 against dev's 311:** the public
tree carries 28 fewer Dart files — `test/interop/` and `test/dev/`, excluded by carriage.

## P46 — size limits, the class read from pub-dev's own source

**Read at the check** from `dart-lang/pub-dev` `master` = `965acc0e` (2026-09-08), `pkg/pub_package_reader/lib/pub_package_reader.dart`
(through the GitHub API, not a clone): `maxArchiveSize = 100 * 1024 * 1024` (compressed) · `maxUncompressedSize = 256 * 1024 * 1024`
· `maxFileCount = 64 * 1024` · *"pubspec.yaml is too large"* above `128 * 1024` · **`maxContentLength = 256 * 1024`, applied to
exactly four files** — the README, CHANGELOG, example and LICENSE files pub-dev picks
(`scanAndReadFiles([readmePath, changelogPath, examplePath, licensePath])`, issue text *"`<path>` exceeds the maximum content
length"*). ✅ **Part D4's scoping is confirmed at source: the cap is on the content class, not on every file.**

| limit | reading | met |
|---|---|---|
| compressed archive < 100 MiB | **43 MB** (the dry-run) | ✅ |
| uncompressed sum < 256 MiB | **100.9 MiB over 112 files** — the tree minus what `.pubignore` and pub's own rules drop; the file count equals the dry-run's 112 | ✅ |
| file count < 65,536 | **112** | ✅ |
| `pubspec.yaml` < 128 KiB | **3,606 B** | ✅ |
| each content-class file ≤ 256 KiB | `README.md` **7,488** · `CHANGELOG.md` **37,374** · `LICENSE` **11,373** · every example candidate — `example/README.md` **64,815**, `example/example.dart` **936** | ✅ |

The largest file in the archive, the unstable Linux core at 15,610,224 bytes, is not in the content class.

## P47 — leak detection

The dry-run's validation block, verbatim: *"Validating package... The server may enforce additional checks. Package has 0
warnings."* No validator reported anything; a search of the output for *leak*, *secret*, *credential* and *key* finds nothing.

## P09 — dependency currency

`fvm dart pub outdated` in `package/`: **direct:** `code_assets` **1.2.1 held** (resolvable and latest 2.0.0); **dev:** `ffigen`
21.0.0 (22.0.0), `very_good_analysis` 10.3.0 (11.0.0); **transitive dev:** `cli_util` 0.4.2 (0.6.0), `native_toolchain_c` 0.19.3
(0.19.4). ⚠️ **`code_assets: ^1.2.1` carries no justification beside it in the pubspec** — `hooks` and `meta` do, `code_assets`
does not. The row's cell at a candidate reads *"recorded; holds justified or listed as R26 debt"*: **this is R26's debt**
(roadmap R26, CI, `1.0.0`: *"dependency holds justified; whether `code_assets` 2.0.0 changes the hook API"*), still open.
**Recorded, not a hold; the pubspec text is CI's.** ⚠️ **What it costs if left:** pana's dependency points lapse once pub.dev judges
the newer major 30 days old, which is imminent by pana's own note — the score at P53 may read below 160 for that reason alone.

## P02 — floor equals pin, in the clone

The assembly read `pin=3.13.1 floor=3.13.1` at E (its R10); here `.fvmrc` is byte-equal to E's (P41) and `package/pubspec.yaml`
declares `sdk: ^3.13.1`.

## For gate 3

**Every row P40–P47 met; P09 recorded with its R26 debt. Nothing red. Nothing tagged.** CA merges PR #4 with a merge commit; S9
tags the merge commit afterwards and cuts `export/1.0.0-rc.1` on E in dev.
