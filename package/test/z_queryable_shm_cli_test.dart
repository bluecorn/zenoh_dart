import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

/// Pool size for the test-side SHM provider. Comfortably above anything these
/// probes allocate; this file makes no claim about where the floor sits.
const int _shmPoolSize = 65536;

/// Allocates an SHM chunk, writes [text] into it, and hands back the
/// SHM-backed [ZBytes].
///
/// The PAYLOAD is zero-copy -- `toBytes()` hands the chunk itself to zenoh --
/// so what crosses the wire really is shared memory. The fill copies into the
/// chunk, which is what `write` is: the alternative, `buffer.data`, hands out a
/// raw pointer and costs this buffer its chunk-releasing finalizer.
ZBytes _shmBytes(ShmProvider provider, String text) {
  final data = utf8.encode(text);
  final buffer = switch (provider.allocGcDefragBlocking(data.length)) {
    AllocOk(:final buffer) => buffer,
    AllocError(:final kind) => fail('SHM alloc failed: $kind'),
    LayoutError(:final kind) => fail('SHM layout failed: $kind'),
  };
  // `toBytes()` consumes the buffer; the returned handle is consumed in turn
  // by the `get` it is handed to.
  return (buffer..write(data)).toBytes();
}

/// Starts the example on [key], listening at [port], and connects a session to
/// it; returns the example's stdout buffer and that session.
///
/// Both halves register their own teardown, so a caller that fails partway
/// still leaves no process holding the port. Extracted because the two tag
/// cells need an identical fixture and differ only in what they then send.
Future<(StringBuffer, Session)> _startExampleAndConnect(
  String packageRoot, {
  required int port,
  required String key,
}) async {
  final endpoint = 'tcp/127.0.0.1:$port';
  final process = await Process.start(_dartExe, [
    'run',
    'example/z_queryable_shm.dart',
    '-k',
    key,
    '-l',
    endpoint,
  ], workingDirectory: packageRoot);
  addTearDown(() => forceKill(process));

  final out = StringBuffer();
  final subscription = process.stdout
      .transform(const SystemEncoding().decoder)
      .listen(out.write);
  addTearDown(subscription.cancel);

  await waitForReady(out);
  // Settle time for the TCP listener to bind and negotiate.
  await Future<void>.delayed(const Duration(seconds: 3));

  final session = await Session.open(
    config: Config()..insertJson5('connect/endpoints', '["$endpoint"]'),
  );
  addTearDown(session.close);
  await Future<void>.delayed(const Duration(seconds: 2));
  return (out, session);
}

/// Sends a get on [key] with [parameters], retrying until a reply lands.
///
/// [payload] is a FACTORY, not a value: `Session.get` consumes the `ZBytes` it
/// is given, so a retry needs a fresh one. Returns whatever it last saw, so a
/// dry deadline surfaces as an empty list the caller asserts on rather than as
/// a timeout somewhere less legible.
Future<List<Reply>> _getUntilAnswered(
  Session session,
  String key, {
  required String parameters,
  ZBytes Function()? payload,
  Duration deadline = const Duration(seconds: 25),
}) async {
  final expiry = DateTime.now().add(deadline);
  while (true) {
    final replies = await session
        .get(
          key,
          parameters: parameters,
          payload: payload?.call(),
          timeout: const Duration(seconds: 5),
        )
        .toList();
    if (replies.isNotEmpty || DateTime.now().isAfter(expiry)) return replies;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

void main() {
  final packageRoot = Directory.current.path;

  group(
    'z_queryable_shm CLI',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      test('runs and declares queryable', () async {
        final process = await Process.start(_dartExe, [
          'run',
          'example/z_queryable_shm.dart',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final stdout = StringBuffer();
        final subscription = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdout.write);

        await waitForReady(stdout);
        await forceKill(process);
        await subscription.cancel();

        expect(stdout.toString(), contains('Declaring Queryable'));
        expect(
          stdout.toString(),
          contains('demo/example/zenoh-dart-queryable'),
        );
      });

      test('accepts --key flag', () async {
        final process = await Process.start(_dartExe, [
          'run',
          'example/z_queryable_shm.dart',
          '--key',
          'demo/custom/shm',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final stdout = StringBuffer();
        final subscription = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdout.write);

        await waitForReady(stdout);
        await forceKill(process);
        await subscription.cancel();

        expect(stdout.toString(), contains('demo/custom/shm'));
      });

      // ⚠️ NARROWED FROM `contains('SHM')`, AND THE NARROWING RESTORES
      // DISCRIMINATION RATHER THAN WEAKENING IT. This cell sends no query at
      // all, so the only `SHM` it could ever observe was the provider banner
      // -- but once the example prints canon's `[SHM]` payload tag, the broad
      // string stops telling a banner from a tag and would green on output
      // carrying only one of the two. The banner is what this cell means, so
      // it is now what it says.
      test('prints SHM provider creation', () async {
        final process = await Process.start(_dartExe, [
          'run',
          'example/z_queryable_shm.dart',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final stdout = StringBuffer();
        final subscription = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdout.write);

        await waitForReady(stdout);
        await forceKill(process);
        await subscription.cancel();

        expect(stdout.toString(), contains('Creating POSIX SHM Provider'));
      });

      // The three tests above assert declaration banners and flag echoes. None
      // of them ever sends a query -- so `replyBytes` from an SHM buffer, the
      // whole subject of this example, had no executed coverage at all.
      //
      // Driving a query is necessary but not sufficient: on allocation failure
      // the example falls back to `query.reply(keyExpr, payload)`, whose reply
      // is *content-identical*, so a payload assertion greens either way. What
      // separates the two is that the fallback is loud on stdout. Asserting the
      // warning's absence after the reply has arrived -- i.e. once the callback
      // has provably run past the alloc branch -- is what makes this test about
      // shared memory rather than about replying.
      //
      // `-p` is passed explicitly so this test does not depend on the default
      // payload string (which Round 2 changes to carry the SHM token).
      test('replies to an in-process get from an SHM buffer', () async {
        const port = 18563;
        const endpoint = 'tcp/127.0.0.1:$port';
        const payload = 'SHM reply probe';

        final qProcess = await Process.start(_dartExe, [
          'run',
          'example/z_queryable_shm.dart',
          '-k',
          'demo/cli/qshm',
          '-p',
          payload,
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(qProcess));

        final qStdout = StringBuffer();
        final qSubscription = qProcess.stdout
            .transform(const SystemEncoding().decoder)
            .listen(qStdout.write);

        try {
          await waitForReady(qStdout);
          // Settle time for the TCP listener to bind and negotiate.
          await Future<void>.delayed(const Duration(seconds: 3));

          final session = await Session.open(
            config: Config()..insertJson5('connect/endpoints', '["$endpoint"]'),
          );
          addTearDown(session.close);
          await Future<void>.delayed(const Duration(seconds: 2));

          final replies = await session
              .get('demo/cli/qshm', timeout: const Duration(seconds: 5))
              .toList();

          expect(replies, isNotEmpty);
          expect(replies.first.isOk, isTrue);
          expect(replies.first.ok.payload, equals(payload));

          final output = qStdout.toString();
          expect(output, contains('Received Query'));
          // Window closed: the reply above proves the callback ran to
          // completion, so the fallback would already have printed.
          expect(
            output,
            isNot(
              contains('Warning: SHM buffer allocation failed'),
            ),
          );
        } finally {
          await forceKill(qProcess);
          await qSubscription.cancel();
        }
      }, timeout: const Timeout(Duration(seconds: 40)));

      test('uses the default SHM payload and echoes the query payload', () async {
        // The e2e above passes -p explicitly (deliberately, so it does not
        // depend on the default) -- which leaves the default itself unpinned.
        // Round 2 restored canon's SHM token to it, so that z_queryable and
        // z_queryable_shm stop being indistinguishable by default output, and
        // added canon's received-query-payload line (z_queryable_shm.c:46-58).
        const port = 18565;
        const endpoint = 'tcp/127.0.0.1:$port';

        final qProcess = await Process.start(_dartExe, [
          'run',
          'example/z_queryable_shm.dart',
          '-k',
          'demo/cli/qshmdef',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(qProcess));

        final qStdout = StringBuffer();
        final qSubscription = qProcess.stdout
            .transform(const SystemEncoding().decoder)
            .listen(qStdout.write);
        addTearDown(qSubscription.cancel);

        await waitForReady(qStdout);
        await Future<void>.delayed(const Duration(seconds: 3));

        final session = await Session.open(
          config: Config()..insertJson5('connect/endpoints', '["$endpoint"]'),
        );
        addTearDown(session.close);
        await Future<void>.delayed(const Duration(seconds: 2));

        final replies = await session
            .get(
              'demo/cli/qshmdef',
              payload: ZBytes.fromString('probe-value'),
              timeout: const Duration(seconds: 5),
            )
            .toList();

        expect(replies, isNotEmpty);
        expect(replies.first.isOk, isTrue);
        expect(replies.first.ok.payload, equals('Queryable from Dart SHM!'));

        // Both lines can only have been printed by the handler that produced
        // the reply just received.
        final output = qStdout.toString();
        expect(output, contains("with value 'probe-value'"));
        expect(
          output,
          contains(
            '>> [Queryable] Responding '
            "('demo/cli/qshmdef': 'Queryable from Dart SHM!')...",
          ),
        );
      }, timeout: const Timeout(Duration(seconds: 40)));

      // Canon tags the payload a REQUESTER sent, two-state, at
      // `z_queryable_shm.c:47-49`:
      //
      //     char *payload_type =
      //         z_bytes_as_loaned_shm(payload, &shm) == Z_OK ? "SHM" : "RAW";
      //
      // ⛔ TWO STATES ONLY. Canon's three-state rendering
      // (RAW / UNKNOWN / SHM (MUT|IMMUT)) lives in `z_sub_shm.c` and stays
      // deliberately carved; this example targets `z_queryable_shm.c`.
      //
      // ⛔ BOTH ARMS RUN AGAINST THE SAME PROCESS IN THE SAME RUN. Without the
      // heap control the `[SHM]` arm proves only that something printed -- a
      // hardwired constant would green a one-armed cell. The arms are told
      // apart by their query PARAMETERS, which the example echoes on the very
      // line the tag rides.
      //
      // ⛔ Nothing here asserts stderr silence: canon logs on its own
      // predicate's failure path (upstream #814), so quiet is not ours to
      // claim.
      test(
        'tags an SHM query payload SHM and a heap one RAW in the same run',
        () async {
          const key = 'demo/cli/qshmtag';
          const shmProbe = 'shm-tag-probe';
          const rawProbe = 'raw-tag-probe';

          final (qStdout, session) = await _startExampleAndConnect(
            packageRoot,
            port: 19741,
            key: key,
          );

          final provider = ShmProvider(size: _shmPoolSize);
          addTearDown(provider.close);

          final shmReplies = await _getUntilAnswered(
            session,
            key,
            parameters: 'arm=shm',
            payload: () => _shmBytes(provider, shmProbe),
          );
          expect(
            shmReplies,
            isNotEmpty,
            reason:
                'the SHM arm got no reply, so '
                'the example never ran its handler',
          );

          final rawReplies = await _getUntilAnswered(
            session,
            key,
            parameters: 'arm=heap',
            payload: () => ZBytes.fromString(rawProbe),
          );
          expect(
            rawReplies,
            isNotEmpty,
            reason:
                'the heap arm got no reply, so '
                'the control never ran',
          );

          final output = qStdout.toString();
          expect(
            output,
            contains(
              ">> [Queryable ] Received Query '$key?arm=shm' "
              "with value '$shmProbe' [SHM]",
            ),
            reason:
                'a shared-memory-backed query payload was not tagged '
                'SHM:\n$output',
          );
          expect(
            output,
            contains(
              ">> [Queryable ] Received Query '$key?arm=heap' "
              "with value '$rawProbe' [RAW]",
            ),
            reason:
                'a heap query payload was tagged as shared memory -- the tag '
                'is a constant, not a measurement, and the arm above proves '
                'nothing:\n$output',
          );
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );

      // A query carrying NO payload takes the branch where `payloadZBytes` is
      // null. Canon prints the short form there, with no tag at all.
      //
      // ⛔ THE ABSENCE IS ONLY EVIDENCE IF PRESENCE IS DEMONSTRATED BESIDE IT.
      // A cell that only checked "no tag on the empty arm" would have been
      // green before the example could print any tag whatsoever. So the same
      // process is first driven with a payload -- which must be tagged -- and
      // only then with none.
      test(
        'a query with NO payload prints neither tag and still replies',
        () async {
          const key = 'demo/cli/qshmnone';
          const probe = 'none-arm-control';

          final (qStdout, session) = await _startExampleAndConnect(
            packageRoot,
            port: 19742,
            key: key,
          );

          final tagged = await _getUntilAnswered(
            session,
            key,
            parameters: 'arm=payload',
            payload: () => ZBytes.fromString(probe),
          );
          expect(tagged, isNotEmpty, reason: 'the presence arm got no reply');

          final untagged = await _getUntilAnswered(
            session,
            key,
            parameters: 'arm=none',
          );
          // A reply proves the handler ran PAST the null-payload read without
          // throwing -- the reply is emitted after it.
          expect(
            untagged,
            isNotEmpty,
            reason:
                'no reply to the payload-less query: reading a null '
                'payloadZBytes threw, or the handler died before replying',
          );

          final output = qStdout.toString();
          expect(
            output,
            contains(
              ">> [Queryable ] Received Query '$key?arm=payload' "
              "with value '$probe' [RAW]",
            ),
            reason:
                'this binary prints no tag at all, so the absence asserted '
                'below is vacuous:\n$output',
          );

          final noneLines = const LineSplitter()
              .convert(output)
              .where((l) => l.contains("Received Query '$key?arm=none'"))
              .toList();
          expect(
            noneLines,
            isNotEmpty,
            reason: 'the payload-less query was never echoed:\n$output',
          );
          for (final line in noneLines) {
            expect(line, isNot(contains('[SHM]')), reason: line);
            expect(line, isNot(contains('[RAW]')), reason: line);
            expect(line, isNot(contains('with value')), reason: line);
          }
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );

      // ⭐⭐ THE DISCRIMINATOR FOR THE MOVE ONTO THE ASYNC ALLOCATOR, and the
      // only cell in this file that was RED before it.
      //
      // A reply payload larger than canon's own 4096-byte pool is a request
      // the pool can never satisfy. Measured at this slice, on both
      // allocators, such a request is ACCEPTED AND NEVER ANSWERED -- so what
      // changes is not whether it is answered but WHO waits:
      //
      //   allocGcDefragBlocking -> the ISOLATE parks, and this example's own
      //                            SIGINT/SIGTERM handlers live on that event
      //                            loop, so the process stops answering
      //                            signals and survives Ctrl-C entirely
      //   allocGcDefragAsync    -> canon holds the request, the event loop
      //                            keeps turning, the signal is seen, and
      //                            shutdown's `provider.close()` answers the
      //                            outstanding request on the way out
      //
      // That asymmetry is the whole ground for diverging from canon, which
      // installs no signal handler and is therefore still killable while
      // parked. This cell asserts it rather than trusting the note.
      //
      // ⚠️ It asserts the process exits ON ITS OWN. `forceKill` escalates to
      // SIGKILL after 3 s, so a cell that merely tore the process down would
      // be green against a frozen one.
      test(
        'a parked allocation does not make the process unkillable',
        () async {
          const port = 19765;
          const endpoint = 'tcp/127.0.0.1:$port';
          const key = 'demo/cli/qshmpark';
          // Larger than the example's 4096-byte pool -- canon's own size, kept.
          final payload = 'x' * 5000;

          final process = await Process.start(_dartExe, [
            'run',
            'example/z_queryable_shm.dart',
            '-k',
            key,
            '-p',
            payload,
            '-l',
            endpoint,
          ], workingDirectory: packageRoot);
          addTearDown(() => forceKill(process));

          final stdout = StringBuffer();
          final subscription = process.stdout
              .transform(const SystemEncoding().decoder)
              .listen(stdout.write);
          addTearDown(subscription.cancel);

          await waitForReady(stdout);
          await Future<void>.delayed(const Duration(seconds: 3));

          final session = await Session.open(
            config: Config()..insertJson5('connect/endpoints', '["$endpoint"]'),
          );
          addTearDown(session.close);
          await Future<void>.delayed(const Duration(seconds: 2));

          // Fire and forget: this query is never answered by construction, so
          // awaiting its replies would be waiting for the thing under test not
          // to happen.
          unawaited(
            session
                .get(key, timeout: const Duration(seconds: 5))
                .toList()
                .then((_) {}, onError: (Object _) {}),
          );

          // The handler has provably reached the allocation.
          await waitForOutput(stdout, 'Allocating Shared Memory Buffer');

          // SIGINT, because "survives Ctrl-C" is the literal claim the note
          // makes; the example watches SIGTERM identically.
          expect(process.kill(ProcessSignal.sigint), isTrue);
          final exitCode = await process.exitCode.timeout(
            const Duration(seconds: 25),
            onTimeout: () => fail(
              'the example ignored SIGINT while an allocation was parked -- '
              'the isolate is frozen inside the allocator, which is exactly '
              'what the async sibling exists to avoid:\n$stdout',
            ),
          );
          expect(
            exitCode,
            0,
            reason: 'the example exited on SIGINT but not cleanly:\n$stdout',
          );
        },
        timeout: const Timeout(Duration(seconds: 120)),
      );

      test('the example awaits the async allocator, one request at a time', () {
        // Per-file anchor; the population-wide census lives in
        // `z_pub_shm_cli_test.dart`.
        //
        // The serialization half is not decoration: a second
        // `allocGcDefragAsync` on the same provider while one is pending
        // THROWS, and this is the one example that allocates on an event it
        // does not control the rate of.
        final source = File(
          '$packageRoot/example/z_queryable_shm.dart',
        ).readAsStringSync();
        expect(source, contains('await provider.allocGcDefragAsync('));
        expect(source, contains('allocates once per query'));
        expect(
          source,
          contains('.pause('),
          reason:
              'nothing stops two queries overlapping, and the second '
              "allocation would throw on this provider's one-in-flight rule",
        );
      });
    },
  );

  // Source-anchored, and deliberately OUTSIDE the shared-memory skip: what it
  // asserts about the file is true on every variant.
  group('z_queryable_shm source', () {
    test("no longer claims canon's backing tag is inexpressible", () {
      // The example carried a marker saying the tag "is not expressible here"
      // because received query payloads surfaced as `Uint8List`. They no
      // longer do -- `Query.payloadZBytes` hands back a `ZBytes`, with no
      // opt-in flag -- so the marker had to GO rather than be reworded, and a
      // removed marker is only assertable as the absence of its fragments.
      final source = File('example/z_queryable_shm.dart').readAsStringSync();
      expect(source, isNot(contains('is not expressible here')));
      expect(source, isNot(contains('has nothing to test')));
      expect(source, isNot(contains('API-surface gap')));
      // And the capability is reached from CODE. Anchored on the receiver so
      // a prose mention in the replacement comment cannot satisfy it: the
      // comment spells it `Query.payloadZBytes`, capitalised.
      expect(source, contains('query.payloadZBytes'));
    });
  });
}
