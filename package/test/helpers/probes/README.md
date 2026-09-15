# CI-side measurement probes — seed #6 (channels-query-reply)

Instruments run during implementation, committed per Decision log 10 (probe sources join the
attackable record). Each file's header states what it measures; the verbatim outputs are recorded
below and cited from the test cells and the PR body that depend on them.

**Why they live here.** A Dart file outside `package/` cannot resolve
`package:zenoh_dart/...` at all — it fails to compile rather than measuring anything — so a probe
that must exercise the shipped API belongs inside the package. `test/helpers/` is the established
home for exactly this (see `alloc_guard_harness.dart` and the pull-port lifecycle probe). Run one
with `cd package && fvm dart run test/helpers/probes/<file>`. They are not `*_test.dart`, so the
default suite never picks them up.

## `probe_liveliness_timeout_zero.dart` — Slice 1

**Question.** The plan's Slice 1 Test 5 predicted that `livelinessGet(..., timeout: Duration.zero)`
completes "carrying zero replies", on the premise that canon applies the liveliness timeout
unconditionally (the shim header's note at `src/zenoh_dart.h`, `zd_liveliness_get`).

**Run 1 — reply counts over repeated gets, two sessions over TCP loopback, one alive token:**

```
ZERO_TIMEOUT_COUNTS={1: 30}
DEFAULT_TIMEOUT_COUNTS={1: 5}
ONE_MS_COUNTS={1: 30}
```

**Run 2 — completion latency, discriminating sentinel-vs-literal:**

```
NOTOKEN_ZERO_MS=2
NOTOKEN_ZERO_MS=0
NOTOKEN_3S_MS=0
NOTOKEN_DEFAULT_MS=0
TOKEN_ZERO count=1 ms=2
```

**Findings.**

1. `timeout: Duration.zero` on `livelinessGet` **delivers the alive token's reply, 30/30** — it is
   not an immediate expiry through our stack. The predicted "zero replies" was a wish; the cell
   pins the measurement instead.
2. The sentinel-vs-literal question is **not discriminable through this stack**. A liveliness get
   completes as soon as the peers have answered, with or without an alive token (0–2 ms in every
   configuration above), so the timer never bites and both hypotheses predict the same observable.
   That is the reason the entry is left honouring zero rather than refusing it: unlike `Session.get`,
   where the substitution is observable (a caller asking for instant expiry silently waits ~10 s),
   here there is no observable to be wrong about.
3. Consequently the shim header's *consequence* sentence for `zd_liveliness_get` — "a liveliness
   query with a 0 ms timeout expires immediately and returns nothing" — is not what happens
   end-to-end. Corrected at Slice 20's header-hygiene pass. The header's separate claim about
   canon's own source was **not** re-derived here (the charter bars reading the Rust core during
   implementation); only the observable is amended.

## `probe_parameters_absent_vs_empty.dart` — Slice 3

**Question.** Canon documents NULL = "none" for a query's parameters on the send side. What does
the RECEIVE side report for absent versus present-but-empty? Nothing anywhere measured it.

**Run (two sessions over TCP loopback, one Stream-path queryable):**

```
--- q0: parameters OMITTED, payload OMITTED ---
q0 parameters=String len=0 value=[] payloadBytes=null attachmentBytes=null
--- q1: parameters: "", payload present-but-empty ---
q1 parameters=String len=0 value=[] payloadBytes=[] attachmentBytes=null
--- q2: parameters: "x=1", payload "p" ---
q2 parameters=String len=3 value=[120, 61, 49] payloadBytes=[112] attachmentBytes=null
```

**Findings.**

1. **Absent and present-but-empty parameters are indistinguishable** at the queryable: both read
   as the empty string. Nothing is "fixed" to manufacture a distinction canon does not draw.
2. The collapse is **canon's, not ours**, and it happens before any wire encoding:
   `CStringView::new_borrowed` takes a NULL pointer at length 0 and a non-NULL pointer at length 0
   alike (`extern/zenoh-c/src/collections.rs:164`), so both arrive at zenoh as the same empty
   `&str`. `Query.parameters` is a non-nullable `String` for the same reason — there is no absent
   value to render.
3. The **payload path is the discriminating control**, and it rides the same query, the same
   callback and the same NativePort message: absent reports `null`, present-but-empty reports a
   non-null empty list. So the harness can see an absent/empty distinction when one exists, which
   is what makes finding 1 a result rather than blindness.

---

# Seed #8 (advanced-parity)

## `probe_detect_token_zid_width.dart` — Slices 6/9

**Question.** Slice 6's token-shape cell asserted the detect token's zid segment as
`[0-9a-f]{32}`, passed, and then went red on a re-run. Is that segment fixed-width, or is it
canon's leading-zero-**stripped** rendering — in which case the assertion pinned a sample rather
than canon's contract, and carried a per-run red at the rate `interop/canon.dart` already records
for `z_id_to_string` (1 zid in 16, measured over 96 canon sessions)?

**Run — 40 fresh publisher sessions, one detection each:**

```
7: SHORT(31) zenoh/probe/tok7/@adv/pub/12c046c507d853d454e4f2f005174cf/uhlc/_  ours=cf7451002f4f4e453d857d506c042c01
16: SHORT(31) zenoh/probe/tok16/@adv/pub/da9c892ce9d8343ff4aad2b0ed0e1e4/uhlc/_  ours=e4e1d00e2bad4aff43839dce92c8a90d
19: SHORT(31) zenoh/probe/tok19/@adv/pub/b0f55da69c1612cca5fa40c8c843d19/uhlc/_  ours=193d848c0ca45fca2c61c169da550f0b
zid-segment width distribution: {32: 37, 31: 3}
```

**Answer: stripped.** 3 of 40 — consistent with the recorded 1/16. And the pairs confirm both
axes at once: pad `12c046c507d853d454e4f2f005174cf` back to 32 (`012c…`), reverse its byte pairs,
and it is exactly `cf7451002f4f4e453d857d506c042c01`, the same session's `ZenohId.toHexString()`.
So the token's zid obeys the identical two-axis divergence the interop harness already models —
this is a second site for a fact the tree had recorded at one.

**What it changed.** The shape cell no longer matches a width. It splits the token, checks the zid
segment against `canonZidPattern`, and then normalizes it through `canonZidToOurHex` and compares
it to the publisher session's own `zid.toHexString()` — full 32-character strength, and stronger
than the regex it replaces, per `verification.md`'s rule to normalize into the contract rather than
widen the matcher.
