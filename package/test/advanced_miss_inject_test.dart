// The first executed end-to-end coverage of the native miss-callback bridge.
//
// Until this file, `AdvancedSubscriber.missEvents` had none: its only live
// test self-skipped on every run, and its own skip message named the problem —
// "a broken bridge is indistinguishable from a skipped test." Over reliable
// loopback nothing is ever missed, so no arrangement of real publishers and
// subscribers drives a miss event.
//
// `test/helpers/miss_injector.c` is what drives one. It is a real canon-C
// advanced publisher that also accepts a command to publish a raw `z_put`
// carrying a crafted `z_source_info_t`, claiming its own identity with a
// sequence number that skips ahead. The subscriber's gap tracker keys on that
// number, so the miss it reports has arithmetic we chose — which is what makes
// the assertions identity- and count-EXACT rather than "at least one".
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/cli_process.dart';

/// Where the ABI-correct generated headers live, relative to `package/`.
///
/// NOT `../extern/zenoh-c/include`. Those copies of `zenoh_opaque.h` and
/// `zenoh_configure.h` are cargo-generated, excluded by the submodule's own
/// .gitignore, and clobbered by every full build; compiling against them
/// declares a 240-byte advanced-publisher struct against a library that writes
/// 248 — nine bytes out of bounds, with rc 0 throughout and correct-looking
/// output. `src/CMakeLists.txt` enforces the same rule for the shim and states
/// the reason there.
const buildTreeIncludes = '../build/linux-x64/extern/zenoh-c/release/include';

const unstableLibDir = 'native/linux/x86_64/unstable';

/// Compiles [source] to [output]; returns clang's own [ProcessResult].
Future<ProcessResult> compileAgainstZenoh(String source, String output) {
  return Process.run('clang', [
    '-O0',
    '-g',
    source,
    '-I',
    buildTreeIncludes,
    '-L',
    unstableLibDir,
    '-lzenohc',
    '-Wl,-rpath,${Directory.current.path}/$unstableLibDir',
    '-o',
    output,
  ]);
}

/// A running injector, with line-oriented reads over its stdout.
class Injector {
  Injector(this._process) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add);
    // Never asserted on, only surfaced when a wait fails: this cell crosses
    // the wire, so silence on stderr is not something to assert.
    _process.stderr.transform(utf8.decoder).listen(stderr.write);
  }

  final Process _process;
  final List<String> lines = [];

  /// Polls for the first line starting with [prefix]. Fails the cell red on
  /// timeout — a bridge that never answers must never hang the serial suite.
  Future<String> waitForLine(
    String prefix, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      for (final l in lines) {
        if (l.startsWith(prefix)) return l;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail(
      'injector never printed a line starting with "$prefix" within $timeout\n'
      '--- injector stdout ---\n${lines.join('\n')}',
    );
  }

  void send(String command) => _process.stdin.writeln(command);

  Future<void> kill() => forceKill(_process);
}

void main() {
  group(
    'AdvancedSubscriber miss injection (TCP 19413)',
    // ⚠️ GATE ORDER IS LOAD-BEARING. This group gate ENCLOSES the setUpAll
    // compile, and it must: the injector links against
    // native/linux/x86_64/unstable, whose advanced symbols do not exist under
    // the stable variant and whose libzenohc.so is a different build. So on
    // the stable matrix leg the whole group is skipped by the established
    // gate — a designed skip — and INSIDE the unstable leg nothing skips at
    // all. The two rules ("the unstable skip-gate composes" and "this cell
    // never skips") must not meet in the other order.
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late Directory tmp;
      late String injectorPath;

      setUpAll(() async {
        // FAIL LOUD, never skip. This cell is the SOLE executed coverage of a
        // bridge whose recorded debt is literally "a broken bridge is
        // indistinguishable from a skipped test", so a toolchain-conditional
        // skip would re-create the very debt it discharges.
        if (!Directory(buildTreeIncludes).existsSync()) {
          fail(
            'the ABI-correct generated headers are missing at '
            '$buildTreeIncludes.\n'
            'Build them first: cmake --preset linux-x64 (or its shim-only '
            'sibling) from the repo root. The source-tree copies under '
            'extern/zenoh-c/include are NOT a substitute — they are '
            'cargo-generated, ABI-mismatched, and compiling against them '
            'writes out of bounds.',
          );
        }

        tmp = await Directory.systemTemp.createTemp('seed8_injector_');
        injectorPath = '${tmp.path}/miss_injector';
        final r = await compileAgainstZenoh(
          'test/helpers/miss_injector.c',
          injectorPath,
        );
        if (r.exitCode != 0) {
          fail(
            'failed to compile test/helpers/miss_injector.c\n'
            '--- clang stderr ---\n${r.stderr}',
          );
        }
      });

      tearDownAll(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      /// Spawns a FRESH injector.
      ///
      /// ⚠️ Fresh per cell, deliberately, and Slice 11's exact count depends on
      /// it. Source sequence numbers are per-publisher and monotonic: sharing
      /// one process with the five-put control below would make a later cell's
      /// puts the sixth and seventh, last-seen sn 6, and `GAP 10` would yield a
      /// gap of 3 rather than 8 — a red against an assertion that must not be
      /// loosened, and one that would read as a broken shipped bridge rather
      /// than as a stale baseline. Each cell declares its own subscriber for
      /// the same reason: the Dart-side gap tracker carries the identical
      /// dependency.
      Future<Injector> startInjector(String keyExpr) async {
        final process = await Process.start(injectorPath, [
          'tcp/127.0.0.1:19413',
          keyExpr,
        ]);
        final injector = Injector(process);
        addTearDown(injector.kill);
        await injector.waitForLine('INJECTOR_READY');
        return injector;
      }

      Future<Session> connectSession() async {
        final config = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19413"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false')
          ..insertJson5('timestamping/enabled', 'true');
        final session = await Session.open(config: config);
        addTearDown(session.close);
        return session;
      }

      AdvancedSubscriber missSubscriber(Session session, String keyExpr) {
        final subscriber = session.declareAdvancedSubscriber(
          keyExpr,
          options: const AdvancedSubscriberOptions(
            enableMissListener: true,
            recovery: true,
            lastSampleMissDetection: true,
          ),
        );
        addTearDown(subscriber.close);
        return subscriber;
      }

      test('the instrument reports a well-formed harvested identity', () async {
        final injector = await startInjector('zenoh/dart/inject/id');
        final id = await injector.waitForLine('INJECTOR_ID ');

        // INJECTOR_READY has already been seen by startInjector, and the
        // injector prints INJECTOR_ID strictly before it — so this assertion
        // lands after the harvest, not before it.
        final fields = id.split(' ');
        expect(fields, hasLength(3));
        // Exactly 32 digits, because the injector renders the zid front to
        // back like ZenohId.toHexString() does, never through canon's
        // z_id_to_string — which differs on byte order AND strips leading
        // zeros, a measured 1-in-16 chance of 31 digits.
        expect(fields[1], matches(RegExp(r'^[0-9a-f]{32}$')));
        expect(int.tryParse(fields[2]), isNotNull);
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('the control: a healthy stream delivers with zero miss events', () async {
        const key = 'zenoh/dart/inject/healthy';
        final injector = await startInjector(key);
        final session = await connectSession();
        final subscriber = missSubscriber(session, key);

        final samples = <Sample>[];
        final misses = <MissEvent>[];
        final sampleSub = subscriber.stream.listen(samples.add);
        final missSub = subscriber.missEvents!.listen(misses.add);
        addTearDown(sampleSub.cancel);
        addTearDown(missSub.cancel);

        await Future<void>.delayed(const Duration(seconds: 1));

        // Each put is OBSERVED before the next is sent, so the stream really
        // is established rather than merely written to.
        for (var i = 0; i < 5; i++) {
          injector.send('PUT');
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (samples.length <= i && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(
            samples.length,
            greaterThan(i),
            reason: 'put $i not delivered',
          );
        }

        await Future<void>.delayed(const Duration(seconds: 2));

        expect(samples, hasLength(5));
        // THIS IS THE CONTROL THAT MAKES THE INJECTED CELL MEAN ANYTHING. A
        // miss stream that fired unconditionally would satisfy an
        // "exactly one miss" assertion while proving nothing about the bridge.
        expect(misses, isEmpty);
      }, timeout: const Timeout(Duration(seconds: 120)));

      test(
        'an injected gap yields exactly one miss event with the exact count',
        () async {
          const key = 'zenoh/dart/inject/gap';
          final injector = await startInjector(key);

          final session = await connectSession();
          final subscriber = missSubscriber(session, key);

          final samples = <Sample>[];
          final misses = <MissEvent>[];
          final sampleSub = subscriber.stream.listen(samples.add);
          final missSub = subscriber.missEvents!.listen(misses.add);
          addTearDown(sampleSub.cancel);
          addTearDown(missSub.cancel);

          await Future<void>.delayed(const Duration(seconds: 1));

          // Baseline: two REAL advanced puts, each observed before the next, so
          // the subscriber's gap tracker has actually seen source sn 0 and 1.
          // Without that baseline there is nothing to measure a gap against.
          for (var i = 0; i < 2; i++) {
            injector.send('PUT');
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (samples.length <= i && DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            expect(
              samples.length,
              greaterThan(i),
              reason: 'baseline put $i not delivered',
            );
          }

          // Last seen is sn 1; a crafted sn 10 therefore skips 2..9 -- eight.
          injector.send('GAP 10');
          await injector.waitForLine('GAP_DONE 10');

          final deadline = DateTime.now().add(const Duration(seconds: 15));
          while (misses.isEmpty && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          // Red, never a hang: this bridge had no executed coverage at all, so
          // if it is in fact broken the cell must fail rather than stall the
          // serial suite.
          expect(
            misses,
            isNotEmpty,
            reason:
                'no MissEvent within 15s -- the shipped bridge did not fire',
          );

          await Future<void>.delayed(const Duration(seconds: 2));

          expect(misses, hasLength(1));
          // Exact arithmetic, never "at least one": 10 - 1 - 1 = 8.
          expect(misses.single.count, equals(8));
        },
        timeout: const Timeout(Duration(seconds: 120)),
      );

      test('the miss event carries the harvested identity exactly', () async {
        const key = 'zenoh/dart/inject/identity';
        final injector = await startInjector(key);
        final idLine = await injector.waitForLine('INJECTOR_ID ');
        final idFields = idLine.split(' ');
        final injectedZid = idFields[1];
        final injectedEid = int.parse(idFields[2]);

        final session = await connectSession();
        final subscriber = missSubscriber(session, key);

        final samples = <Sample>[];
        final misses = <MissEvent>[];
        final sampleSub = subscriber.stream.listen(samples.add);
        final missSub = subscriber.missEvents!.listen(misses.add);
        addTearDown(sampleSub.cancel);
        addTearDown(missSub.cancel);

        await Future<void>.delayed(const Duration(seconds: 1));

        for (var i = 0; i < 2; i++) {
          injector.send('PUT');
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (samples.length <= i && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(
            samples.length,
            greaterThan(i),
            reason: 'baseline put $i not delivered',
          );
        }

        injector.send('GAP 7');
        await injector.waitForLine('GAP_DONE 7');

        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (misses.isEmpty && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          misses,
          isNotEmpty,
          reason: 'no MissEvent within 15s -- the shipped bridge did not fire',
        );

        // The first executed proof of the z_entity_global_id_zid /
        // z_entity_global_id_eid conveyance through _zd_miss_callback. Equality
        // on BOTH fields against values the injector printed -- no isNotNull,
        // no greaterThan(0).
        //
        // REPAIRED at seed #9: the zid half compares BYTES, not strings.
        //
        // This cell is about IDENTITY CONVEYANCE through _zd_miss_callback --
        // whether the sixteen bytes canon harvested arrive intact. It should
        // not depend on the rendering contract at all, and until this seed it
        // did: it compared our toHexString() against the injector's
        // front-to-back %02x print, which agreed only because BOTH were
        // storage order. Now that toHexString() renders canon's form, that
        // comparison would flip -- so it moves to the bytes path, which is the
        // fidelity ground truth and is what this cell actually cares about.
        //
        // miss_injector.c is deliberately NOT changed. Its header says why it
        // prints front-to-back rather than through z_id_to_string: an
        // instrument whose whole point is to avoid crossing a divergence
        // should not import canon's renderer. Its own `{32}` well-formedness
        // pin therefore stays green, untouched.
        final event = misses.single;
        final injectedBytes = Uint8List.fromList([
          for (var i = 0; i < injectedZid.length; i += 2)
            int.parse(injectedZid.substring(i, i + 2), radix: 16),
        ]);
        expect(event.sourceId.zid.bytes, equals(injectedBytes));
        expect(event.sourceId.eid, equals(injectedEid));
        expect(event.count, equals(5));
      }, timeout: const Timeout(Duration(seconds: 120)));

      test('a build failure fails loudly rather than skipping', () async {
        // Drives R9's fail-loud path for real instead of asserting it
        // structurally: a source that cannot compile must produce clang's own
        // stderr, which is what the setUpAll above quotes.
        final broken = File('${tmp.path}/broken.c')
          ..writeAsStringSync(
            '#include <zenoh.h>\nint main(void) { return }\n',
          );
        final r = await compileAgainstZenoh(
          broken.path,
          '${tmp.path}/broken.out',
        );
        expect(r.exitCode, isNot(0));
        expect('${r.stderr}', contains('error'));
        // And the control: the same helper on the REAL source succeeds, so the
        // failure above is the snippet's and not the toolchain's.
        final ok = await compileAgainstZenoh(
          'test/helpers/miss_injector.c',
          '${tmp.path}/control.out',
        );
        expect(ok.exitCode, equals(0), reason: '${ok.stderr}');
      }, timeout: const Timeout(Duration(seconds: 60)));
    },
  );
}
