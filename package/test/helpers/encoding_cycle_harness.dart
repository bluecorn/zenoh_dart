// Cycle harness for seed #10's encoding-carrier resource legs.
//
// Runs N cycles of one encoding-carrying pattern and exits. Meant to be spawned
// under `LD_PRELOAD=shim_alloc_counter.so`, whose destructor prints the
// alloc/free totals for the tracked size class as the process ends.
//
// WHY A COUNTER AND NOT AN ASSERTION. A leak is invisible to every behavioural
// cell: the value still arrives, the round-trip still passes, and the suite
// stays green while the process grows. The discipline is to measure the
// RESOURCE and to count over N cycles rather than sample once.
//
// THE TWO SIDES OF THE SEAM NEED DIFFERENT COUNTER SETTINGS, and that is the
// whole reason this harness has four modes rather than one:
//
//   send / send-throw   Dart-side buffers from `allocLengthCarriedUtf8`, which
//                       is `package:ffi`'s calloc. Not `malloc`, and not called
//                       from libzenoh_dart.so — so they need
//                       ZD_COUNT_CALLER=* and the counter's calloc hook.
//                       Measured before that existed: five deliberately leaked
//                       blocks reported outstanding=0.
//   recv / recv-abandon shim-side `malloc(enc_len + 1)` inside
//                       zd_pull_subscriber_try_recv. The default caller filter
//                       is exactly right for these.
//
// SIZE CLASSES ARE MEASURED, NEVER GUESSED. `allocLengthCarriedUtf8` allocates
// exactly `utf8.encode(value).length` bytes, so the send buffers land in the
// class named by the MIME's own byte length; the sync extractor allocates
// `enc_len + 1`, one more. Both constants below are derived from the fixture
// strings rather than typed, and the fixtures are sized to an unusual class so
// unrelated traffic does not crowd the count.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

/// Builds an ASCII string of exactly [length] bytes from [seed].
///
/// The fixtures are BUILT to an exact length rather than typed, because the
/// length IS the instrument: it is the size class the counter selects on.
String _ofLength(String seed, int length) {
  final b = StringBuffer();
  while (b.length < length) {
    b.write(seed);
  }
  return b.toString().substring(0, length);
}

/// ⚠️ THE SIZE IS THE INSTRUMENT, and this value is fenced in from BOTH sides
/// by measurements.
///
/// FROM BELOW — the send-side buffers cannot be caller-filtered: `dladdr`
/// resolves NO shared object for them, because they are allocated from
/// JIT-compiled Dart rather than from any `.so`. Measured: a diagnostic build
/// reported not one resolvable caller for them across a whole run. So the size
/// class has to do all the work alone, and a crowded class cannot. At 61 bytes
/// it was badly crowded — with a live wire that class took ~5 allocations per
/// cycle against the 2 that are ours.
///
/// FROM ABOVE — ⚠️ AN ENCODING OF 256 BYTES OR MORE ABORTS THE PUBLISHING
/// PROCESS. Measured exactly: 255 bytes round-trips byte-exact, 256 panics
/// inside zenoh's transport (`pipeline.rs:401`, `unwrap()` on `DidntWrite`) and
/// aborts. It is CANON's, not ours — the canon-C peer publishing the same
/// encoding panics identically with our shim entirely out of the path — and it
/// is pre-existing, since the same bytes reached the wire before this seed via
/// `z_encoding_from_str`. It is recorded as an upstream finding rather than
/// pinned by a cell, because a cell that reproduced it would abort the test
/// runner and take the whole serial suite with it.
///
/// 200 sits clear of the crowded small classes and safely under the 256-byte
/// cliff. The rendered `mime;schema` is 401 bytes, which never reaches the
/// wire on the send legs (they throw first) and is only RECEIVED on the recv
/// legs — where the sending side is the same process and the cliff would bite,
/// so the recv legs publish a SHORT encoding instead. See [recvCycles].
const _cycleLength = 1021;

/// A MIME id of exactly [_cycleLength] bytes, for the SEND legs.
final String cycleMime = _ofLength(
  'application/x-seed10-carrier-probe-',
  _cycleLength,
);

/// A schema of the SAME byte length, so ONE size class covers both channels and
/// each cycle contributes exactly two tracked allocations.
final String cycleSchema = _ofLength(
  'seed10-schema-carrier-probe-',
  _cycleLength,
);

/// The RECEIVE legs need their own, SHORTER fixture, and the reason is the
/// 256-byte cliff above: those legs actually put the encoding on a wire, where
/// a rendered form of 256 bytes or more aborts the process. `mime;schema` here
/// renders to 201 bytes, comfortably under it.
///
/// A crowded size class costs nothing on this side: the receive buffers ARE
/// allocated inside libzenoh_dart.so, so the counter's default caller filter
/// selects them on its own and the size is only a second sieve.
const _recvLength = 100;

/// A MIME id of exactly [_recvLength] bytes.
final String recvMime = _ofLength(
  'application/x-seed10-recv-probe-',
  _recvLength,
);

/// A schema of the same length, so the rendered form is deterministic.
final String recvSchema = _ofLength('seed10-recv-schema-', _recvLength);

/// The byte length both marshalling buffers land in.
final int sendSizeClass = utf8.encode(cycleMime).length;

/// What the sync extractor allocates for a rendered encoding: its length + 1.
///
/// The rendered form is `mime;schema`, so this is derived from both — computed,
/// never typed, because it is the number the counter selects on.
final int recvSizeClass = utf8.encode('$recvMime;$recvSchema').length + 1;

Config _quietConfig({String? listen, String? connect}) {
  final c = Config()
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  if (listen != null) c.insertJson5('listen/endpoints', '["$listen"]');
  if (connect != null) c.insertJson5('connect/endpoints', '["$connect"]');
  return c;
}

/// N puts carrying BOTH channels, each releasing its two buffers.
///
/// No subscriber and no second session: the marshalling buffers are allocated
/// and released entirely on the sending side, so a peer would add traffic
/// without adding evidence.
Future<void> sendCycles(int n) async {
  final session = await Session.open(config: _quietConfig());
  final withSchema = Encoding(cycleMime).withSchema(cycleSchema);
  // ONE key expression for every cycle. A per-cycle key expression makes zenoh
  // retain per-resource state that grows with N, which would surface in the
  // count as a leak that is not ours.
  for (var i = 0; i < n; i++) {
    session.put('zenoh/dart/s10/cycle/send', 'payload', encoding: withSchema);
  }
  session.close();
}

/// N puts that THROW after both marshalling buffers are allocated.
///
/// This is the outer-`finally` leg. In `Session.put` the two buffers are
/// allocated BEFORE the `try`, and the key expression is validated INSIDE it —
/// so an invalid key expression throws with both buffers live, which is exactly
/// the path the enclosing `finally` exists for. If the release lived inside the
/// `_withKeyExprArg` closure instead (which is never entered on this path),
/// both buffers would leak on every cycle and no behavioural cell would notice.
///
/// Reachable from the public API, and deliberately so: a leg driven only at the
/// bindings level would not prove the shipped entry point is safe.
Future<void> sendThrowCycles(int n) async {
  final session = await Session.open(config: _quietConfig());
  final withSchema = Encoding(cycleMime).withSchema(cycleSchema);
  var thrown = 0;
  for (var i = 0; i < n; i++) {
    try {
      // `demo//x` — an empty chunk, refused by canon's own key-expression
      // validation with rc -1. Taken from the shipped invalid-expression list
      // in keyexpr_test.dart rather than invented: an earlier attempt used a
      // key with SPACES, which canon accepts, and the harness caught its own
      // false premise by counting zero throws.
      session.put('demo//x', 'payload', encoding: withSchema);
    } on Object {
      thrown++;
    }
  }
  if (thrown != n) {
    stdout.writeln('HARNESS_FATAL expected $n throws, got $thrown');
    exit(2);
  }
  session.close();
}

/// N `tryRecv` cycles over a pull subscriber, each returning a sample whose
/// encoding the shim allocated and the Dart side must release.
Future<void> recvCycles(int n, {bool abandon = false}) async {
  const endpoint = 'tcp/127.0.0.1:19572';
  final host = await Session.open(config: _quietConfig(listen: endpoint));
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final client = await Session.open(config: _quietConfig(connect: endpoint));
  await Future<void>.delayed(const Duration(seconds: 1));

  const key = 'zenoh/dart/s10/cycle/recv';
  // Deliberately far above the cycle count so the ring never drops during a
  // run: a dropped sample would read as a missing ALLOCATION, which is not the
  // property this leg is measuring.
  final pull = client.declarePullSubscriber(key, capacity: 1024);
  await Future<void>.delayed(const Duration(milliseconds: 500));

  final encoding = Encoding(recvMime).withSchema(recvSchema);
  var taken = 0;
  for (var i = 0; i < n; i++) {
    host.put(key, 'payload', encoding: encoding);
    // Bounded poll: a sample that never arrives must not hang the harness.
    for (var attempt = 0; attempt < 40 && taken <= i; attempt++) {
      final r = pull.tryRecv();
      if (r is RecvData<Sample>) {
        taken++;
        // The abandon arm drops the result immediately without reading it —
        // the shim's buffers are released inside tryRecv's own finally either
        // way, which is exactly the property being counted.
        if (!abandon && r.value.encoding == null) {
          stdout.writeln('HARNESS_FATAL sample carried no encoding');
          exit(2);
        }
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  }
  if (taken != n) {
    stdout.writeln('HARNESS_FATAL took $taken of $n samples');
    exit(2);
  }
  pull.close();
  client.close();
  host.close();
}

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stdout.writeln('usage: encoding_cycle_harness <mode> <n>');
    exit(2);
  }
  final mode = args[0];
  final n = int.parse(args[1]);

  switch (mode) {
    case 'send':
      await sendCycles(n);
    case 'send-throw':
      await sendThrowCycles(n);
    case 'recv':
      await recvCycles(n);
    case 'recv-abandon':
      await recvCycles(n, abandon: true);
    case 'sizes':
      stdout.writeln('SEND_SIZE $sendSizeClass RECV_SIZE $recvSizeClass');
    default:
      stdout.writeln('HARNESS_FATAL unknown mode $mode');
      exit(2);
  }

  stdout.writeln('HARNESS_DONE $mode $n');
}
