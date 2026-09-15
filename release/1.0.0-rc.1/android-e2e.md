# S7 — Android end-to-end, `1.0.0-rc.1`, iteration 4

> **Where the cited tools live.** The fixture (`development/release/fixtures/android-e2e/`, its `run_e2e.sh` and the app), the
> stage runner (`iteration-4/runners/s7-run.sh`) and `native_manifest.py` are committed in the private development repository,
> `bluecorn/zenoh_dart_dev`, on `release-record/1.0.0-rc.1`; this repository does not carry that tree.

**Stage:** S7 of `development/release/release-procedure.md` (A2; P36–P38), run by CB on 2026-09-15 over the libraries of
**N = `88a7314bb2e9e1d10642a895773b70944832ae26`**, from a fresh clone of N (`iteration4/s7-at-N`; HEAD asserted equal to N,
`native_manifest.py check` **16 of 16** before and after each ABI's runs). **Run in full:** under A2a the anchor iteration
(3) ran its own S7 in full and S4's comparison reads all 16 libraries equal, **but the path diff over `package/example/` is not
empty** — the cookbook, `package/example/README.md`, changed — so the row's discharge is unavailable as written. *(The rule names
the directory where it means the programs the fixture consumes, `example/z_sub.dart` and `example/z_put.dart`; a README is
neither. Recorded for S12 in the dev records; applied as written here.)*
**One run per variant per device:** the fixture builds the app against the package under test, checks that the APK carries the
libraries under test (after the pinned NDK's `llvm-strip --strip-unneeded`, the release build's packaging transform), then
exchanges a message in each direction through a pinned `zenohd` 1.8.0 on the host's loopback reached over `adb reverse`. Each
run's APK and logs are kept outside the repositories (`iteration4/logs/s7/`).

## Per ABI — what ran where (P36's input)

| ABI | device | variant | run (UTC) | the loaded libraries — sha256 under test (`libzenoh_dart` · `libzenohc`), each = the manifest's | result |
|---|---|---|---|---|---|
| `x86_64` | the host's emulator: Google `sdk_gphone16k_x86_64` (AVD `Pixel_Tablet`, headless), API 37, page size **16384**, ABI list `x86_64,arm64-v8a` | stable | 06:42:39 | `27986cc8…` · `46a3563e…` | **PASS**, Flutter row `3.47.1` |
| `x86_64` | the same | unstable | 06:43:06 | `85f14dfc…` · `887e531b…` | **PASS**, Flutter row `3.47.1` |
| `arm64-v8a` | the developer's device (R39): **Google `Pixel 9a`**, serial `58141JEBF02659`, physical (`ro.kernel.qemu` empty), Android 17 / API 37, page size **4096**, ABI list **`arm64-v8a` only** — attached before N existed, at the developer's word | stable | 06:41:05 | `f583069f…` · `12af4388…` | **PASS**; ⚠️ Flutter row **empty** (finding 2) |
| `arm64-v8a` | the same | unstable | 06:41:53 | `99360e80…` · `3b683073…` | **PASS**, Flutter row `3.47.1` |
| `armeabi-v7a` | ⛔ **none — built, LOAD-aligned `0x4000`, never loaded on any device.** A permanent caveat on this hardware (R39): the one physical device lists `arm64-v8a` as its only ABI, and the emulator image is `x86_64`. Shipped *caveat emptor — use at your own discretion* (ruling 11; P38) | both | — | — | **not run, permanently** |

**Every APK carried its libraries under test:** in all four runs the fixture's section 1 reads the stripped library's sha256
equal to the APK's, for both `libzenoh_dart.so` and `libzenohc.so`; the sha256 under test equals the manifest's for that ABI and
variant. The device logged `ZENOH_E2E PASS` in all four, after the host received `device <tag>` and the run's unique acknowledgement.

## Findings

1. **The fixture's residue recurred exactly as iterations 1 and 3 recorded** — the host-side subscribers it leaves behind and the
   Gradle and Kotlin daemons — and was stopped, by pid, before certification started; the emulator was stopped (`adb emu kill`)
   and verified gone; the Pixel carried no `adb reverse` rule afterwards. ⚠️ **One instrument defect of CB's, disclosed:** the
   first cleanup command searched process command lines for `z_sub.dart` and matched **its own shell**, which it then killed
   (exit 144) after stopping the emulator and the subscribers but before the daemons; a second pass with a pattern that cannot
   match itself (`[z]_sub\.dart`) finished the job and verified the host clean. The proposed fixture changes stand and are still
   not made — this iteration ran the same instrument on purpose, so its runs are comparable. ▶ **Make them after `rc.1`.**
2. ⚠️ **The `arm64-v8a` stable record's Flutter row is empty.** The fixture fills it from `fvm flutter --version | head -1`,
   run once per record; on the first invocation of this session it printed nothing on its first stdout line, and on the three
   later runs it read `Flutter 3.47.1 • channel stable`. **The row is informational:** the app was built by the fixture's own
   `.fvmrc`-pinned Flutter (3.47.1) in all four runs, and the APK identity check (section 1) is what the PASS rests on. ▶ **For the
   fixture:** read the version from `fvm flutter --version --machine` or the SDK's `version` file rather than the first line of a
   human-formatted banner.
3. **The host ran a game at about 270% CPU throughout** (`CivilizationVI_`); the runs took 27–48 s each. Timing is not compared
   with iteration 3's; the exchange is a pass/fail instrument.

---

# Android end-to-end run — `x86_64-stable`

| what | reading |
|---|---|
| date (UTC) | 2026-09-15T06:42:39Z |
| device | Google sdk_gphone16k_x86_64 (serial `emulator-5554`) |
| emulator | yes |
| Android API level | 37 |
| ABI list | `x86_64,arm64-v8a` |
| page size | 16384 |
| variant | `stable` |
| package under test | `/home/hugo/bluecorn/release-work/1.0.0-rc.1/iteration4/s7-at-N/package` |
| router | `zenohd v1.8.0 built with rustc 1.93.0 (254b59607 2026-01-19)`, sha256 `deab2fce50d88adece23662ee96a9f2d42c302f5cc67d47fedf26fc0688571bc` |
| Flutter | Flutter 3.47.1 • channel stable • https://github.com/flutter/flutter.git |
| APK | `9012677692516536ce66bf88468829091e1f7632007eb88bc1f7d908552e11d7`, libraries for: arm64-v8a armeabi-v7a x86_64  |

## 1. The APK carries the libraries under test (`x86_64`)

- packaging transform reproduced with `/home/hugo/Android/Sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip --strip-unneeded` (NDK 28.2.13676358)
- `libzenoh_dart.so`: under test `27986cc8b3337dea4355257a434ae657221935da0cc9632624d00551bbf20e25` → stripped `ee78470a19836ca07e809753dae0bde0cd5ba701a5d6a80edffbb8720afe34a0` · in the APK `ee78470a19836ca07e809753dae0bde0cd5ba701a5d6a80edffbb8720afe34a0`
- `libzenohc.so`: under test `46a3563e44cd8e6a765ffcaf2a95f72d5353aba15c6aca66548b6a00ad9ef9c2` → stripped `90f7e0ef2c1de0d479f41e1b238235591d55fbbacb6e2dbd37d2ebdc7c13fc6e` · in the APK `90f7e0ef2c1de0d479f41e1b238235591d55fbbacb6e2dbd37d2ebdc7c13fc6e`

## 2–4. The exchange

- installed; the package manager's primary ABI for the app: `x86_64`
- **device → host:** the host subscriber received `device x86_64-stable`
- **host → device → host:** the host published `host-20260915T064239Z-1849519` and received `ack x86_64-stable host-20260915T064239Z-1849519`
- **device:** logged `ZENOH_E2E PASS`

### The device's log lines

```
    09-15 08:43:00.806 I/flutter ( 7642): ZENOH_E2E OPEN tag=x86_64-stable zid=71b77f65e62c10f976546720b0815e4e
    09-15 08:43:00.806 I/flutter ( 7642): ZENOH_E2E READY
    09-15 08:43:03.197 I/flutter ( 7642): ZENOH_E2E RECEIVED host-20260915T064239Z-1849519
    09-15 08:43:05.200 I/flutter ( 7642): ZENOH_E2E PASS
```

**RESULT: PASS**

---

# Android end-to-end run — `x86_64-unstable`

| what | reading |
|---|---|
| date (UTC) | 2026-09-15T06:43:06Z |
| device | Google sdk_gphone16k_x86_64 (serial `emulator-5554`) |
| emulator | yes |
| Android API level | 37 |
| ABI list | `x86_64,arm64-v8a` |
| page size | 16384 |
| variant | `unstable` |
| package under test | `/home/hugo/bluecorn/release-work/1.0.0-rc.1/iteration4/s7-at-N/package` |
| router | `zenohd v1.8.0 built with rustc 1.93.0 (254b59607 2026-01-19)`, sha256 `deab2fce50d88adece23662ee96a9f2d42c302f5cc67d47fedf26fc0688571bc` |
| Flutter | Flutter 3.47.1 • channel stable • https://github.com/flutter/flutter.git |
| APK | `0083fd517a2ea53763c125c4a68f483a59accda4f965ba85eeadedb1b6622c52`, libraries for: arm64-v8a armeabi-v7a x86_64  |

## 1. The APK carries the libraries under test (`x86_64`)

- packaging transform reproduced with `/home/hugo/Android/Sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip --strip-unneeded` (NDK 28.2.13676358)
- `libzenoh_dart.so`: under test `85f14dfc5277c79a248f41927a99d5d999194d5440a07018103f54b8b1e92b81` → stripped `e2bc34974daf6d69c45e5842d845598868ad4f01d1a162158e696edba5c99bcb` · in the APK `e2bc34974daf6d69c45e5842d845598868ad4f01d1a162158e696edba5c99bcb`
- `libzenohc.so`: under test `887e531b500a53d9a20c2b2a761609f53c94785580dcb0cfe85f4ff1e279ca2d` → stripped `5e1c7773fadf7f44571d31b1158c23885cb7de09654800f37d850eba7e354e9c` · in the APK `5e1c7773fadf7f44571d31b1158c23885cb7de09654800f37d850eba7e354e9c`

## 2–4. The exchange

- installed; the package manager's primary ABI for the app: `x86_64`
- **device → host:** the host subscriber received `device x86_64-unstable`
- **host → device → host:** the host published `host-20260915T064306Z-1850669` and received `ack x86_64-unstable host-20260915T064306Z-1850669`
- **device:** logged `ZENOH_E2E PASS`

### The device's log lines

```
    09-15 08:43:26.421 I/flutter ( 7771): ZENOH_E2E OPEN tag=x86_64-unstable zid=14e6a0ed3e6425d366c599d030ee198e
    09-15 08:43:26.422 I/flutter ( 7771): ZENOH_E2E READY
    09-15 08:43:28.870 I/flutter ( 7771): ZENOH_E2E RECEIVED host-20260915T064306Z-1850669
    09-15 08:43:30.873 I/flutter ( 7771): ZENOH_E2E PASS
```

**RESULT: PASS**

---

# Android end-to-end run — `arm64-v8a-stable`

| what | reading |
|---|---|
| date (UTC) | 2026-09-15T06:41:05Z |
| device | Google Pixel 9a (serial `58141JEBF02659`) |
| emulator | no |
| Android API level | 37 |
| ABI list | `arm64-v8a` |
| page size | 4096 |
| variant | `stable` |
| package under test | `/home/hugo/bluecorn/release-work/1.0.0-rc.1/iteration4/s7-at-N/package` |
| router | `zenohd v1.8.0 built with rustc 1.93.0 (254b59607 2026-01-19)`, sha256 `deab2fce50d88adece23662ee96a9f2d42c302f5cc67d47fedf26fc0688571bc` |
| Flutter |  |
| APK | `878701b0e9de90d8c5f076a76fe2df8fd80a508e292ad099286d6496df2e5767`, libraries for: arm64-v8a armeabi-v7a x86_64  |

## 1. The APK carries the libraries under test (`arm64-v8a`)

- packaging transform reproduced with `/home/hugo/Android/Sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip --strip-unneeded` (NDK 28.2.13676358)
- `libzenoh_dart.so`: under test `f583069fd8a239d63aceb3827bbfbe9bf2d9d1713a9ea9e35e76261c04d396ba` → stripped `43703dcf8f26bf8ea463d5c848636f7b67f277ef87252578b6dbc2bd25dcacab` · in the APK `43703dcf8f26bf8ea463d5c848636f7b67f277ef87252578b6dbc2bd25dcacab`
- `libzenohc.so`: under test `12af438872a8897816180a389500bf94cda60147e200c6e6734c7cfea47c4028` → stripped `f2dcba27927412c96cdb05341ac21a86d2e4df17534a162c3edf6921a4683cef` · in the APK `f2dcba27927412c96cdb05341ac21a86d2e4df17534a162c3edf6921a4683cef`

## 2–4. The exchange

- installed; the package manager's primary ABI for the app: `arm64-v8a`
- **device → host:** the host subscriber received `device arm64-v8a-stable`
- **host → device → host:** the host published `host-20260915T064105Z-1847039` and received `ack arm64-v8a-stable host-20260915T064105Z-1847039`
- **device:** logged `ZENOH_E2E PASS`

### The device's log lines

```
    09-15 08:41:50.411 I/flutter (19290): ZENOH_E2E OPEN tag=arm64-v8a-stable zid=acf5b71d570166bd37b567924dbacfb6
    09-15 08:41:50.412 I/flutter (19290): ZENOH_E2E READY
    09-15 08:41:52.937 I/flutter (19290): ZENOH_E2E RECEIVED host-20260915T064105Z-1847039
    09-15 08:41:54.945 I/flutter (19290): ZENOH_E2E PASS
```

**RESULT: PASS**

---

# Android end-to-end run — `arm64-v8a-unstable`

| what | reading |
|---|---|
| date (UTC) | 2026-09-15T06:41:53Z |
| device | Google Pixel 9a (serial `58141JEBF02659`) |
| emulator | no |
| Android API level | 37 |
| ABI list | `arm64-v8a` |
| page size | 4096 |
| variant | `unstable` |
| package under test | `/home/hugo/bluecorn/release-work/1.0.0-rc.1/iteration4/s7-at-N/package` |
| router | `zenohd v1.8.0 built with rustc 1.93.0 (254b59607 2026-01-19)`, sha256 `deab2fce50d88adece23662ee96a9f2d42c302f5cc67d47fedf26fc0688571bc` |
| Flutter | Flutter 3.47.1 • channel stable • https://github.com/flutter/flutter.git |
| APK | `39550e08642adc354b38f211017071d42259b725e8290c9f7b365924b2f7d22d`, libraries for: arm64-v8a armeabi-v7a x86_64  |

## 1. The APK carries the libraries under test (`arm64-v8a`)

- packaging transform reproduced with `/home/hugo/Android/Sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip --strip-unneeded` (NDK 28.2.13676358)
- `libzenoh_dart.so`: under test `99360e80038ea929d3aaf972a711d7effb310f52c57346a8c8db8b50cbe8f49f` → stripped `76c67725ed24c23bc958b8312005c7cce2b253747c4bb8a9a58dbd2b180cc326` · in the APK `76c67725ed24c23bc958b8312005c7cce2b253747c4bb8a9a58dbd2b180cc326`
- `libzenohc.so`: under test `3b68307399c1bd490ab1450bf5757f9ac47ea2ef3c33fe35c18532a5e7d2bf73` → stripped `33406c702a0b05bc2a241b85922f185447dae03e37aefdb8a778320469dd8ded` · in the APK `33406c702a0b05bc2a241b85922f185447dae03e37aefdb8a778320469dd8ded`

## 2–4. The exchange

- installed; the package manager's primary ABI for the app: `arm64-v8a`
- **device → host:** the host subscriber received `device arm64-v8a-unstable`
- **host → device → host:** the host published `host-20260915T064153Z-1848387` and received `ack arm64-v8a-unstable host-20260915T064153Z-1848387`
- **device:** logged `ZENOH_E2E PASS`

### The device's log lines

```
    09-15 08:42:19.402 I/flutter (19472): ZENOH_E2E OPEN tag=arm64-v8a-unstable zid=1173ab47c89656a7626a4be7ec8a2afc
    09-15 08:42:19.402 I/flutter (19472): ZENOH_E2E READY
    09-15 08:42:21.569 I/flutter (19472): ZENOH_E2E RECEIVED host-20260915T064153Z-1848387
    09-15 08:42:23.576 I/flutter (19472): ZENOH_E2E PASS
```

**RESULT: PASS**

---

