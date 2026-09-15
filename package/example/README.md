# zenoh-dart Examples

> **Audience:** Auditors, new developers, and zenoh users familiar with the
> C or C++ bindings who want to understand what zenoh-dart implements, what
> it skips, and why.
>
> **Convention:** Each example entry below mirrors a zenoh-c example
> (`extern/zenoh-c/examples/z_*.c`). Entries are grouped by zenoh pattern.
> Canon-following examples get brief entries; examples that deviate from
> zenoh-c/zenoh-cpp get expanded architectural rationale.

## How This Binding Maps to zenoh-c

zenoh-dart is a pure Dart FFI package. Dart never calls zenoh-c directly.
All calls pass through a C shim layer (`src/zenoh_dart.c`) whose symbols
use the `zd_` prefix:

```
Dart API  -->  libzenoh_dart.so (C shim, zd_* functions)
                     |
                     +--> libzenohc.so (zenoh-c, z_* functions)
                          resolved by OS linker via DT_NEEDED
```

The C shim exists because six categories of zenoh-c construct cannot cross
the Dart FFI boundary:

| # | Barrier | Example |
|---|---------|---------|
| 1 | `static inline` move functions | `z_move(x)` has no exported symbol |
| 2 | C11 `_Generic` polymorphic macros | `z_drop`, `z_loan`, `z_try_recv` |
| 3 | Options struct initialization | `z_put_options_default()` is a macro |
| 4 | Opaque type sizes | Dart FFI has no `sizeof` for foreign types |
| 5 | Closure callbacks across threads | NativePort bridge for Dart event loop |
| 6 | Loaning and const/mut enforcement | `z_loan()` is macro/inline; Dart erases const |

Every `zd_*` function wraps one or more of these barriers. There are no
unnecessary proxies.

**Dual-reference strategy:** We use zenoh-c as the contract boundary
(correct FFI) and zenoh-cpp as the structural peer (API design). We do
not reference the Rust source — it is one layer too deep.

**Example-driven development:** Each CLI example mirrors its zenoh-c
counterpart — same flags, same defaults, same output format. This ensures
cross-language interop (a Dart `z_get` can query a C `z_queryable`) and
zero cognitive overhead for zenoh users switching languages.

Two families of deliberate difference remain, and both are called out at
the entries where they apply: **language-token substitution** in default
key expressions and payloads (`zenoh-c-put` -> `zenoh-dart-put`, `Put from
C!` -> `Put from Dart!`), and a small number of **documented deviations**
where a C idiom has no Dart counterpart. Anything else is a defect.

---

## Common Flags

Every canon example except `z_bytes` and `z_scout` parses the block that
`extern/zenoh-c/examples/parse_args.h` calls `COMMON_HELP`. Every example
here except `z_bytes` parses it, from one shared implementation,
`example/common_args.dart`, rather than a copy per example — `z_scout`
included, so it accepts flags that canon's `z_scout`, whose `main` reads no
arguments, does not.

| Flag | Description |
|------|-------------|
| `-c, --config <CONFIG>` | Path to a JSON5 configuration file. Without it, the default configuration is used. |
| `-m, --mode <MODE>` | Session mode: `peer` (default), `client` or `router`. |
| `-e, --connect <ENDPOINT>` | Endpoint to connect to. Repeatable. |
| `-l, --listen <LOCATOR>` | Locator to listen on. Repeatable. |
| `--cfg <KEY:VALUE>` | Arbitrary configuration change; `VALUE` is JSON5. Repeatable. E.g. `--cfg 'transport/unicast/max_links:2'`. |
| `--no-multicast-scouting` | Disable multicast scouting. |
| `-h, --help` | Print help and exit 1 (canon's `_Z_CHECK_HELP` exits 1, not 0). |

The block also carries canon's argument *rejection* behaviour: an
unrecognised option prints `Unknown option <arg>`, an option missing its
value prints `Option <arg> given without a value`, and an unexpected
positional prints `Unexpected positional arguments`. All three exit 255 —
the status a shell observes for canon's `exit(-1)`. `z_bytes` is excluded
on purpose: canon's `z_bytes.c` has no argument parsing at all and opens no
session, so giving it a flag surface would create a divergence rather than
close one.

Per-example tables below list only that example's own flags and link back
here for the shared block, exactly as canon's `print_help` functions print
their own options and then `printf(COMMON_HELP)`.

---

## Absent Examples

These zenoh-c examples are intentionally not implemented. Each omission
has a structural reason.

### z_sub_shm — Subscriber Is SHM-Transparent

zenoh-c's `z_sub_shm.c` demonstrates a subscriber that detects and
handles SHM-backed payloads explicitly. In zenoh-dart, all subscribers
already receive SHM-backed data transparently — `Sample.payloadBytes`
returns the bytes regardless of backing, so no separate subscriber example
is required to *consume* SHM.

Classifying a received payload is now covered, in canon's **two-state**
`SHM`/`RAW` form: `Sample.payloadZBytes` and `Query.payloadZBytes` hand back an
owned `ZBytes`, and `ZBytes.isShmBacked` reads its backing. `z_queryable_shm`
prints that tag, as canon's does.

Canon's **three-state** rendering — `SHM (MUT)` / `SHM (IMMUT)` / `UNKNOWN`, in
`z_sub_shm.c` — remains deliberately out of scope: it needs the mut-reclaim
family, which is carved.

### z_pong_shm — Pong Is SHM-Transparent

No such example exists in zenoh-c. The pong responder echoes whatever
bytes it receives regardless of SHM backing. `z_pong.dart` works
unchanged with both `z_ping.dart` and `z_ping_shm.dart`.

---

## Examples

### z_put / z_delete — One-Shot Publish and Delete

**Follows canon.**

These are the simplest zenoh operations. `z_put` publishes a single
key-value pair; `z_delete` removes a resource.

**The pattern it demonstrates**

```
z_put:    open session → put(key, value) → close       (one-shot write)
z_delete: open session → delete(key) → close           (one-shot remove)
```

The basic session lifecycle: open, operate, close. No long-lived
entities, no callbacks, no streams.

**Dart-specific note**

Both are synchronous FFI calls — no isolate, no async. The C shim wraps
`z_put()` / `z_delete()` primarily for options struct initialization
(barrier 3) and move semantics (barrier 1).

```
z_put.dart    -k demo/example/zenoh-dart-put  -p 'Put from Dart!'
z_delete.dart -k demo/example/zenoh-dart-put
```

| Flag | Default | Description |
|------|---------|-------------|
| `-k, --key` | `demo/example/zenoh-dart-put` | Key expression |
| `-p, --payload` | `Put from Dart!` | Value to publish (z_put only) |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

---

### z_sub — Callback Subscriber

**Follows canon** with Dart-specific async adaptation.

**The pattern it demonstrates**

```
z_sub: open → declareSubscriber(key) → stream<Sample> → ... → close   (long-lived, push)
```

Continuous message reception on a key expression. Runs until Ctrl-C.
zenoh-c uses a C callback invoked on a zenoh worker thread. Dart cannot
receive callbacks on non-Dart threads, so the C shim extracts all sample
fields synchronously during the callback and posts them to Dart via
`Dart_PostCObject_DL` / `NativePort`. Dart receives them as a `Stream<Sample>`.

This is the **NativePort callback bridge** — the foundational pattern
reused by every callback-based entity in the binding (subscriber,
queryable, scout, publisher matching listener, background subscriber).

**Why not `NativeCallable.listener`?** Dart 3.1 introduced
`NativeCallable.listener` as a higher-level callback API, but it uses
the same `SendPort`/`ReceivePort` mechanism internally. More critically,
zenoh-c's loaned pointers (`z_loaned_sample_t*`) are only valid during
the synchronous callback — by the time `NativeCallable.listener`
delivers the pointer to Dart asynchronously, the memory is invalid.
The C shim must extract fields synchronously regardless of which Dart
callback API is used. The current approach is battle-tested across all
phases and 500+ tests. Monitor `NativeCallable.isolateGroupBound`
(experimental) for a future alternative that could read loaned pointers
synchronously on the zenoh thread.

```
z_sub.dart -k 'demo/example/**'
```

| Flag | Default | Description |
|------|---------|-------------|
| `-k, --key` | `demo/example/**` | Key expression |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

---

### z_pub — Declared Publisher

**Follows canon.**

**The pattern it demonstrates**

```
z_pub: open → declarePublisher(key) → put(value) loop → close   (long-lived entity, periodic write)
```

A long-lived publisher entity that sends periodic messages. Supports
attachments, congestion control, priority, and a matching listener that
notifies when subscribers appear or disappear.

**Dart-specific note**

The matching listener uses the same NativePort bridge as subscribers,
delivering status changes as a `Stream<bool>`. `Timer.periodic` drives
the publish loop. Signal handling uses `ProcessSignal.sigint.watch()`.

```
z_pub.dart -k demo/example/zenoh-dart-pub -p 'Pub from Dart!' --add-matching-listener
```

| Flag | Default | Description |
|------|---------|-------------|
| `-k, --key` | `demo/example/zenoh-dart-pub` | Key expression |
| `-p, --payload` | `Pub from Dart!` | Message payload |
| `-a, --attach` | -- | Attachment string |
| `--add-matching-listener` | false | Enable subscriber discovery |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

---

### z_pub_shm — SHM Publisher

**Follows canon.**

**The pattern it demonstrates**

```
z_pub_shm: open → declarePublisher(key) → [alloc → fill → toBytes → put] loop → close
                                            ^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                            per-iteration SHM alloc (correct but expensive)
```

Per-iteration shared memory publish: allocate a fixed `total_size / 4`
buffer, write the message into its front, convert to `ZBytes`, and publish
the whole buffer — residual bytes included, as canon does. This is the
basic SHM pattern — correct but not optimal for latency-sensitive paths
(see `z_ping_shm` for the optimized pattern).

The pool and the buffer are both canon's own numbers (4096 and 1024) — this
example carries no deviation in its sizes. It used to floor the pool at 65536 on the claim
that smaller pools are rejected, which is measured false.
On allocation failure the example stops, as canon does, rather than warning and
continuing to look healthy while publishing nothing. Unlike canon it can say
*which* outcome the allocator reported, because `alloc` now returns a
discriminated result.

**The one call that is not canon's, and why it cannot be.** canon allocates
with the *blocking* entry (`z_pub_shm.c:80`); this example awaits
`allocGcDefragAsync`. The blocking entry is synchronous FFI, so it parks the
whole **isolate**, and on a request the pool can never satisfy it never
returns — a size merely larger than the pool reaches that. The ground for
diverging is a Dart-side asymmetry rather than taste: canon installs **no
signal handler**, so SIGINT keeps its default disposition and still kills it
while the allocation is parked, while this example installs one *on the very
event loop that would be frozen* — so a parked allocation would make its own
`Press CTRL-C to quit` false. Faithfulness to canon's *call* would be
infidelity to canon's *behaviour*.

Exposure is graded, and the note in each file says which end it is at:
`z_pub_shm` allocates once per publish iteration and `z_queryable_shm` once
per query, while `z_pub_shm_thr` and `z_ping_shm` allocate once at startup —
a narrower window, and still an unkillable process if it is reached. The full
hazard table stays on `allocGcDefragBlocking`'s own dartdoc, where a caller
meets it.

**Dart-specific note**

Filling the buffer through `ShmMutBuffer.write` — a **copy** into the chunk,
where C writes through a `uint8_t*` directly. That divergence is deliberate and
is the one place this binding does not mirror canon's mechanics: a raw pointer
handed to Dart outlives every guard the wrapper has, so the class used to have
to disarm its own safety net the moment anyone took one. `write` copies,
nothing escapes, and the net stays armed. ⚠️ **Nothing is lost on the wire** —
SHM's zero-copy property belongs to the transport, and the source bytes were
always in the Dart heap and always had to cross. `ShmProvider.alloc()` returns a sealed
three-way `AllocResult` — `AllocOk` with the buffer, `AllocError` with canon's
allocation-failure kind, or `LayoutError` with canon's layout-failure kind —
consumed by an exhaustive `switch` with no `default` arm. It previously
returned a nullable, which reported "the pool is full" and "your arguments are
wrong" with the same `null`.

SHM features are compile-time guarded (`Z_FEATURE_SHARED_MEMORY`,
`Z_FEATURE_UNSTABLE_API`) and excluded on Android where POSIX `shm_open`
is unavailable in Bionic.

```
z_pub_shm.dart -k demo/example/zenoh-dart-pub-shm -p 'Hello from SHM!'
```

| Flag | Default | Description |
|------|---------|-------------|
| `-k, --key` | `demo/example/zenoh-dart-pub-shm` | Key expression |
| `-p, --payload` | `Pub from Dart!` | Message payload |
| `--add-matching-listener` | false | Enable subscriber discovery |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

---

### z_get / z_queryable — Query/Reply

**Follows canon.**

**The pattern it demonstrates**

```
z_get:       open → get(selector) → await stream<Reply> → close          (one-shot query)
z_queryable: open → declareQueryable(key) → await query → reply → ...    (long-lived responder)
```

The request/response pattern. `z_get` sends a query with a selector and
receives a stream of replies. `z_queryable` declares a responder that
answers incoming queries.

As canon does, `z_get` splits its selector at `?` into a key expression and
a parameter string before querying, and validates the key expression before
opening the session. `?` is not legal inside a key expression, so a
selector like `demo/example/**?foo=bar` would otherwise be rejected
outright.

**Dart-specific adaptation**

zenoh-c uses callbacks for both sides. Dart uses `Stream<Reply>` for get
replies and `Stream<Query>` for queryable. The C shim extracts reply/query
fields during the synchronous callback (loaned-pointer lifetime constraint)
and posts them via NativePort.

**C shim case study:** The get/queryable implementation added 10 C shim
functions, of which several were barrier-justified but unreachable from the
Dart API — pull-accessors for data already pushed via NativePort. **Two of
those survive**: `zd_query_payload`, and `zd_query_sizeof` for an allocation
the shim handles internally. Both have a real Dart caller today, through the
direct bindings in the ownership test harness.

The other two did not survive, and the reason is worth more than the original
argument: `zd_query_parameters` was removed once the parameters path became
length-carrying, and `zd_query_keyexpr` with it — both returned a
`const char*` into the query's own storage, so a caller had no length and
could not carry an interior NUL. **A speculative accessor is not free when
its shape is wrong**; retaining one because "future examples may need it" is
what left two length-discarding traps exported for several releases.

```
z_get.dart       -s 'demo/example/**' -t BEST_MATCHING -o 10000
z_queryable.dart -k demo/example/zenoh-dart-queryable -p 'Queryable from Dart!' --complete
```

| Flag (z_get) | Default | Description |
|------|---------|-------------|
| `-s, --selector` | `demo/example/**` | Query selector |
| `-p, --payload` | -- | Optional query payload |
| `-t, --target` | `BEST_MATCHING` | `BEST_MATCHING`, `ALL`, `ALL_COMPLETE` |
| `-o, --timeout` | `10000` | Timeout in ms |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

| Flag (z_queryable) | Default | Description |
|------|---------|-------------|
| `-k, --key` | `demo/example/zenoh-dart-queryable` | Key expression |
| `-p, --payload` | `Queryable from Dart!` | Reply payload |
| `--complete` | false | Declare as complete queryable |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

---

### z_get_shm / z_queryable_shm — SHM Query/Reply

**Follows canon.**

**The pattern it demonstrates**

```
z_get_shm:       open → alloc → fill → toBytes → get(selector, payload: shmBytes) → await stream<Reply> → close
z_queryable_shm: open → declareQueryable(key) → await query → alloc → fill → toBytes → replyBytes → ...
```

SHM zero-copy variants of get and queryable. `z_get_shm` allocates an SHM
buffer for the query payload. `z_queryable_shm` allocates SHM for reply
payloads. Both use `ZBytes` (which can be SHM-backed) through the same
`Session.get()` and `Query.replyBytes()` APIs — no separate SHM query
path needed.

**Dart-specific note**

`ZBytes.isShmBacked`, from `zenoh_unstable.dart`, detects SHM backing. On a
native built without shared memory — the `stable` variant, and Android in
either variant — it throws `UnsupportedError` rather than answering.

The two examples differ on allocation failure, deliberately. `z_get_shm`
follows canon: it prints `Unexpected failure during SHM buffer
allocation...` and exits 255, because a query silently sent with no payload
at all would look like a healthy SHM run while never touching shared
memory. `z_queryable_shm` instead warns and replies with heap bytes, so the
demo keeps answering; its CLI test asserts that warning never appears, so
the degraded path cannot pass unnoticed.

**Neither makes canon's allocation call, and they diverge from different
starting points.** canon's queryable blocks (`z_queryable_shm.c:67`) while
canon's get uses the plain, non-waiting entry (`z_get_shm.c:70`,
`z_shm_provider_alloc`, which reports out-of-memory instead of waiting).
Both Dart examples await `allocGcDefragAsync`, which keeps the
garbage-collect-then-defragment retry without ever parking the isolate.
`allocGcDefragBlocking` is synchronous FFI: a request the pool can never
satisfy never returns, and nothing on that event loop runs again — including
a **signal handler**, which canon does not install and these examples do.
Both allocate once per query, so the window is as wide as the work they do.

`z_queryable_shm` uses canon's own 4096-byte pool exactly. `z_get_shm` cannot:
canon sizes that pool to the payload it then allocates (the payload length),
and a pool sized to its own allocation is always one allocation short of
satisfying it — a pool needs a constant headroom above what is allocated from
it. So `z_get_shm` sizes `max(2N, 4096)`, and that forced deviation is the only
one, measured across the range. Both examples previously floored at 65536 on
a claim that is measured false.

```
z_get_shm.dart       -s 'demo/example/**' -p 'Query from SHM!'
z_queryable_shm.dart -k demo/example/zenoh-dart-queryable -p 'Queryable from Dart SHM!'
```

Flags are those of their non-SHM counterparts above, except the payload
defaults: `z_get_shm` sends `'Get from Dart SHM!'` when `-p` is not given,
where canon's `z_get_shm` has no default payload, and `z_queryable_shm`
replies `'Queryable from Dart SHM!'`.

---

### z_pull — Pull Subscriber

**Deviates from canon:** C-side ring buffer.

**The pattern it demonstrates**

```
z_pull: open → declarePullSubscriber(key, capacity) → [user presses Enter → tryRecv()] loop
                                                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                                       synchronous poll, no stream (pull, not push)
```

On-demand polling of buffered samples. Each input character drives exactly
one `tryRecv()`, as in canon (`z_pull.c:74-86`) — so one keypress yields at
most one sample, and the on-demand, sample-at-a-time character of the
pattern stays visible. `tryRecv()` returns `RecvData` carrying the **oldest
retained** sample, or `RecvEmpty` when the ring is empty. The ring is lossy:
when full it drops the oldest entry, so what survives is the newest window of
traffic.

On end-of-input the example idles at `-i/--interval` seconds and keeps
running, rather than exiting — again matching canon.

**Key architectural decision**

The ring buffer lives in C, not Dart. The reason is **freshness**.

If the ring buffer sat in Dart (after NativePort delivery), all samples
would cross the FFI boundary — including ones destined to be dropped.
When Dart's event loop stalls (GC pause, Flutter frame render), the
"surviving" samples in a Dart-side ring are stale: they were recent
when C posted them, but old by the time Dart processes them.

With a C-side ring buffer, drops happen before NativePort. Only surviving
samples cross FFI. If Dart stalls for 500ms and a sensor publishes at
100Hz, the 3 samples in a C-side ring of capacity 3 are from the last
30ms. In a Dart-side ring, they would be 500ms old.

```
C-side:  zenoh thread -> [ring buffer, drops oldest] -> tryRecv() -> Dart
Dart-side: zenoh thread -> NativePort -> [ring buffer] -> Dart
                                          ^^^^^^^^^^^^
                                          samples already stale if Dart stalled
```

**The "fat tryRecv" pattern:** `zd_pull_subscriber_try_recv()` is a
single synchronous FFI call that performs receive, loan, field extraction,
and drop internally. One FFI round-trip per poll. Dart never holds a
sample handle. This mirrors the NativePort push pattern (extract
everything in C) but inverts control — Dart pulls instead of C pushing.

**Return code note:** `z_try_recv()` returns positive codes -- **0 = OK,
1 = disconnected (`Z_CHANNEL_DISCONNECTED`), 2 = no data
(`Z_CHANNEL_NODATA`)** -- unlike the usual zenoh-c convention of negative
errors. They are the only positive result codes in the whole zenoh-c API,
and they sit outside the negative error space deliberately: they are
*states a consumer switches on*, not failures. The Dart side uses explicit
value checks, not the `!= 0` pattern used elsewhere.

Those three codes reach the caller as `RecvData` / `RecvDisconnected` /
`RecvEmpty` -- a sealed result, switched over exhaustively with no
`default` arm. That is what makes canon's own polling idiom writable:
back off on empty, exit on disconnected. A call *failure* (an allocation
the shim could not satisfy) is not one of these states and throws
`ZenohException` instead.

```
z_pull.dart -k 'demo/example/**' -s 3
```

| Flag | Default | Description |
|------|---------|-------------|
| `-k, --key` | `demo/example/**` | Key expression |
| `-s, --size` | `3` | Channel capacity (negative is rejected) |
| `-i, --interval` | `5` | Seconds to idle per poll once stdin reaches EOF |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

---

### z_queryable_with_channels / z_non_blocking_get — Query/Reply Over Bounded Channels

**Follows canon.**

**The pattern it demonstrates**

```
z_queryable_with_channels: open → declarePullQueryable(key, fifo, 16) → [await recv() → reply] loop → close
z_non_blocking_get:        open → pullGet(selector, fifo, 16) → [tryRecv(), back off when empty] until disconnected → dispose → close
```

The channel forms of `z_queryable` and `z_get`. Where those two deliver
through a `Stream`, these take a **bounded** pull handle — a fifo channel of
capacity 16, as canon's own examples use — and read from it at their own pace.
A slow consumer holds at most the channel's capacity rather than a queue that
grows with traffic, which makes these the back-pressured forms of query and
reply.

**Dart-specific note**

`z_non_blocking_get` is canon's polling loop. `tryRecv()` returns a sealed
`RecvResult`, switched over with no `default` arm: `RecvData` prints the reply,
`RecvEmpty` waits 50 ms and polls again, and `RecvDisconnected` — the query
complete — ends the loop, which is canon's own exit condition rather than a
timer or a reply count. As in `z_get`, canon's `-o 0` ("use the configured
default query timeout") is passed on as `timeout: null`.

`z_queryable_with_channels` replaces canon's blocking `z_recv()` with an
awaited `recv()`: the same contract — a query as soon as one is buffered,
`RecvDisconnected` when the channel ends, never `RecvEmpty` — with no thread
parked, so the example's signal handlers keep running while it waits.

```
z_queryable_with_channels.dart -k demo/example/zenoh-dart-queryable -p 'Queryable from Dart!'
z_non_blocking_get.dart        -s 'demo/example/**' -t BEST_MATCHING -o 10000
```

| Flag (z_queryable_with_channels) | Default | Description |
|------|---------|-------------|
| `-k, --key` | `demo/example/zenoh-dart-queryable` | Key expression |
| `-p, --payload` | `Queryable from Dart!` | Reply payload |
| `--complete` | false | Declare as complete queryable |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

| Flag (z_non_blocking_get) | Default | Description |
|------|---------|-------------|
| `-s, --selector` | `demo/example/**` | Query selector |
| `-p, --payload` | -- | Optional query payload |
| `-t, --target` | `BEST_MATCHING` | `BEST_MATCHING`, `ALL`, `ALL_COMPLETE` |
| `-o, --timeout` | `10000` | Timeout in ms |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

---

### z_info / z_scout — Session Info and Discovery

**Follow canon.**

**The pattern it demonstrates**

```
z_info:  open → zid → routersZid() → peersZid() → close   (session introspection)
z_scout: scout(config) → List<Hello> → print               (no session needed)
```

`z_info` prints the session's own ZenohId and the IDs of connected
routers and peers. `z_scout` discovers zenoh entities on the network
without opening a session.

**Dart-specific notes**

`ZenohId.toHexString()` does hex conversion in pure Dart — no FFI call,
despite `zd_id_to_string` existing in the C shim. It renders **canon's
exact form** (digit order `bytes[15]`→`bytes[0]`, leading zeros stripped
per hex digit, the all-zero id as `"0"`), re-implemented rather than
delegated so that an id renders without the native library being loaded
and `toString()` can never throw — `ZenohId` is an immutable value that
outlives its session and is printed by every log line. `zd_id_to_string`
is not dead: it is the **test oracle** (`test/id_rendering_oracle_test.dart`)
that keeps the two implementations honest, which a delegating
implementation could not have, since comparing a value with itself proves
nothing.

`Zenoh.scout()` uses a NativePort variant: the C shim posts
`[zid, whatami, locators]` per discovered entity, then a null sentinel
on completion. Dart collects into `List<Hello>` via a `Completer`.

Router/peer ZID collection (`Session.routersZid()`, `Session.peersZid()`)
uses a synchronous buffer-based C closure (not NativePort) — canon's own
enumeration blocks and completes before returning, so a synchronous FFI
call is the faithful shape. This is the only callback pattern in the
binding that does not use NativePort.

The buffer is **shim-owned and unbounded**: it grows by `realloc` inside
the collection closure (capacity 0 → 1 → 2 → 4 → …, the same policy as
zenoh-cpp's `std::vector<Id>` collector), and the shim hands Dart a
pointer plus an out-**count of ids**, which Dart copies and then releases
through the designated drop entry `zd_zid_list_drop`. An empty
enumeration allocates nothing at all. A shim-side allocation failure is
reported, never silently truncated, and never presented as an empty
list.

```
z_info.dart
z_scout.dart
```

| Flag | Default | Description |
|------|---------|-------------|
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

---

### z_querier — Declared Querier

**Follows canon.**

**The pattern it demonstrates**

```
z_querier: open → declareQuerier(selector, target, timeout) → [get() → stream<Reply>] loop → close
                   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                   fixed options at declaration, per-query payload varies
```

A long-lived querier entity for repeated queries. Declaration-time options
(target, consolidation, timeout) are fixed at creation; per-query options
(payload, encoding) vary per `get()` call. The loop is strictly serial, as
canon's is: sleep one second, issue one query, drain its replies to
completion, then advance the index. A fixed-rate timer would let queries
overlap whenever a drain outlasts the interval — roughly ten in flight at
the default 10 s timeout with no responder — and would print repeating
sequence numbers. Includes a matching listener
for queryable discovery. Mirrors `Publisher` structurally — both are declared entities with
fixed options and per-operation parameters. `Querier.get()` returns
`Stream<Reply>` reusing the same reply callback infrastructure as
`Session.get()`.

```
z_querier.dart -s 'demo/example/**' -t BEST_MATCHING --add-matching-listener
```

| Flag | Default | Description |
|------|---------|-------------|
| `-s, --selector` | `demo/example/**` | Query selector |
| `-p, --payload` | -- | Optional query payload |
| `-t, --target` | `BEST_MATCHING` | `BEST_MATCHING`, `ALL`, `ALL_COMPLETE` |
| `-o, --timeout` | `10000` | Timeout in ms |
| `--add-matching-listener` | false | Enable queryable discovery |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

---

### z_liveliness / z_sub_liveliness / z_get_liveliness — Liveliness

**Follow canon.**

**The pattern it demonstrates**

```
z_liveliness:     open → declareLivelinessToken(key) → ... → close       (announce presence)
z_sub_liveliness: open → declareLivelinessSubscriber(key) → stream<Sample> → ...
                                                            PUT = appeared, DELETE = gone
z_get_liveliness: open → livelinessGet(key) → stream<Reply> → close      (snapshot query)
```

Entity presence detection. `z_liveliness` declares a token announcing the
entity is alive. `z_sub_liveliness` subscribes to token changes (PUT on
appearance, DELETE on disappearance or connectivity loss).
`z_get_liveliness` queries currently alive tokens.

**Dart-specific note**

All three reuse existing callback infrastructure — `z_sub_liveliness`
reuses the sample callback/drop pair from regular subscribers;
`z_get_liveliness` reuses the reply callback/drop pair from `Session.get()`.
No new callback patterns introduced.

`z_liveliness`'s default key substitutes the language token in canon's
`group1/zenoh-rs` — the C example keeps the Rust binding's token — so it
declares `group1/zenoh-dart`.

```
z_liveliness.dart     -k group1/zenoh-dart
z_sub_liveliness.dart -k 'group1/**' --history
z_get_liveliness.dart -k 'group1/**' -o 10000
```

| Flag (z_liveliness) | Default | Description |
|------|---------|-------------|
| `-k, --key` | `group1/zenoh-dart` | Key expression |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

| Flag (z_sub_liveliness) | Default | Description |
|------|---------|-------------|
| `-k, --key` | `group1/**` | Key expression |
| `--history` | false | Get existing tokens on subscribe |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

| Flag (z_get_liveliness) | Default | Description |
|------|---------|-------------|
| `-k, --key` | `group1/**` | Key expression |
| `-o, --timeout` | `10000` | Timeout in ms |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

---

### z_ping / z_pong — Latency Benchmark

**Follow canon.**

**The pattern it demonstrates**

```
z_pong: open → bgSubscriber(test/ping) → publisher(test/pong) → [recv → echo] loop   (responder)
z_ping: open → publisher(test/ping) → bgSubscriber(test/pong) → [publish → await pong → measure] loop
                                                                  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                                                  Completer resets each iteration
```

Round-trip latency measurement. `z_pong` echoes every message received
on `test/ping` back to `test/pong`. `z_ping` publishes a payload, waits
for the echo, and measures the round-trip time.

**What's new (added to the project)**

- `Session.declareBackgroundSubscriber()` — fire-and-forget subscriber
  returning `Stream<Sample>`, lives until session closes, no explicit
  close needed
- `Publisher.isExpress` parameter — disables message batching for lower
  latency
- `ZBytes.clone()` — shallow ref-counted copy (near-zero cost)
- `ZBytes.toBytes()` — read content as `Uint8List`

`z_pong` uses a background subscriber (no handle management) with an
express publisher (no batching delay). `z_ping` uses a `Completer` that
resets each iteration to synchronize the ping/pong round-trip — the Dart
equivalent of C's condition variable wait.

```
z_pong.dart
z_ping.dart 64 -n 100 -w 1000
```

| Flag (z_pong) | Default | Description |
|------|---------|-------------|
| `--no-express` | false | Disable express mode |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

| Flag (z_ping) | Default | Description |
|------|---------|-------------|
| `<PAYLOAD_SIZE>` | (required) | Payload size in bytes |
| `-n, --samples` | `100` | Number of ping measurements |
| `-w, --warmup` | `1000` | Warmup time in ms |
| `--no-express` | false | Disable express mode |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

**Output format:** `<size> bytes: seq=<i> rtt=<us>µs, lat=<us>µs`,
printed after the measurement loop finishes so stdout I/O never lands
between two measured pings.

**What the window contains.** `z_ping` builds the payload *before* starting
the stopwatch, as canon does (`z_ping.c:96-98`): the native allocation and
copy are not part of the round-trip. `z_ping_shm` deliberately keeps its
`clone()` *inside* the window, also as canon does — there the ref-counted
clone is the operation shared memory exists to make cheap.

---

### z_ping_shm — SHM Latency Benchmark

**Composition example.** Zero new C shim functions, zero new Dart API.
Composes from `z_pub_shm`, `z_ping/z_pong`, `ZBytes.clone()`, and
`ZBytes.isShmBacked`.

**What's new**

- 1 CLI example: `z_ping_shm.dart` — allocate-once, clone-in-loop SHM
  benchmark
- ~10 tests: SHM clone integration (6) + CLI tests (4)

**Key architectural decision**

The phase spec mentions `ShmBuffer` / `toImmutable()` as an intermediate
type. This binding skips it — the existing `ShmMutBuffer.toBytes()`
already calls `z_bytes_from_shm_mut` which produces SHM-backed bytes
directly. The intermediate `z_owned_shm_t` type is a C API artifact for
explicit type transitions that Dart does not need. Adding `ShmBuffer`
would be dead API surface with no consumer.

**The pattern it demonstrates**

```
z_pub_shm:  alloc -> fill -> toBytes -> publish         (per iteration -- expensive)
z_ping_shm: alloc -> fill -> toBytes -> clone -> publish (clone in loop -- near free)
```

**The allocation is not canon's call.** canon uses the plain, non-waiting
entry (`z_ping_shm.c:78`); this example awaits `allocGcDefragAsync`, having
previously used `allocGcDefragBlocking` — a synchronous-FFI entry that parks
the whole isolate and, on a request the pool can never satisfy, never returns
at all. A parked isolate answers nothing, a **signal handler** included, and
canon installs none. Exposure here is at the low end: one allocation at
startup, before the measured loop.

The allocate-once, clone-in-loop pattern is the production SHM
optimization. `ZBytes.clone()` increments a reference count rather than
copying the payload — which is what makes it flat in payload size.

**Measured**, interleaved on an idle host, against reconstructing the payload
instead:

| payload | `clone()` | rebuild from bytes |
|---|---|---|
| 1 MiB | 2.9–3.1 µs | 87–96 µs |
| 64 KiB | 2.2 µs | 5.0 µs |
| 4 KiB | 2.2 µs | 1.9 µs |

The **flatness** is the point, not the ratio: a clone costs the same at every
size, a copy scales. ⚠️ It is **not free** — roughly 2–3 µs and a small
allocation for the wrapper — so below about 8 KiB it wins nothing, and at
4 KiB it is marginally slower than simply copying. "Zero-copy" is a claim
about **allocation volume**, not a promise of lower latency at every size.

**Test gap it fills**

No prior test covers `ZBytes.clone()` on SHM-backed bytes, or verifies
`isShmBacked` on `ShmMutBuffer.toBytes()` output. This example's test
suite closes that gap.

```
z_ping_shm.dart 64 -n 100 -w 1000
```

| Flag | Default | Description |
|------|---------|-------------|
| `<PAYLOAD_SIZE>` | (required) | SHM payload size in bytes |
| `-n, --samples` | `100` | Number of ping measurements |
| `-w, --warmup` | `1000` | Warmup time in ms |
| `--no-express` | false | Disable express mode |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

**Pong side:** Reuses `z_pong.dart` unchanged. The pong subscriber
receives bytes transparently (SHM or heap) and echoes them back.

---

### z_pub_thr / z_sub_thr / z_pub_shm_thr — Throughput Benchmarks

**Composition examples.** Zero new C shim functions, zero new Dart API.
Compose from `Publisher` with `CongestionControl.block`, `Session.declareBackgroundSubscriber()`,
`ShmProvider`, `ShmMutBuffer`, and `ZBytes.clone()`.

**The pattern they demonstrate**

```
z_pub_thr:     open → declarePublisher(test/thr, block) → [putBytes(clone)] tight loop
z_sub_thr:     open → bgSubscriber(test/thr) → count msgs per round → print throughput
z_pub_shm_thr: open → declarePublisher(test/thr, block) → alloc once → [putBytes(clone)] tight loop
                                                                         ^^^^^^^^^^^^^^^^
                                                                         clone in loop (near-zero cost)
```

`z_pub_thr` builds a heap `ZBytes` once and clones it each iteration —
same clone-in-loop pattern as `z_ping_shm`, applied to bulk throughput.
`z_sub_thr` uses a background subscriber to count messages asynchronously;
after each round of `--number` messages it prints the throughput in msg/s
and prints a summary on exit. `z_pub_shm_thr` is the SHM variant: allocates
a single `ShmMutBuffer` once, converts to `ZBytes`, then clones per
iteration for zero-copy publish.

**Dart-specific note**

`z_pub_shm_thr`'s allocation is not canon's call: canon uses the plain,
non-waiting entry (`z_pub_shm_thr.c:61`) and this example awaits
`allocGcDefragAsync`, having previously used `allocGcDefragBlocking` — which
is synchronous FFI, parks the whole isolate, and never returns at all on a
request the pool can never satisfy. A parked isolate runs nothing else, a
**signal handler** included, and canon installs none anywhere. Exposure is at
the low end: one allocation at startup, before the publish loop.

`z_sub_thr` enables `transport/shared_memory/enabled` in config so it can
receive SHM-backed payloads from `z_pub_shm_thr` transparently in the same
process. The `Stopwatch`-based measurement follows the zenoh-c reference
implementation's round structure.

```
z_pub_thr.dart     8192 --express
z_sub_thr.dart     -s 10 -n 1000000
z_pub_shm_thr.dart 8192 -s 32
```

| Flag (z_pub_thr) | Default | Description |
|------|---------|-------------|
| `<PAYLOAD_SIZE>` | (required) | Payload size in bytes |
| `-p, --priority` | `5` | Priority (1–7, Z_PRIORITY_DATA = 5) |
| `--express` | false | Enable express mode (disable batching) |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

| Flag (z_sub_thr) | Default | Description |
|------|---------|-------------|
| `-s, --samples` | `10` | Number of measurement rounds |
| `-n, --number` | `1000000` | Messages per round |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

**Output format (z_sub_thr):** `<throughput> msg/s` per round, then `sent <N> messages over <t> seconds (<overall> msg/s)` on exit.

| Flag (z_pub_shm_thr) | Default | Description |
|------|---------|-------------|
| `<PAYLOAD_SIZE>` | (required) | SHM payload size in bytes |
| `-s, --shared-memory` | `32` | SHM pool size in MB |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

---

### z_bytes — Serialization Round-Trip Demo

**Follows canon.**

**What's new**

- 1 CLI example: `z_bytes.dart` — serialization round-trip validation
  (no network operations)
- ~61 tests: serializer lifecycle (6), arithmetic types (6), compound
  types (5), deserializer round-trips (19), composite sequences (4),
  convenience methods (7), writer (6), slice iterator (4), error
  handling (3), CLI (1)
- Extended later with six further sections: the single-shot conversions
  for every scalar width, and the encoding's schema surface

**The pattern it demonstrates**

```
z_bytes: ZSerializer → serialize types → finish → ZDeserializer → deserialize → verify
         ZBytesWriter → writeAll/append → finish → slices → iterate fragments
         ZBytes.fromInt(42) → toInt() == 42   (convenience, uses serializer internally)
         ZBytes.fromUint8/16/32/64 · fromInt8/16/32 · fromFloat → to*() (single-shot, every width)
         Encoding.withSchema('') vs .withSchema('x') vs no schema → three distinct wire states
```

Pure serialization — no sessions, no network. Validates cross-language
wire format compatibility: a Dart-serialized uint32 produces the same
bytes as zenoh-c's `ze_serialize_uint32`, enabling interop between
language bindings.

**Dart-specific note**

The C example uses `z_bytes_reader_*` for reading back writer output.
The reader API is deferred in Dart — `toBytes()` reads the full payload
instead. Every other canon section is present, including the int32
sequence, the custom struct (float + nested 2x3 uint64 sequences + string)
and the slice iterator, which prints each slice exactly as canon does and
asserts that three appended payloads stay three slices. The C
`ze_serialize_*` / `ze_deserialize_*` one-shot functions are not bound:
the Dart single-shot forms compose over `ZSerializer` / `ZDeserializer`
instead, and that composition was **measured byte-identical to canon's
one-shot output** across all eleven scalar widths and the string form, so
the carve rests on measurement rather than assertion.

Two sections go beyond canon's own file, because canon's does not
demonstrate them. `z_bytes.c` uses the one-shot family only for `uint32`
(`:69`) and only *mentions* the encoding constants, in comments
(`:49-50`, `:60-61`, `:73-74`). Here every scalar width gets a
single-shot round-trip at both ends of its domain, and the encoding's
schema is exercised across all three states canon distinguishes —
absent, present-but-empty, and present — which differ on the wire by
exactly a trailing separator.

```
z_bytes.dart
```

No flags — canon's `z_bytes.c` has none either, so the common block does
not apply here. Runs all sections, prints PASS/FAIL for each, and exits
nonzero if any section failed (canon compiles with `#undef NDEBUG`, so a
mismatch aborts the process there).

---

### z_storage — In-Memory Storage

**Follows canon.**

**What's new**

- 1 CLI example: `z_storage.dart` — in-memory key-value store
- ~6 tests: CLI startup (3), end-to-end integration (3)
- 3 new C shim functions: `zd_keyexpr_intersects`, `zd_keyexpr_includes`,
  `zd_keyexpr_equals`
- `KeyExpr.intersects()`, `includes()`, `equals()` methods on existing class

**The pattern it demonstrates**

```
z_storage: open → declareSubscriber(key) + declareQueryable(key)
                   │                        │
                   ▼                        ▼
           stream<Sample> → Map[key]=sample query → intersects(stored) → reply
                            (PUT stores, DELETE removes)
```

Combines a subscriber and a queryable into an in-memory storage. The
subscriber stores incoming PUT samples in a `Map<String, Sample>` and
removes entries on DELETE. The queryable responds to queries by iterating
stored entries and replying with those whose key expression intersects
the query's key expression.

Replies carry a **refcount clone** of the stored payload, not a copy of
it. The subscriber is declared with `retainPayload: true`, so each stored
`Sample` keeps an owned `payloadZBytes` handle on the payload the network
delivered, and the queryable replies with `payloadZBytes.clone()` —
`ZBytes.clone()` **is** canon's `z_bytes_clone` (`z_storage.c:92-94`), a
reference-count bump. Canon clones twice, `z_sample_clone` into the store
and `z_bytes_clone` into the reply; what Dart stores is the delivered
`Sample`, whose other fields are already this process's own copies, so the
payload clone is the one left to perform. The raw-bytes route this
replaced made a full heap copy of every stored value on every matching
reply, and replying from `Sample.payload` — the lenient UTF-8 display
view — would additionally re-encode every invalid sequence as U+FFFD and
silently corrupt any binary value the store holds.

Retention also makes the store a holder of native handles, so it owns
their release: a DELETE releases the handle it evicts (and the DELETE
sample's own), a PUT to a key already stored releases the one it replaces,
and shutdown releases whatever is left — canon's `storage_drop`.

**Dart-specific note**

The key expression matching (`KeyExpr.intersects`) is delegated to the
C shim, which calls `z_keyexpr_intersects()` on loaned key expressions.
This ensures matching semantics are identical to zenoh-c's implementation.
The storage map is pure Dart — no C-side data structures.

```
z_storage.dart -k 'demo/example/**'
```

| Flag | Default | Description |
|------|---------|-------------|
| `-k, --key` | `demo/example/**` | Key expression |
| `--complete` | false | Declare queryable as complete |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

---

### z_advanced_pub / z_advanced_sub — Advanced Pub/Sub

**Deviates from canon:** flattened options hierarchy, no `Session.ext()`,
Dart-side key expression storage, bundled miss listener declaration.
*(Cache options are no longer a deviation: the body below records that Dart
now reaches the same nested shape zenoh-cpp does.)*

This is the most complex feature phase in the project. The zenoh-c
advanced API uses 47 functions, 8 nested options structs, and a new
closure type (`ze_owned_closure_miss_t`). The Dart binding selectively
wraps a subset of these functions through 5 architectural decisions that
diverge from the C/C++ pattern.

**What's new**

- 2 CLI examples: `z_advanced_pub.dart`, `z_advanced_sub.dart`
- C shim functions guarded by `#if defined(Z_FEATURE_UNSTABLE_API)`, so
  they ship in the `unstable` variant, on Linux and Android alike
- `AdvancedPublisher`, `AdvancedPublisherOptions`, `HeartbeatMode`,
  `AdvancedSubscriber`, `AdvancedSubscriberOptions`, `MissEvent` types
- `Session.declareAdvancedPublisher()`, `Session.declareAdvancedSubscriber()`
- ~38 tests: publisher lifecycle (7), put/delete (5), options (6),
  subscriber lifecycle (7), integration/history (5), miss listener (4),
  CLI (5)

**The pattern it demonstrates**

```
z_advanced_pub: config(timestamping=true) → open → declareAdvancedPublisher(key, opts)
                                                        │
                                                        ▼
                                              loop: put("[idx] payload")
                                              (cache stores last N, heartbeat sends seq numbers)

z_advanced_sub: open → declareAdvancedSubscriber(key, opts)
                         │                        │
                         ▼                        ▼
                  stream<Sample>          missEvents<MissEvent>
                  (history + live)        (gap detection via seq numbers)
```

Advanced publisher adds three capabilities beyond the regular publisher:
(1) **cache** — stores last N samples for late-joining subscriber history
retrieval, (2) **publisher detection** — announces presence via liveliness
tokens, (3) **sample miss detection** — sequence numbering with optional
heartbeats so subscribers detect gaps.

Advanced subscriber adds three corresponding capabilities:
(1) **history** — queries cached samples from advanced publishers on
connect, (2) **recovery** — detects sequence gaps and requests
retransmission from publisher cache, (3) **miss listener** — streams
`MissEvent` notifications (source ZenohId + count).

**Key architectural decisions**

**1. Flattened options hierarchy.** zenoh-c uses deeply nested options:
`ze_advanced_publisher_options_t` contains
`ze_advanced_publisher_cache_options_t` (5 fields, requires separate
`_default()` call) and
`ze_advanced_publisher_sample_miss_detection_options_t` (3 fields,
separate `_default()` call), each with an `is_enabled` boolean plus
sub-fields. The subscriber side is similarly nested (3 levels deep:
options → recovery → last_sample_miss_detection). The C shim flattens
ALL of this into scalar parameters:

```
zenoh-c (hierarchical):
  opts.cache.is_enabled = true;
  opts.cache.max_samples = 10;
  opts.cache.congestion_control = Z_CONGESTION_CONTROL_DROP;
  opts.sample_miss_detection.is_enabled = true;
  opts.sample_miss_detection.heartbeat_mode = PERIODIC;
  opts.sample_miss_detection.heartbeat_period_ms = 500;

C shim (flat):
  zd_declare_advanced_publisher(session, pub, ke,
      /*enable_cache*/ true, /*cache_max_samples*/ 10,
      /*publisher_detection*/ true, /*sample_miss_detection*/ true,
      /*heartbeat_mode*/ 1, /*heartbeat_period_ms*/ 500);
```

The C shim internally calls each sub-struct's `_default()` initializer
when the corresponding boolean is true, so deferred fields
(`congestion_control`, `priority`, `is_express` on cache;
`query_timeout_ms` on subscriber) get correct zenoh-c defaults. This
matches our established pattern (see `zd_declare_publisher` with its 7
scalar parameters) and avoids exposing 8 nested C structs through FFI.

**2. No `Session.ext()`.** zenoh-cpp accesses advanced features via
`session.ext().declare_advanced_publisher()`, where `SessionExt` is a
C++ template specialization wrapping the same session. Dart has no
equivalent of C++ header-level extension mechanisms. An `.ext()` accessor
would add an indirection layer with no benefit — our `Session` class
already has 17+ methods, and the `Advanced` prefix on the method name
provides sufficient disambiguation. Both methods are placed directly on
`Session`.

**3. Dart-side key expression storage.** zenoh-c exposes
`ze_advanced_publisher_keyexpr()` to read the key expression back from
the native entity. zenoh-cpp wraps this as `get_keyexpr()`. Our Dart
binding stores the key expression string at construction time (passed
through from `declareAdvancedPublisher()`) and returns it as a property
— no FFI call. This avoids a pointer lifetime concern: the C function
returns a `const z_loaned_keyexpr_t*` that borrows from the publisher,
so if the publisher is dropped between the C call and Dart reading the
string, the pointer is dangling. Storing at construction is simpler
and matches our regular `Publisher`, `Querier`, and `PullSubscriber`
pattern — none of them call back to C for their key expression.

**4. Bundled miss listener declaration.** In zenoh-c (and zenoh-cpp),
the miss listener is declared as a separate API call after the subscriber
exists:

```c
ze_declare_advanced_subscriber(..., &sub, ...);       // step 1
ze_advanced_subscriber_declare_background_sample_miss_listener(
    z_loan(sub), z_move(miss_callback));              // step 2
```

Dart bundles this into the `AdvancedSubscriber.declare()` factory via an
`enableMissListener` field in `AdvancedSubscriberOptions`. When true, the
factory creates two NativePort pairs (samples + miss events), declares
the subscriber, then immediately declares the miss listener. If step 2
fails, step 1 is cleaned up (subscriber dropped, ports closed). This
gives the consumer a single `declareAdvancedSubscriber()` call instead
of two — matching Dart API ergonomics where factories handle multi-step
native setup.

**5. Nested cache options.** zenoh-c uses separate
`cache.is_enabled` (bool) + `cache.max_samples` (size_t) fields.
zenoh-cpp uses `std::optional<CacheOptions>`. Dart reaches the same
shape: `AdvancedPublisherOptions.cache` is an
`AdvancedPublisherCacheOptions?`, whose **presence** carries the enable
axis, and whose `int? maxSamples` carries the bound (`null` = canon
decides). The invalid combination — a bound with no cache — is
unrepresentable.

This replaced an earlier single `int? cacheMaxSamples`, where one
nullable field carried both axes and `0` was documented as "unlimited".
It is not: measured against zenoh-c 1.8.0, an explicit `0` lets a
late-joining history subscriber recover exactly **one** of five pre-join
samples — identical to leaving the field unspecified, because canon's
default is `1`. (Canon documents `0` as "no limit" on the *subscriber*'s
history bound; the old text borrowed that sentinel from the wrong side
of the contract.) Zero stays expressible and passes through verbatim;
a negative bound throws `ArgumentError` before any native call.

**Miss callback pattern**

The miss listener introduces a new callback type
(`ze_owned_closure_miss_t`) that follows the established NativePort
bridge pattern. The C shim callback:

1. Receives `const ze_miss_t* miss` with `miss->source`
   (`z_entity_global_id_t`) and `miss->nb` (`uint32_t`)
2. Extracts ZID: `z_id_t zid = z_entity_global_id_zid(&miss->source)`
3. Posts raw 16-byte ZID as `Dart_TypedData_kUint8` + `nb` as `int64`
4. Dart constructs `MissEvent(sourceId: ZenohId(bytes), count: nb)`

The raw-bytes approach matches the scout callback pattern (Phase 5) —
`ZenohId` is constructed from a 16-byte `Uint8List`, not parsed from a
hex string. The C example converts to hex for printing; we defer
conversion to `ZenohId.toHexString()` on the Dart side.

**Sample callback reuse**

The advanced subscriber uses the same `z_owned_closure_sample_t` as the
regular subscriber. `AdvancedSubscriber.declare()` calls
`Subscriber.createSampleChannel()` directly — the same factory that
creates the NativePort + StreamController pair for regular subscribers.
This means advanced and regular subscribers share identical sample
delivery code paths. The `_zd_sample_callback` / `_zd_sample_drop` pair
is reused without modification.

**Feature flag guard**

The advanced C shim functions are guarded by
`#if defined(Z_FEATURE_UNSTABLE_API)` — the `ze_*` namespace requires
this flag. The `unstable` variant defines it on Android as well as Linux,
so the advanced API ships in Android's `unstable` libraries; what Android
lacks, in both variants, is shared memory (`hook/build.dart` states the
mapping).

**Deferred API surface**

10 zenoh-c options fields are deliberately not exposed in this phase:

| Deferred | Why |
|----------|-----|
| `publisher_detection_metadata` | **Carved** (2026-08-19): unstable-API-by-decision, no consumer trigger to add. Announce-side only — the *observe* side is already transparent, since an announced metadata key expression arrives verbatim in the detect token's trailing segment |
| `subscriber_detection_metadata` | **Carved**, as the publisher-side row |
| `put_options` (encoding, attachment) | Matches regular Publisher deferral |
| `delete_options` | No fields beyond base options |
| Cache QoS (`congestion_control`, `priority`, `is_express`) | Uses zenoh-c defaults |
| `query_timeout_ms` | 0 = internal default |
| History `max_samples`, `max_age_ms` | 0 = no limit (this really is documented on the *subscriber* side — see the cache note above for the field where that sentinel does **not** apply) |
| `ze_advanced_subscriber_detect_publishers()` | **Superseded** — the *background* form is now bound as `AdvancedSubscriber.detectedPublishers`. The foreground form stays carved under the cancelable-Stream-renders-listener-handle idiom, with its cost stated in that member's dartdoc: it is canon's only way to reclaim the native liveliness subscription before session close, so the divergence here is larger than for any other instance of that idiom |
| `ze_advanced_publisher_declare_matching_listener()` | **Superseded** — the *background* form is now bound as `AdvancedPublisher.matchingStatus`. The foreground form is carved; canon's own docs bind its handle to the publisher's lifetime, so a cancelable Stream renders it |
| `ze_declare_background_advanced_subscriber()` | Background variant — defer |

These can be added in patch releases without breaking changes.

```
z_advanced_pub.dart -k demo/example/zenoh-dart-pub -i 10
z_advanced_sub.dart -k 'demo/example/**'
```

| Flag (z_advanced_pub) | Default | Description |
|------|---------|-------------|
| `-k, --key` | `demo/example/zenoh-dart-pub` | Key expression |
| `-p, --payload` | `Pub from Dart!` | Payload string |
| `-i, --history` | `1` | Cache size (number of samples) |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

| Flag (z_advanced_sub) | Default | Description |
|------|---------|-------------|
| `-k, --key` | `demo/example/**` | Key expression (wildcard) |
| *[common flags](#common-flags)* | -- | `-c`, `-m`, `-e`, `-l`, `--cfg`, `--no-multicast-scouting`, `-h` |

**Note:** The zenoh-c subscriber example hardcodes its options (history,
late-publisher detection, recovery, last-sample miss detection, subscriber
detection, miss listener) with no CLI flags for individual options, and our
Dart example sets exactly the same set.

One option is deliberately *not* set on either side:
`periodic_queries_period_ms`. Canon's line for it exists but is commented
out — "use publisher heartbeats by default, otherwise enable periodic
queries as follows" (`z_advanced_sub.c:72-73`) — so recovery is
heartbeat-driven, matching the paired publisher's 500 ms heartbeat. zenoh-c
documents periodic queries as useless when the publication period is at or
below the query period, which is precisely this pair's regime. The
publisher example exposes `-i`/`--history` for cache size. canon's help
text names the same flag, but its parser registers the long form as
`--hisotry` (`z_advanced_pub.c:106`), so canon accepts `-i` and
`--hisotry` where this example accepts `-i` and `--history`.

---

## Coverage Map

Which zenoh-c examples does this binding implement, and which are absent?

| zenoh-c Example | zenoh-dart | Status |
|-----------------|------------|--------|
| `z_put.c` | `z_put.dart` | Implemented |
| `z_delete.c` | `z_delete.dart` | Implemented |
| `z_sub.c` | `z_sub.dart` | Implemented |
| `z_pub.c` | `z_pub.dart` | Implemented |
| `z_pub_shm.c` | `z_pub_shm.dart` | Implemented |
| `z_info.c` | `z_info.dart` | Implemented |
| `z_scout.c` | `z_scout.dart` | Implemented |
| `z_get.c` | `z_get.dart` | Implemented |
| `z_queryable.c` | `z_queryable.dart` | Implemented |
| `z_get_shm.c` | `z_get_shm.dart` | Implemented |
| `z_queryable_shm.c` | `z_queryable_shm.dart` | Implemented |
| `z_pull.c` | `z_pull.dart` | Implemented (C-side ring buffer) |
| `z_querier.c` | `z_querier.dart` | Implemented |
| `z_liveliness.c` | `z_liveliness.dart` | Implemented |
| `z_sub_liveliness.c` | `z_sub_liveliness.dart` | Implemented |
| `z_get_liveliness.c` | `z_get_liveliness.dart` | Implemented |
| `z_ping.c` | `z_ping.dart` | Implemented |
| `z_pong.c` | `z_pong.dart` | Implemented |
| `z_ping_shm.c` | `z_ping_shm.dart` | Implemented |
| `z_sub_shm.c` | -- | Absent (transparent receive covered; SHM/RAW detection now EXISTS via `Sample.payloadZBytes` + `isShmBacked`, and `z_queryable_shm` prints it — no `z_sub_shm.dart` is added) |
| `z_bytes.c` | `z_bytes.dart` | Implemented |
| `z_queryable_with_channels.c` | `z_queryable_with_channels.dart` | Implemented |
| `z_non_blocking_get.c` | `z_non_blocking_get.dart` | Implemented |
| `z_advanced_pub.c` | `z_advanced_pub.dart` | Implemented |
| `z_advanced_sub.c` | `z_advanced_sub.dart` | Implemented |
| `z_pub_thr.c` | `z_pub_thr.dart` | Implemented |
| `z_sub_thr.c` | `z_sub_thr.dart` | Implemented |
| `z_pub_shm_thr.c` | `z_pub_shm_thr.dart` | Implemented |
| `z_storage.c` | `z_storage.dart` | Implemented |

**Current:** 28 implemented, 1 permanently absent, 0 future.

---

## Architectural Notes

### The NativePort Callback Bridge

zenoh-c delivers events (samples, replies, queries, scouting results)
via C callbacks invoked on zenoh's tokio worker threads. Dart isolates
are single-threaded and cannot receive foreign-thread callbacks directly.

The bridge works as follows:

1. Dart creates a `ReceivePort` and passes its `nativePort` (int64) to C
2. C stores the port in a heap-allocated context struct
3. When zenoh invokes the callback (on a tokio thread), the C shim:
   - Extracts all fields from the loaned pointer synchronously
   - Packs them into a `Dart_CObject` array
   - Calls `Dart_PostCObject_DL(port, &cobject)`
4. Dart's event loop receives the message and constructs the Dart object
5. When the entity is closed, zenoh calls the drop closure, which frees
   the context struct

The critical invariant: **loaned pointers are only valid during the
synchronous callback.** The C shim must extract data before returning.
No Dart-side API (`NativeCallable.listener`, `Pointer.fromFunction`) can
solve this — it is structural to zenoh-c's ownership model.

### The Sole Facade Principle

Dart has zero direct bindings to zenoh-c. The `ffigen.yaml` filters on
`zd_.*` — only symbols with the `zd_` prefix appear in `bindings.dart`.
Dart literally cannot see `z_get()`, `z_declare_queryable()`, or any
other zenoh-c function.

The alternative — dual-binding with selective shimming — was rejected
because almost every zenoh-c call chain hits at least one FFI barrier
(a loan, a move, an options init). Shimming the loan, calling the
function directly, then shimming the drop is worse than shimming the
whole operation. A single `zd_*` namespace eliminates "which do I call?"
confusion and removes the per-phase audit burden of classifying functions.

### Callback Reuse Across Examples

Several callback implementations are shared:

| Callback pair | Used by |
|---------------|---------|
| `_zd_sample_callback` / `_zd_sample_drop` | subscriber, liveliness subscriber, background subscriber, advanced subscriber |
| `_zd_reply_callback` / `_zd_get_drop` | `Session.get()`, `Querier.get()`, `Session.livelinessGet()` |
| `_zd_miss_callback` / `_zd_miss_drop` | `AdvancedSubscriber` miss listener |

This is a consequence of zenoh-c using the same data types (`z_loaned_sample_t`,
`z_loaned_reply_t`, `ze_miss_t`) across different features. The C shim mirrors
this — one extraction function per data type, not per feature.

---

## Updating This Guide

When a new example is implemented, add an entry in the Examples section
using this template:

```markdown
### z_example_name — Short Description

**Follows canon / Deviates from canon / Composition example.**

Brief classification. If composition: list which existing primitives
it composes. If deviation: state what differs.

**What's new**

- N CLI example(s): description
- ~N tests: breakdown

**The pattern it demonstrates**

Arrow-chain showing the operation sequence. Every example gets one —
this is the visual signature. Use annotations under the chain to
highlight the key step. For compositions, contrast with the prior
example it builds on.

**Key architectural decision** (deviations and compositions only)

What the canon specifies, what we do instead, and why. Reference the
specific zenoh-c/zenoh-cpp construct being replaced or skipped.

**Test gap it fills** (if applicable)

What compositional invariant was untested before this example.

Flags table and usage line.
```

Update the Coverage Map table to reflect the new example's status.
