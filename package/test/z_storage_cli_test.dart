import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path (direct binary, not fvm wrapper).
final String _dartExe = Platform.resolvedExecutable;

void main() {
  final packageRoot = Directory.current.path;

  group('z_storage CLI', () {
    setUpAll(() {
      final scriptFile = File('$packageRoot/example/z_storage.dart');
      expect(
        scriptFile.existsSync(),
        isTrue,
        reason: 'example/z_storage.dart must exist',
      );
    });

    test(
      'starts and prints subscriber/queryable messages',
      () async {
        const endpoint = 'tcp/127.0.0.1:18700';

        final process = await Process.start(_dartExe, [
          'run',
          'example/z_storage.dart',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final stdoutBuf = StringBuffer();
        final stderrBuf = StringBuffer();
        process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdoutBuf.write);
        process.stderr
            .transform(const SystemEncoding().decoder)
            .listen(stderrBuf.write);

        await waitForReady(stdoutBuf);
        await forceKill(process);

        final stdout = stdoutBuf.toString();
        expect(stdout, contains('Declaring Subscriber'));
        expect(stdout, contains('Declaring Queryable'));
        expect(stdout, contains('demo/example/**'));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('accepts --key flag', () async {
      const endpoint = 'tcp/127.0.0.1:18701';

      final process = await Process.start(_dartExe, [
        'run',
        'example/z_storage.dart',
        '-k',
        'test/storage/**',
        '-l',
        endpoint,
      ], workingDirectory: packageRoot);
      addTearDown(() => forceKill(process));

      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();
      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdoutBuf.write);
      process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(stderrBuf.write);

      await waitForReady(stdoutBuf);
      await forceKill(process);

      final stdout = stdoutBuf.toString();
      expect(stdout, contains('test/storage/**'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test(
      'runs with --complete without error',
      () async {
        const endpoint = 'tcp/127.0.0.1:18702';

        final process = await Process.start(_dartExe, [
          'run',
          'example/z_storage.dart',
          '--complete',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final stdoutBuf = StringBuffer();
        final stderrBuf = StringBuffer();
        process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdoutBuf.write);
        process.stderr
            .transform(const SystemEncoding().decoder)
            .listen(stderrBuf.write);

        await waitForReady(stdoutBuf);
        await forceKill(process);

        final stdout = stdoutBuf.toString();
        final stderr = stderrBuf.toString();

        // Process should have started without crashing
        // Accept either clean startup messages or a clean exit
        expect(
          stdout.contains('Declaring Subscriber') ||
              stdout.contains('Press CTRL-C'),
          isTrue,
          reason:
              'Process should start without error. '
              'stdout: $stdout, stderr: $stderr',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'put then query returns stored value',
      () async {
        const endpoint = 'tcp/127.0.0.1:18710';

        // Start z_storage
        final storageProc = await Process.start(_dartExe, [
          'run',
          'example/z_storage.dart',
          '-k',
          'demo/example/**',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(storageProc));

        final storageStdout = StringBuffer();
        final storageStderr = StringBuffer();
        storageProc.stdout
            .transform(const SystemEncoding().decoder)
            .listen(storageStdout.write);
        storageProc.stderr
            .transform(const SystemEncoding().decoder)
            .listen(storageStderr.write);

        await waitForReady(storageStdout);
        expect(storageStdout.toString(), contains('Press CTRL-C'));

        // Put a value
        final putResult = await runToCompletion(_dartExe, [
          'run',
          'example/z_put.dart',
          '-k',
          'demo/example/key1',
          '-p',
          'value1',
          '-e',
          endpoint,
        ], workingDirectory: packageRoot);
        expect(
          putResult.exitCode,
          equals(0),
          reason: 'z_put failed: ${putResult.stderr}',
        );

        // Wait for propagation
        await Future<void>.delayed(const Duration(seconds: 2));

        // Query the stored value
        final getResult = await runToCompletion(_dartExe, [
          'run',
          'example/z_get.dart',
          '-s',
          'demo/example/**',
          '-e',
          endpoint,
          '-o',
          '5000',
        ], workingDirectory: packageRoot);

        final getStdout = getResult.stdout as String;
        expect(
          getStdout,
          contains('value1'),
          reason:
              'z_get should return stored value. '
              'stdout: $getStdout, stderr: ${getResult.stderr}',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'delete removes from storage then query omits deleted key',
      () async {
        const endpoint = 'tcp/127.0.0.1:18711';

        // Start z_storage
        final storageProc = await Process.start(_dartExe, [
          'run',
          'example/z_storage.dart',
          '-k',
          'demo/example/**',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(storageProc));

        final storageStdout = StringBuffer();
        final storageStderr = StringBuffer();
        storageProc.stdout
            .transform(const SystemEncoding().decoder)
            .listen(storageStdout.write);
        storageProc.stderr
            .transform(const SystemEncoding().decoder)
            .listen(storageStderr.write);

        await waitForReady(storageStdout);
        expect(storageStdout.toString(), contains('Press CTRL-C'));

        // Put key1 and key2
        final put1Result = await runToCompletion(_dartExe, [
          'run',
          'example/z_put.dart',
          '-k',
          'demo/example/key1',
          '-p',
          'val1',
          '-e',
          endpoint,
        ], workingDirectory: packageRoot);
        expect(put1Result.exitCode, equals(0));

        final put2Result = await runToCompletion(_dartExe, [
          'run',
          'example/z_put.dart',
          '-k',
          'demo/example/key2',
          '-p',
          'val2',
          '-e',
          endpoint,
        ], workingDirectory: packageRoot);
        expect(put2Result.exitCode, equals(0));

        // Wait for propagation
        await Future<void>.delayed(const Duration(seconds: 2));

        // Delete key1 using in-process Session API
        final config = Config()
          ..insertJson5('connect/endpoints', '["$endpoint"]');
        final session = await Session.open(config: config);
        // Allow connection to establish
        await Future<void>.delayed(const Duration(seconds: 2));
        session.deleteResource('demo/example/key1');
        // Wait for the DELETE the assertion below is about.
        await waitForOutput(storageStdout, 'DELETE');
        session.close();

        // Verify storage received the DELETE
        expect(storageStdout.toString(), contains('DELETE'));

        // Query and check that val1 is gone but val2 remains
        final getResult = await runToCompletion(_dartExe, [
          'run',
          'example/z_get.dart',
          '-s',
          'demo/example/**',
          '-e',
          endpoint,
          '-o',
          '5000',
        ], workingDirectory: packageRoot);

        final getStdout = getResult.stdout as String;
        expect(
          getStdout,
          contains('val2'),
          reason:
              'z_get should return val2. '
              'stdout: $getStdout, stderr: ${getResult.stderr}',
        );
        expect(
          getStdout,
          isNot(contains('val1')),
          reason: 'z_get should not return deleted val1. stdout: $getStdout',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'query with non-matching key returns no results',
      () async {
        const endpoint = 'tcp/127.0.0.1:18712';

        // Start z_storage
        final storageProc = await Process.start(_dartExe, [
          'run',
          'example/z_storage.dart',
          '-k',
          'demo/example/**',
          '-l',
          endpoint,
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(storageProc));

        final storageStdout = StringBuffer();
        final storageStderr = StringBuffer();
        storageProc.stdout
            .transform(const SystemEncoding().decoder)
            .listen(storageStdout.write);
        storageProc.stderr
            .transform(const SystemEncoding().decoder)
            .listen(storageStderr.write);

        await waitForReady(storageStdout);
        expect(storageStdout.toString(), contains('Press CTRL-C'));

        // Put a value under demo/example/key1
        final putResult = await runToCompletion(_dartExe, [
          'run',
          'example/z_put.dart',
          '-k',
          'demo/example/key1',
          '-p',
          'testval',
          '-e',
          endpoint,
        ], workingDirectory: packageRoot);
        expect(putResult.exitCode, equals(0));

        // Wait for propagation
        await Future<void>.delayed(const Duration(seconds: 2));

        // Positive control first: prove the storage actually holds the value
        // and that a z_get against this endpoint can retrieve it. Without it,
        // a z_get that crashed on startup -- or a storage that stored nothing
        // -- satisfies the negative below just as well as correct key
        // filtering does. (Test 5 pairs its negative this way; this one did
        // not.)
        final controlResult = await runToCompletion(_dartExe, [
          'run',
          'example/z_get.dart',
          '-s',
          'demo/example/**',
          '-e',
          endpoint,
          '-o',
          '3000',
        ], workingDirectory: packageRoot);
        expect(controlResult.exitCode, equals(0));
        expect(
          controlResult.stdout as String,
          contains('testval'),
          reason:
              'positive control: a MATCHING selector must return testval, '
              'else the negative below proves nothing. '
              'stdout: ${controlResult.stdout}',
        );

        // Query with a non-matching selector
        final getResult = await runToCompletion(_dartExe, [
          'run',
          'example/z_get.dart',
          '-s',
          'other/**',
          '-e',
          endpoint,
          '-o',
          '3000',
        ], workingDirectory: packageRoot);

        expect(getResult.exitCode, equals(0));
        final getStdout = getResult.stdout as String;
        expect(
          getStdout,
          isNot(contains('testval')),
          reason:
              'z_get with non-matching selector should not return testval. '
              'stdout: $getStdout',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'replies with the stored bytes, not a lenient re-encoding',
      () async {
        // The discriminating test for canon's byte fidelity
        // (z_storage.c:92-94 clones the stored payload). Replying from
        // `Sample.payload` -- the lenient UTF-8 display view -- turns every
        // invalid sequence into U+FFFD, so this payload came back as
        // 0xEF 0xBF 0xBD... before the fix: the v0.18.1 defect, reintroduced
        // one layer up.
        const endpoint = 'tcp/127.0.0.1:18715';
        const keyExpr = 'test/storage/binary';

        final storageProc = await Process.start(_dartExe, [
          'run',
          'example/z_storage.dart',
          '-k',
          'test/storage/**',
          '-l',
          endpoint,
          '--no-multicast-scouting',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(storageProc));

        final storageStdout = StringBuffer();
        final storageSub = storageProc.stdout
            .transform(const SystemEncoding().decoder)
            .listen(storageStdout.write);
        addTearDown(storageSub.cancel);

        await waitForReady(storageStdout);
        // Let the TCP listener finish binding before connecting to it.
        await Future<void>.delayed(const Duration(seconds: 2));

        // Not valid UTF-8: a lone 0xFF, a truncated two-byte sequence, an
        // unexpected continuation byte, and an embedded NUL.
        final payload = Uint8List.fromList([
          0x00,
          0xff,
          0xfe,
          0x41,
          0xc3,
          0x28,
          0x80,
        ]);

        final config = Config()
          ..insertJson5('connect/endpoints', '["$endpoint"]')
          ..insertJson5('scouting/multicast/enabled', 'false');
        final session = await Session.open(config: config);
        addTearDown(session.close);
        await Future<void>.delayed(const Duration(seconds: 2));

        session.putBytes(keyExpr, ZBytes.fromUint8List(payload));
        await waitForOutput(storageStdout, 'Received PUT');

        final replies = await session
            .get('test/storage/**', timeout: const Duration(seconds: 5))
            .toList();
        final samples = replies
            .where((r) => r.isOk)
            .map((r) => r.ok)
            .where((s) => s.keyExpr == keyExpr)
            .toList();

        expect(
          samples,
          hasLength(1),
          reason:
              'expected exactly one stored entry back; '
              'storage said: $storageStdout',
        );
        expect(
          samples.single.payloadBytes,
          orderedEquals(payload),
          reason: 'the storage must reply with the bytes it stored',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('z_storage retained-payload storage', () {
    // ⚠️ The CLI cells below are BLIND to copy-vs-clone: a heap copy of the
    // stored bytes and a refcount clone of the stored payload put identical
    // bytes on the wire. They pin the CONTRACT (what a querier gets back);
    // the mechanism is pinned by the source-anchored cell that follows.
    test('replies by cloning the retained handle, not by copying bytes', () {
      final source = File(
        '$packageRoot/example/z_storage.dart',
      ).readAsStringSync();

      expect(
        source,
        contains('retainPayload: true'),
        reason:
            'the stored samples must carry an owned handle on the payload '
            'the network delivered -- without it there is nothing to clone',
      );
      expect(
        source,
        contains('payloadZBytes!.clone()'),
        reason:
            'canon replies with a z_bytes_clone of the stored payload '
            '(z_storage.c:92-94); ZBytes.clone() is that call, a refcount '
            'bump rather than a copy',
      );
      expect(
        source,
        isNot(contains('ZBytes.fromUint8List(entry.value.payloadBytes)')),
        reason:
            'the full heap copy of every stored value on every matching '
            'reply must be GONE, not merely reworded around it',
      );
    });

    test(
      'a query for a stored key returns the stored bytes byte-exact',
      () async {
        const endpoint = 'tcp/127.0.0.1:18719';
        const keyExpr = 'test/storage/clone/value';

        final storageProc = await Process.start(_dartExe, [
          'run',
          'example/z_storage.dart',
          '-k',
          'test/storage/clone/**',
          '-l',
          endpoint,
          '--no-multicast-scouting',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(storageProc));

        final storageStdout = StringBuffer();
        final storageSub = storageProc.stdout
            .transform(const SystemEncoding().decoder)
            .listen(storageStdout.write);
        addTearDown(storageSub.cancel);

        await waitForReady(storageStdout);
        await Future<void>.delayed(const Duration(seconds: 2));

        final payload = Uint8List.fromList(
          List<int>.generate(4096, (i) => 0x20 + (i % 95)),
        );

        final config = Config()
          ..insertJson5('connect/endpoints', '["$endpoint"]')
          ..insertJson5('scouting/multicast/enabled', 'false');
        final session = await Session.open(config: config);
        addTearDown(session.close);
        await Future<void>.delayed(const Duration(seconds: 2));

        session.putBytes(keyExpr, ZBytes.fromUint8List(payload));
        await waitForOutput(storageStdout, 'Received PUT');

        final replies = await session
            .get('test/storage/clone/**', timeout: const Duration(seconds: 5))
            .toList();
        final samples = replies
            .where((r) => r.isOk)
            .map((r) => r.ok)
            .where((s) => s.keyExpr == keyExpr)
            .toList();

        expect(
          samples,
          hasLength(1),
          reason:
              'expected exactly one stored entry back; '
              'storage said: $storageStdout',
        );
        expect(
          samples.single.payloadBytes,
          orderedEquals(payload),
          reason: 'the reply must carry the payload that was stored',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'an invalid-UTF-8 value with an interior NUL survives the round trip',
      () async {
        const endpoint = 'tcp/127.0.0.1:18716';
        const keyExpr = 'test/storage/binnul/value';

        final storageProc = await Process.start(_dartExe, [
          'run',
          'example/z_storage.dart',
          '-k',
          'test/storage/binnul/**',
          '-l',
          endpoint,
          '--no-multicast-scouting',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(storageProc));

        final storageStdout = StringBuffer();
        final storageSub = storageProc.stdout
            .transform(const SystemEncoding().decoder)
            .listen(storageStdout.write);
        addTearDown(storageSub.cancel);

        await waitForReady(storageStdout);
        await Future<void>.delayed(const Duration(seconds: 2));

        // A NUL in the INTERIOR (index 3 and 7, neither leading nor
        // trailing), a lone 0xFF, a truncated two-byte sequence and a
        // stray continuation byte. Built as list elements: a literal NUL
        // in this file would be a raw NUL byte in the source.
        final payload = Uint8List.fromList([
          0x41,
          0xff,
          0x42,
          0x00,
          0xc3,
          0x28,
          0x80,
          0x00,
          0x43,
        ]);

        final config = Config()
          ..insertJson5('connect/endpoints', '["$endpoint"]')
          ..insertJson5('scouting/multicast/enabled', 'false');
        final session = await Session.open(config: config);
        addTearDown(session.close);
        await Future<void>.delayed(const Duration(seconds: 2));

        session.putBytes(keyExpr, ZBytes.fromUint8List(payload));
        await waitForOutput(storageStdout, 'Received PUT');

        final replies = await session
            .get('test/storage/binnul/**', timeout: const Duration(seconds: 5))
            .toList();
        final samples = replies
            .where((r) => r.isOk)
            .map((r) => r.ok)
            .where((s) => s.keyExpr == keyExpr)
            .toList();

        expect(
          samples,
          hasLength(1),
          reason:
              'expected exactly one stored entry back; '
              'storage said: $storageStdout',
        );
        expect(
          samples.single.payloadBytes,
          orderedEquals(payload),
          reason:
              'neither the store nor the reply may re-encode the value: a '
              'lenient UTF-8 round trip would return U+FFFD for the three '
              'invalid bytes, and a C-string round trip would truncate at '
              'the first interior NUL',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    // ⚠️ WHAT THE TWO RESIDENT-MEMORY CELLS BELOW CAN AND CANNOT SEE.
    // Measured on this machine 2026-08-31: growth of the child's VmRSS
    // across the 256 measured cycles of 128 KiB, after the 64-cycle warm-up,
    // with z_storage driven four ways.
    //
    //   store-then-evict, displaced handle released     +0.9 MB
    //   store-then-evict, that release REMOVED          +1.4 MB
    //   overwrite, displaced handle released            +1.6 MB
    //   stored and NEVER evicted -- 256 live entries   +86.0 MB
    //
    // So resident memory separates "the store does not accumulate" from
    // "the store accumulates" by ~50x, and THAT is what these two cells
    // assert: a DELETE that failed to evict, or an overwrite that appended
    // instead of replacing, moves this instrument by tens of megabytes.
    //
    // It does NOT separate an explicit release from a reclaimed one -- rows
    // one and two above are the same measurement. A displaced `Sample` is
    // unreachable either way and `ZBytes` carries a `NativeFinalizer`, so
    // omitting the release costs a delay until the next GC rather than
    // unbounded growth, and the GC is driven by the same traffic. Nothing
    // observable from outside the process separates the two. The explicit
    // release -- which the example still owes, the net being no substitute
    // for the contract -- is therefore pinned by the source-anchored cell
    // after these, not pretended at inside them.
    test(
      'a DELETE evicts what it deleted: the store does not accumulate',
      () async {
        const endpoint = 'tcp/127.0.0.1:18717';
        const keyPrefix = 'test/storage/evict';

        final counter = await _startStorage(
          endpoint: endpoint,
          keyExpr: '$keyPrefix/**',
          packageRoot: packageRoot,
        );
        final session = await _connect(endpoint);

        // Each cycle stores one entry and immediately evicts it, so a
        // storage whose DELETE evicts holds at most one payload at any
        // moment. One whose DELETE does not evict holds all 256.
        Future<void> cycles(int from, int to) async {
          for (var i = from; i < to; i++) {
            session
              ..putBytes(
                '$keyPrefix/k$i',
                ZBytes.fromUint8List(_leakPayload),
                congestionControl: CongestionControl.block,
              )
              ..deleteResource(
                '$keyPrefix/k$i',
                congestionControl: CongestionControl.block,
              );
            // Yield: a tight synchronous loop would queue the whole run
            // before the child ever saw the first sample.
            await Future<void>.delayed(Duration.zero);
          }
        }

        await cycles(0, _warmupCycles);
        await _awaitCount(counter, 'Received PUT', _warmupCycles);
        await _awaitCount(counter, 'Received DELETE', _warmupCycles);
        await Future<void>.delayed(const Duration(seconds: 1));
        final before = _rssKib(counter.pid);

        await cycles(_warmupCycles, _warmupCycles + _measuredCycles);
        const total = _warmupCycles + _measuredCycles;
        await _awaitCount(counter, 'Received PUT', total);
        await _awaitCount(counter, 'Received DELETE', total);
        await Future<void>.delayed(const Duration(seconds: 1));
        final growthKib = _rssKib(counter.pid) - before;

        // The waits above are the anti-vacuity guard: they fail with the
        // observed counts if the traffic never reached the storage, so a
        // green here cannot mean "nothing happened".
        expect(counter.count('Received PUT'), greaterThanOrEqualTo(total));
        expect(
          growthKib,
          lessThan(_leakKib ~/ 2),
          reason:
              'the measured half stores and evicts $_measuredCycles payloads '
              'of $_payloadKib KiB. A storage that evicts them plateaus '
              '(measured: under 1 MB across this window); one that keeps '
              'them holds $_leakKib KiB more at the end than at the start '
              '(measured: 86 MB). Measured growth here: $growthKib KiB.',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
      testOn: 'linux',
    );

    test(
      'an overwrite replaces: the store does not accumulate',
      () async {
        const endpoint = 'tcp/127.0.0.1:18718';
        const keyPrefix = 'test/storage/overwrite';
        const key = '$keyPrefix/k';

        final counter = await _startStorage(
          endpoint: endpoint,
          keyExpr: '$keyPrefix/**',
          packageRoot: packageRoot,
        );
        final session = await _connect(endpoint);

        // Every PUT after the first lands on a key that is already stored.
        // A map that replaces ends holding one payload; one that appends
        // -- a keying defect, or a store that never overwrote -- ends
        // holding all $_measuredCycles of them.
        Future<void> cycles(int from, int to) async {
          for (var i = from; i < to; i++) {
            session.putBytes(
              key,
              ZBytes.fromUint8List(_leakPayload),
              congestionControl: CongestionControl.block,
            );
            await Future<void>.delayed(Duration.zero);
          }
        }

        await cycles(0, _warmupCycles);
        await _awaitCount(counter, 'Received PUT', _warmupCycles);
        await Future<void>.delayed(const Duration(seconds: 1));
        final before = _rssKib(counter.pid);

        await cycles(_warmupCycles, _warmupCycles + _measuredCycles);
        const total = _warmupCycles + _measuredCycles;
        await _awaitCount(counter, 'Received PUT', total);
        await Future<void>.delayed(const Duration(seconds: 1));
        final growthKib = _rssKib(counter.pid) - before;

        expect(counter.count('Received PUT'), greaterThanOrEqualTo(total));
        expect(
          growthKib,
          lessThan(_leakKib ~/ 2),
          reason:
              'the measured half overwrites the same key $_measuredCycles '
              'times with $_payloadKib KiB. A store that replaces plateaus '
              '(measured: under 2 MB across this window); one that appends '
              'holds $_leakKib KiB more at the end (measured: 86 MB). '
              'Measured growth here: $growthKib KiB.',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
      testOn: 'linux',
    );

    test('both displacement paths release the handle they displace', () {
      // The obligation the resident-memory cells above cannot see, read off
      // the source instead -- region-bounded, so each switch arm answers
      // for itself rather than the whole file answering for one of them.
      final source = File(
        '$packageRoot/example/z_storage.dart',
      ).readAsStringSync();

      final putAt = source.indexOf('case SampleKind.put:');
      final deleteAt = source.indexOf('case SampleKind.delete:');
      expect(putAt, greaterThanOrEqualTo(0), reason: 'the PUT arm');
      expect(deleteAt, greaterThan(putAt), reason: 'the DELETE arm');
      final endAt = source.indexOf('\n    }', deleteAt);
      expect(endAt, greaterThan(deleteAt), reason: 'end of the switch');

      final putArm = source.substring(putAt, deleteAt);
      final deleteArm = source.substring(deleteAt, endAt);
      final release = RegExp(r'payloadZBytes\?\.dispose\(\)');

      expect(
        release.allMatches(putArm).length,
        equals(1),
        reason:
            'a PUT to a key already stored displaces that entry, and the '
            'handle it held has no other owner',
      );
      expect(
        deleteArm,
        contains('storage.remove('),
        reason: 'a DELETE evicts the entry it names',
      );
      expect(
        release.allMatches(deleteArm).length,
        equals(2),
        reason:
            'TWO handles end on the DELETE path: the evicted entry and the '
            "DELETE sample's own -- retention clones the payload of every "
            'delivered sample, including one that is never stored',
      );
      expect(
        source,
        contains('for (final stored in storage.values)'),
        reason:
            'and what the map still holds at shutdown is released too: '
            "canon's storage_drop at the end of its main",
      );
    });

    test('the README describes the mechanism the example performs', () {
      final readme = File(
        '$packageRoot/example/README.md',
      ).readAsStringSync();

      final start = readme.indexOf('### z_storage');
      expect(start, greaterThanOrEqualTo(0), reason: 'z_storage section');
      final next = readme.indexOf('### ', start + 4);
      final section = readme.substring(
        start,
        next < 0 ? readme.length : next,
      );

      expect(
        section,
        isNot(contains('Sample.payloadBytes')),
        reason:
            'payloadBytes is a full heap COPY of the stored value; calling '
            "it canon's z_bytes_clone was mechanism-false",
      );
      expect(
        section,
        contains('retainPayload'),
        reason: 'what makes a stored sample carry an owned payload handle',
      );
      expect(
        section,
        contains('payloadZBytes'),
        reason: 'the handle the reply is cloned from',
      );
      expect(
        section,
        contains('ZBytes.clone'),
        reason: 'the Dart call performed',
      );
      expect(
        section,
        contains('z_bytes_clone'),
        reason: 'the canon call it is',
      );
    });
  });
}

/// 128 KiB. Big enough that [_measuredCycles] leaked payloads are [_leakKib]
/// of resident memory -- an order of magnitude outside the child's
/// steady-state noise -- and small enough that the example's echo of every
/// payload to stdout stays affordable.
const _payloadKib = 128;

/// Cycles run before the first sample is taken, so what is measured is only
/// what the second half ADDS. A leak grows linearly; a Dart heap reaching its
/// working set does not, which is what makes the second half discriminate
/// where an absolute figure would not.
const _warmupCycles = 64;

/// Cycles between the two samples.
const _measuredCycles = 256;

/// What the measured half pins if nothing releases the displaced handles.
const int _leakKib = _measuredCycles * _payloadKib;

/// Printable ASCII, so the example's echo decodes one byte per character on
/// both sides and adds no multi-byte noise to the measurement.
final Uint8List _leakPayload = Uint8List.fromList(
  List<int>.filled(_payloadKib * 1024, 0x78),
);

/// Resident set size of another process, in KiB, straight from the kernel.
int _rssKib(int pid) {
  final line = File(
    '/proc/$pid/status',
  ).readAsLinesSync().firstWhere((l) => l.startsWith('VmRSS:'));
  return int.parse(line.split(RegExp(r'\s+'))[1]);
}

/// Starts z_storage, waits for it to be ready, and returns its stdout probe.
Future<_MarkerCounter> _startStorage({
  required String endpoint,
  required String keyExpr,
  required String packageRoot,
}) async {
  final process = await Process.start(_dartExe, [
    'run',
    'example/z_storage.dart',
    '-k',
    keyExpr,
    '-l',
    endpoint,
    '--no-multicast-scouting',
  ], workingDirectory: packageRoot);
  addTearDown(() => forceKill(process));

  final counter = _MarkerCounter(process, const [
    'Received PUT',
    'Received DELETE',
  ]);
  addTearDown(counter.cancel);

  await waitForReady(counter.banner);
  // Let the TCP listener finish binding before connecting to it.
  await Future<void>.delayed(const Duration(seconds: 2));
  return counter;
}

/// Opens a session connected to [endpoint], with time to establish.
Future<Session> _connect(String endpoint) async {
  final config = Config()
    ..insertJson5('connect/endpoints', '["$endpoint"]')
    ..insertJson5('scouting/multicast/enabled', 'false');
  final session = await Session.open(config: config);
  addTearDown(session.close);
  await Future<void>.delayed(const Duration(seconds: 2));
  return session;
}

/// Polls until [marker] has been seen [n] times, failing with what was seen.
Future<void> _awaitCount(
  _MarkerCounter counter,
  String marker,
  int n, {
  Duration timeout = const Duration(seconds: 120),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (counter.count(marker) >= n) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail(
    'Timed out after ${timeout.inSeconds}s waiting for $n x "$marker"; '
    'saw ${counter.count(marker)}.',
  );
}

/// Counts markers in a child's stdout without accumulating the stream.
///
/// The two resident-memory cells drive tens of megabytes through z_storage,
/// which echoes every byte of every payload to stdout -- canon's z_storage.c
/// prints the payload too, so that is not something the example should stop
/// doing. Buffering it in this process would cost more memory than the leak
/// being measured, so this keeps only counters, a carry-over for a marker
/// that straddles a chunk boundary, and the first 4 KiB, which is the
/// startup banner the readiness gate reads.
class _MarkerCounter {
  _MarkerCounter(Process process, this._markers)
    : pid = process.pid,
      _carryLen =
          _markers.fold<int>(0, (m, s) => s.length > m ? s.length : m) - 1 {
    _out = process.stdout
        .transform(const SystemEncoding().decoder)
        .listen(_onChunk);
    // stderr must be drained too, or a child that writes enough of it
    // blocks on a full pipe.
    _err = process.stderr.listen((_) {});
  }

  /// The process id, for [_rssKib].
  final int pid;

  final List<String> _markers;
  final int _carryLen;
  late final StreamSubscription<String> _out;
  late final StreamSubscription<List<int>> _err;
  final Map<String, int> _counts = <String, int>{};

  /// The first 4 KiB of stdout, which is where every startup line lands.
  final StringBuffer banner = StringBuffer();

  String _carry = '';

  int count(String marker) => _counts[marker] ?? 0;

  Future<void> cancel() async {
    await _out.cancel();
    await _err.cancel();
  }

  void _onChunk(String chunk) {
    if (banner.length < 4096) {
      final room = 4096 - banner.length;
      banner.write(chunk.length <= room ? chunk : chunk.substring(0, room));
    }
    final text = _carry + chunk;
    for (final marker in _markers) {
      var from = 0;
      while (true) {
        final at = text.indexOf(marker, from);
        if (at < 0) break;
        _counts[marker] = count(marker) + 1;
        from = at + marker.length;
      }
    }
    // Anything that could still be the HEAD of a marker rides along. An
    // occurrence starting inside this tail cannot have completed within
    // `text`, so nothing is ever counted twice.
    _carry = text.length <= _carryLen
        ? text
        : text.substring(text.length - _carryLen);
  }
}
