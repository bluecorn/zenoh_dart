import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/cli_process.dart';

/// The FVM-resolved Dart executable path.
final String _dartExe = Platform.resolvedExecutable;

/// The banner of the example's *second* publish iteration.
///
/// `Putting Data` used to print **before** the first allocation, and on
/// failure the example warned and kept looping -- so every assertion here was
/// satisfiable by a run in which not one SHM byte was ever published. The
/// example now allocates first and prints only on success (canon's order), so
/// even iteration 0's banner lands on the right side of the thing under test.
///
/// Gating on iteration 1 keeps a second allocation inside the window as well,
/// which is what makes the failure-absence assertion below meaningful rather
/// than merely true.
///
/// The index is padded to width 4, as canon's `sprintf("[%4d] %s", ...)` does.
const _secondPutBanner = '[   1]';

/// The line z_pub_shm prints when `allocGcDefragBlocking` returns null.
///
/// canon breaks its publish loop here; so does the example, so this string
/// appearing at all means the run stopped publishing.
const _allocWarning = 'Unexpected failure during SHM buffer allocation';

/// The five SHM examples moved onto the async allocator.
///
/// ENUMERATED, not globbed. The claim is about a decided population -- the
/// ruling was "all five" -- and a glob would silently absorb a sixth SHM
/// example written later without anyone deciding it belonged.
const _shmExamples = <String>[
  'example/z_pub_shm.dart',
  'example/z_pub_shm_thr.dart',
  'example/z_ping_shm.dart',
  'example/z_get_shm.dart',
  'example/z_queryable_shm.dart',
];

/// Where `allocGcDefragBlocking` is still CALLED after the move, and how often.
///
/// ⭐ PROVENANCE, NOT ABSENCE, and the difference is the whole instrument. A
/// bare "no example calls it" is equally satisfied by a scanner that has gone
/// vacuous -- a renamed symbol, a strip that eats too much, a file list that
/// resolved to nothing. This map REQUIRES a surviving caller, so a vacuous
/// scanner fails here while the absence cell above it passes silently.
///
/// The one survivor is the declaration itself: the method stays, unaltered,
/// per a LOCKED register row. ⚠️ `test/` is deliberately outside the census --
/// cells there drive the blocking entry on purpose, and that is not drift.
const _survivingBlockingCallers = <String, int>{
  'lib/src/unstable/shm_provider.dart': 1,
};

/// The exposure each example carries, and the phrase its note must use.
///
/// ⭐ THE GRADING IS PART OF THE RULING. `z_pub_shm`, `z_queryable_shm` and
/// `z_get_shm` allocate while the program is serving; `z_pub_shm_thr` and
/// `z_ping_shm` allocate once at startup -- where a park is still an
/// unkillable process, just a shorter window in which to reach it. A note
/// that flattened the two would tell a reader the wrong thing about their
/// own copy.
const _exposureNote = <String, String>{
  'example/z_pub_shm.dart': 'allocates once per publish iteration',
  'example/z_queryable_shm.dart': 'allocates once per query',
  'example/z_get_shm.dart': 'allocates once per query',
  'example/z_pub_shm_thr.dart': 'allocates once at startup',
  'example/z_ping_shm.dart': 'allocates once at startup',
};

/// The `example/README.md` sections that document an SHM example.
///
/// Keyed by heading, because a section is what a reader actually consults --
/// a tree-wide `contains` would let one paragraph anywhere in a 1300-line
/// file satisfy a claim about five examples.
const _readmeShmSections = <String>[
  '### z_pub_shm — SHM Publisher',
  '### z_get_shm / z_queryable_shm — SHM Query/Reply',
  '### z_ping_shm — SHM Latency Benchmark',
  '### z_pub_thr / z_sub_thr / z_pub_shm_thr — Throughput Benchmarks',
];

/// A call to the blocking allocator, by name.
final RegExp _blockingCall = RegExp(r'\ballocGcDefragBlocking\b');

/// An AWAITED call to the async allocator on a variable named `provider`.
///
/// Anchored on the receiver and on `await`: a bare `allocGcDefragAsync` would
/// be satisfied by the very comment the move adds, and an unawaited call
/// would start a request nobody reads.
final RegExp _awaitedAsyncCall = RegExp(
  r'await\s+provider\s*\.\s*allocGcDefragAsync\s*\(',
);

/// [line] with its `//` comment tail and its string CONTENTS removed.
///
/// Both halves are load-bearing here. An honest migration leaves notes that
/// NAME the retired call -- the hazard-note cell below requires exactly that
/// -- so a raw text scan would go red on an accurate record, which trains the
/// next author to delete the record. String contents go for the mirror-image
/// reason.
String _codeOf(String line) {
  final out = StringBuffer();
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quote != null) {
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        quote = null;
        out.write(c);
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      continue;
    }
    if (c == '/' && i + 1 < line.length && line[i + 1] == '/') break;
    out.write(c);
  }
  return out.toString();
}

/// [path]'s source with every comment and string body removed.
String _codeText(String path) =>
    File(path).readAsStringSync().split('\n').map(_codeOf).join('\n');

/// Every `.dart` file this census covers: the shipped library and the
/// examples. See [_survivingBlockingCallers] for why `test/` is excluded.
List<String> _censusFiles() {
  final out = <String>[];
  for (final root in const ['lib', 'example']) {
    for (final entry in Directory(root).listSync(recursive: true)) {
      if (entry is! File) continue;
      final path = entry.path;
      if (!path.endsWith('.dart')) continue;
      if (path.endsWith('bindings.dart')) continue;
      out.add(path);
    }
  }
  return out;
}

/// The text of [heading]'s section in [readme], up to the next `### `.
String _readmeSection(String readme, String heading) {
  final start = readme.indexOf(heading);
  expect(start, isNot(-1), reason: 'README section not found: $heading');
  final next = readme.indexOf('### ', start + heading.length);
  return readme.substring(start, next < 0 ? readme.length : next);
}

void main() {
  final packageRoot = Directory.current.path;

  group(
    'z_pub_shm CLI',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      test(
        'runs and prints SHM provider creation and publisher declaration',
        () async {
          final process = await Process.start(_dartExe, [
            'run',
            'example/z_pub_shm.dart',
          ], workingDirectory: packageRoot);
          addTearDown(() => forceKill(process));

          final stdout = StringBuffer();
          final subscription = process.stdout
              .transform(const SystemEncoding().decoder)
              .listen(stdout.write);

          // Wait for the SECOND publish banner, not the first: see
          // [_secondPutBanner]. The window this opens is what makes the
          // warning-absence assertion below decisive.
          await waitForOutput(stdout, _secondPutBanner);
          await forceKill(process);
          await subscription.cancel();

          final output = stdout.toString();
          expect(output, contains('Opening session...'));
          expect(output, contains('Creating POSIX SHM Provider...'));
          expect(output, contains('Declaring Publisher'));
          expect(output, contains('Putting Data'));
          // The one assertion that distinguishes "published via SHM" from
          // "printed a banner and then failed to allocate".
          expect(output, isNot(contains(_allocWarning)));
        },
      );

      test('accepts -k and -p flags', () async {
        final process = await Process.start(_dartExe, [
          'run',
          'example/z_pub_shm.dart',
          '-k',
          'demo/shm/test',
          '-p',
          'SHM data',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final stdout = StringBuffer();
        final subscription = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdout.write);

        // Both asserted strings appear together in the 'Putting Data' line;
        // waiting for the second one also puts an allocation inside the window
        // (see [_secondPutBanner]).
        await waitForOutput(stdout, _secondPutBanner);
        await forceKill(process);
        await subscription.cancel();

        final output = stdout.toString();
        expect(output, contains('demo/shm/test'));
        expect(output, contains('SHM data'));
        expect(output, isNot(contains(_allocWarning)));
      });

      test('runs with --add-matching-listener without error', () async {
        final process = await Process.start(_dartExe, [
          'run',
          'example/z_pub_shm.dart',
          '--add-matching-listener',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final stdout = StringBuffer();
        final stderr = StringBuffer();
        final stdoutSub = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdout.write);
        final stderrSub = process.stderr
            .transform(const SystemEncoding().decoder)
            .listen(stderr.write);

        await waitForOutput(stdout, _secondPutBanner);
        await forceKill(process);
        await stdoutSub.cancel();
        await stderrSub.cancel();

        final output = stdout.toString();
        expect(output, contains('Opening session...'));
        expect(output, contains('Putting Data'));
        expect(output, isNot(contains(_allocWarning)));
      });

      test('runs with -e endpoint without error', () async {
        final process = await Process.start(_dartExe, [
          'run',
          'example/z_pub_shm.dart',
          '-e',
          'tcp/127.0.0.1:7447',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final stdout = StringBuffer();
        final subscription = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdout.write);

        // -e points at an endpoint with nothing listening, so the example may
        // never reach its readiness banner. Wait only for the line this test
        // actually asserts. See the audit note above about what it does not.
        await waitForOutput(stdout, 'Opening session...');
        await forceKill(process);
        await subscription.cancel();

        final output = stdout.toString();
        // At minimum, it parsed the flag and attempted to open a session
        expect(output, contains('Opening session...'));
      });

      // ⛔⛔ EVERY OTHER CELL IN THIS FILE IS BLIND TO WHAT IS IN THE CHUNK.
      // Measured at this slice by writing the message at HALF length: all
      // four stdout-only cells above stayed GREEN, because the strings they
      // assert are built from the Dart value and this example never reads its
      // buffer back. Only a RECEIVER can tell a filled chunk from a
      // half-filled one, so this cell subscribes to the example.
      //
      // It is also the cell that makes "the existing cells are the oracle"
      // true for this file at all, which a move onto a different allocator
      // needs it to be.
      test('publishes the bytes it wrote into the chunk, SHM-backed', () async {
        const endpoint = 'tcp/127.0.0.1:19763';
        const key = 'demo/cli/pubshm';
        const value = 'fill-oracle-probe';

        final process = await Process.start(_dartExe, [
          'run',
          'example/z_pub_shm.dart',
          '-k',
          key,
          '-p',
          value,
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
        // Settle time for the TCP listener to bind and negotiate.
        await Future<void>.delayed(const Duration(seconds: 3));

        final session = await Session.open(
          config: Config()..insertJson5('connect/endpoints', '["$endpoint"]'),
        );
        addTearDown(session.close);
        await Future<void>.delayed(const Duration(seconds: 2));

        final subscriber = session.declareSubscriber(key, retainPayload: true);
        addTearDown(subscriber.close);

        final sample = await subscriber.stream.first.timeout(
          const Duration(seconds: 20),
        );
        final bytes = sample.payloadBytes;
        final retained = sample.payloadZBytes;
        addTearDown(() => retained?.dispose());

        // canon publishes the WHOLE buffer, residual bytes included
        // (z_pub_shm.c:76-95), so the frame is `total_size / 4` wide however
        // short the message is.
        expect(
          bytes.length,
          1024,
          reason:
              "the frame is not canon's fixed buffer: the example sized "
              'the allocation to its message, or published a slice of it',
        );

        final text = utf8.decode(bytes, allowMalformed: true);
        final match = RegExp(
          r'^\[ *\d+\] '
          '${RegExp.escape(value)}',
        ).firstMatch(text);
        expect(
          match,
          isNotNull,
          reason:
              'the chunk does not carry the message the example printed; '
              'a short or shifted fill is invisible to every other cell in '
              'this file:\n${jsonEncode(text.substring(0, 40))}',
        );
        expect(
          bytes.skip(match!.end).every((b) => b == 0),
          isTrue,
          reason:
              "the residue past the message is not the fresh segment's "
              'zeroes, so more was written into the chunk than was printed',
        );
        expect(
          retained?.isShmBacked,
          isTrue,
          reason:
              'the payload arrived without shared-memory backing -- the '
              'example published a heap copy, and every SHM claim this file '
              'makes is about a banner rather than a transport',
        );
      }, timeout: const Timeout(Duration(seconds: 90)));

      // ⚠️ GREEN BEFORE THE MOVE AS WELL, and stated rather than implied:
      // with canon's own 4096/1024 pair the blocking call never parks, so
      // Ctrl-C already worked here. What this cell guards is that the move
      // did not take it away -- the loop must still observe a signal and run
      // its shutdown to completion, exiting on its own rather than being
      // SIGKILLed by [forceKill].
      test('shuts down on SIGINT while the publish loop is ticking', () async {
        final process = await Process.start(_dartExe, [
          'run',
          'example/z_pub_shm.dart',
        ], workingDirectory: packageRoot);
        addTearDown(() => forceKill(process));

        final stdout = StringBuffer();
        final subscription = process.stdout
            .transform(const SystemEncoding().decoder)
            .listen(stdout.write);
        addTearDown(subscription.cancel);

        // The loop has provably ticked at least twice before the signal.
        await waitForOutput(stdout, _secondPutBanner);
        expect(process.kill(ProcessSignal.sigint), isTrue);

        final exitCode = await process.exitCode.timeout(
          const Duration(seconds: 20),
          onTimeout: () => fail('the example did not exit on SIGINT:\n$stdout'),
        );
        expect(
          exitCode,
          0,
          reason: 'the example exited on SIGINT but not cleanly:\n$stdout',
        );
        expect(stdout.toString(), isNot(contains(_allocWarning)));
      }, timeout: const Timeout(Duration(seconds: 90)));
    },
  );

  // Source-anchored, and deliberately OUTSIDE the shared-memory skip: what
  // these assert about the files is true on every variant, and a
  // stable-variant run that silently skipped them would be the run in which
  // the move rotted.
  group('the SHM examples and the blocking allocator', () {
    test('every SHM example awaits the async allocator instead', () {
      for (final path in _shmExamples) {
        expect(
          File(path).existsSync(),
          isTrue,
          reason: '$path is in the moved population but is not on disk',
        );
        final code = _codeText(path);
        expect(
          _blockingCall.hasMatch(code),
          isFalse,
          reason:
              '$path still CALLS the blocking allocator; naming it in the '
              'note is the point, calling it is not',
        );
        expect(
          _awaitedAsyncCall.hasMatch(code),
          isTrue,
          reason:
              '$path does not await provider.allocGcDefragAsync(...); an '
              'unawaited request is one nobody reads, and a second one on the '
              'same provider throws',
        );
      }
    });

    test('the blocking allocator survives where it is declared -- provenance, '
        'not absence', () {
      final surviving = <String, int>{};
      for (final path in _censusFiles()) {
        final hits = _blockingCall.allMatches(_codeText(path)).length;
        if (hits > 0) surviving[path] = hits;
      }
      expect(
        surviving,
        equals(_survivingBlockingCallers),
        reason:
            'the census moved. If it is EMPTY the scanner has gone vacuous '
            'and the cell above it is passing on nothing; if it gained an '
            'entry, a caller came back',
      );
    });

    test('the divergence is stated at every site, with exposure graded', () {
      for (final path in _shmExamples) {
        final source = File(path).readAsStringSync();
        expect(
          source,
          contains('allocGcDefragBlocking'),
          reason:
              '$path diverges from canon without saying so; an example is '
              'a parity artifact, and an unstated divergence reads as canon',
        );
        // 'signal handler', not 'signal': z_queryable_shm's serialization
        // comment says "resume signal", which the looser form would have
        // accepted in place of the ground this cell is about.
        expect(
          source,
          contains('signal handler'),
          reason:
              '$path states the divergence without its ground -- canon '
              'installs no signal handler, so SIGINT still kills it while it '
              'is parked, and ours does not',
        );
        final exposure = _exposureNote[path]!;
        expect(
          source,
          contains(exposure),
          reason:
              '$path does not grade its own exposure. Per-iteration and '
              'once-at-startup are different risks, and the note must say '
              'which this file is',
        );
      }
    });

    test("z_pub_shm's hazard note is rewritten, not deleted", () {
      final source = File('example/z_pub_shm.dart').readAsStringSync();

      // It says what this example now calls...
      expect(source, contains('allocGcDefragAsync'));
      // ...records that canon uses the blocking call, at the line that does...
      expect(
        source,
        contains('z_pub_shm.c:80'),
        reason:
            'the note must cite what canon actually does, not merely that '
            'this file differs from it',
      );
      // ...and names the asymmetry that FORCES the divergence.
      expect(
        source,
        contains('installs no signal handler'),
        reason:
            'without this the divergence reads as taste. Faithfulness to '
            "canon's CALL would be infidelity to canon's BEHAVIOUR",
      );
      // The stale claim must GO rather than be reworded: the async allocator
      // is bound now, and a removed marker is only assertable as an absence.
      expect(source, isNot(contains('does not bind yet')));
    });

    test(
      "the full hazard still lives on the blocking sibling's own dartdoc",
      () {
        // ⛔ The BYTE-FOR-BYTE fingerprint of that region lives in
        // `test/shm_async_alloc_test.dart` ('the blocking sibling is untouched
        // by this slice') and is not duplicated here -- two copies of a magic
        // length is a maintenance trap. What this cell adds is the CONTENT
        // claim the acceptance criterion makes: the hazard table did not move
        // out of the dartdoc and into an example note.
        final lib = File('lib/src/unstable/shm_provider.dart')
            .readAsStringSync();
        const waitRow =
            '/// | a size the pool can satisfy *after* waiting | '
            'parks, then returns |';
        for (final row in const [
          '/// | a size the pool can satisfy | returns [AllocOk] |',
          waitRow,
          '/// | a size the pool can **never** satisfy | **parks forever** |',
          '/// | `size: 0` | returns a layout error immediately |',
        ]) {
          expect(
            lib,
            contains(row),
            reason:
                'the blocking allocator lost a row of its hazard table: '
                '$row',
          );
        }
        expect(
          lib,
          contains(
            'AllocResult allocGcDefragBlocking(int size, '
            '{AllocAlignment? alignment}) =>',
          ),
          reason:
              'the blocking sibling was renamed or resignatured; a LOCKED '
              'register row says it stays',
        );
      },
    );

    test('the SHM sections of the example README follow the examples', () {
      final readme = File('example/README.md').readAsStringSync();
      for (final heading in _readmeShmSections) {
        final section = _readmeSection(readme, heading);
        expect(
          section,
          contains('allocGcDefragAsync'),
          reason:
              'the README still documents a mechanism these examples no '
              'longer perform: $heading',
        );
        expect(
          section,
          contains('signal handler'),
          reason:
              'the divergence from canon is recorded without its ground '
              'in $heading -- a reader is told what differs and not why it '
              'has to',
        );
      }
    });
  });
}
