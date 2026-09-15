// Seed [CC] — `CongestionControl.blockFirst` is REFUSED on a native built
// without `Z_FEATURE_UNSTABLE_API`, at every send entry point that takes one.
//
// ⛔ WHY EVERY BEHAVIOURAL ASSERTION HERE RUNS IN A CHILD PROCESS. The thing
// under test is a property of the LOADED NATIVE. The default suite loads the
// `unstable` one — where `blockFirst` is legal and nothing is refused — so an
// in-process cell would assert the opposite of what this unit ships, and
// pass. The variant is selected by `ZENOH_DART_VARIANT`, and an environment
// variable can only be set for a child.
//
// ⛔ AND THE CHILD IS NOT TRUSTED TO BE THE RIGHT CHILD. `armingFailure`
// reads the probe's first row and FAILS every cell below if the loaded native
// carries the unstable API, or was resolved from outside the stable variant
// directory. It does not skip. A skip on a blind instrument reads as "did not
// run"; the truth is "ran, and could not have seen the defect" — the false
// green the retired variant matrix used to produce.
//
// ⛔ THE UNSTABLE HALF IS NOT HERE. That `blockFirst` still reaches the wire
// unchanged lives in `subscriber_test.dart`'s F13 group, beside the cell it
// must not disturb, because it needs two linked sessions and this file has
// none. Its absence here is deliberate, not an omission.
//
// ⚠️ WHAT NO CELL IN THIS FILE CLAIMS. At `get`, `pullGet` and
// `declareQuerier` the wire value is unobserved AND unobservable: canon
// exposes no request-side QoS accessor, on either build. Those three sites
// are pinned structurally — the marshal expression is asserted to be
// unchanged — and no round-trip pair is manufactured for them.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/congestion_control.dart';

import 'helpers/changelog_section.dart';

/// What one probe run produced, INCLUDING whether it ended on its own.
class ProbeRun {
  ProbeRun(this.stdout, this.stderr, this.exitCode, {required this.timedOut});

  final String stdout;
  final String stderr;
  final int exitCode;

  /// True when the child had to be killed. ⛔ Not an infrastructure detail:
  /// "this process exited by itself" is one of the assertions.
  final bool timedOut;

  String get all => '$stdout$stderr';
}

/// One `dart run` of a probe under `test/helpers/`, with [environment] ADDED
/// to this process's own, and BOUNDED.
///
/// ⛔ NOT `Process.run`, and the difference is load-bearing. `Process.run`
/// waits forever. A refused `get` that had opened its `ReceivePort` before
/// throwing leaves that port pinning the child's isolate, so the child prints
/// every row it was asked for and then never exits — and under `Process.run`
/// that surfaces as the whole suite hanging, which is not a red anyone can
/// read. It is also exactly the defect the exit-code cell exists to catch, so
/// the instrument has to survive it. Killing the child and recording
/// [ProbeRun.timedOut] turns a hang into a failing assertion with a reason.
///
/// ⚠️ `includeParentEnvironment` stays at its default `true`: the child needs
/// the inherited PATH and PUB_CACHE to run at all.
Future<ProbeRun> runProbe(
  String helper, {
  Map<String, String> environment = const {},
  Duration limit = const Duration(seconds: 120),
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'test/helpers/$helper'],
    environment: environment,
  );
  final out = StringBuffer();
  final err = StringBuffer();
  final drained = Future.wait<void>([
    process.stdout.transform(utf8.decoder).forEach(out.write),
    process.stderr.transform(utf8.decoder).forEach(err.write),
  ]);

  var timedOut = false;
  final code = await process.exitCode.timeout(
    limit,
    onTimeout: () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  try {
    await drained.timeout(const Duration(seconds: 5));
  } on Object {
    // After a kill the pipes may not close promptly. What was read is enough:
    // every row the child managed to emit is already in the buffers.
  }
  return ProbeRun('$out', '$err', code, timedOut: timedOut);
}

/// See `open_detail_secrets_test.dart` for why prose is read flattened.
/// ⚠️ LOWERCASED, and needles must be lowercase too.
String flattenedProse(String path) =>
    File(path)
        .readAsStringSync()
        .replaceAll(RegExp(r'^\s*///?', multiLine: true), ' ')
        .replaceAll('*', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .toLowerCase();

/// The dartdoc block immediately above [declaration] in the file at [path],
/// flattened the same way.
///
/// Adjacency, not a file-wide scan: "this entry point documents its own
/// refusal" is a claim about where the sentence sits, and a whole-file grep
/// cannot see where anything sits.
String dartdocAbove(String path, String declaration) {
  final source = File(path).readAsStringSync();
  final at = source.indexOf(declaration);
  expect(
    at,
    greaterThanOrEqualTo(0),
    reason: '$declaration not found in $path',
  );
  final lines = source.substring(0, at).split('\n');
  final doc = <String>[];
  for (var i = lines.length - 2; i >= 0; i--) {
    final line = lines[i].trimLeft();
    if (line.startsWith('///')) {
      doc.insert(0, line.substring(3).trim());
    } else if (line.startsWith('@') || line.isEmpty) {
      continue;
    } else {
      break;
    }
  }
  return doc
      .join(' ')
      .replaceAll('*', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .toLowerCase();
}

/// [path]'s source with every comment line removed.
///
/// The tree's idiom (`reply_options_test.dart:276`): a source-text assertion
/// must not be satisfiable by a comment that happens to quote the code.
String code(String path) =>
    File(path)
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

/// The seven public entry points that accept a `CongestionControl`, by the
/// declaration text that identifies each uniquely in `session.dart`.
const sevenEntryPoints = <String>[
  'void put(',
  'void putBytes(',
  'void deleteResource(',
  'Publisher declarePublisher(',
  'Querier declareQuerier(',
  'Stream<Reply> get(',
  'PullReplies pullGet(',
];

void main() {
  group(
    '[CC] the block-first guard, on the stable native',
    () {
      late ProbeRun result;
      late String output;
      final rows = <String, Map<String, Object?>>{};

      /// Non-null when the instrument is NOT usable, carrying the reason.
      String? armingFailure;

      setUpAll(() async {
        result = await runProbe(
          'blockfirst_guard_probe.dart',
          environment: {'ZENOH_DART_VARIANT': 'stable'},
        );
        output = result.all;
        final lines = const LineSplitter().convert(result.stdout);
        for (final line in lines) {
          if (!line.startsWith('{')) continue;
          final decoded = jsonDecode(line) as Map<String, dynamic>;
          rows['${decoded['case']}'] = decoded;
        }

        final armed = rows['ARMED'];
        // ⛔ A KILLED CHILD IS NOT, BY ITSELF, AN ARMING FAILURE. A probe that
        // emitted every row and then failed to exit has produced trustworthy
        // rows AND demonstrated a pinned isolate — which is a specific cell's
        // assertion, not a reason to fail every cell with one message.
        // Missing rows are the arming failure, and `PROBE_DONE` is what says
        // whether any are missing.
        if (!result.stdout.contains('PROBE_DONE')) {
          armingFailure =
              'the probe did not reach its own end'
              '${result.timedOut ? ' and had to be killed' : ''}, so the rows '
              'below are incomplete and nothing here can be read as an '
              'answer.\nexit=${result.exitCode}\n$output';
        } else if (armed == null) {
          armingFailure =
              'the probe emitted no ARMED row — it did not reach '
              'its first statement, so nothing below ran on any native.\n'
              'exit=${result.exitCode}\n$output';
        } else if (armed['unstableApi'] != false) {
          armingFailure =
              'the probe loaded a native WITH the unstable API '
              '(${armed['libraryPath']}). Every assertion below would then '
              'measure the variant this unit does not change. That is a '
              'FAILURE, not a skip: the instrument was blind, it did not sit '
              'out.\n$output';
        } else if (!'${armed['libraryPath']}'.contains(
          'native/linux/x86_64/stable/',
        )) {
          armingFailure =
              'the probe reported the unstable API absent but '
              'resolved its library from ${armed['libraryPath']}, which is '
              'not the stable variant directory — so what it measured is '
              'unattributable.\n$output';
        }
      });

      /// The named row, or a FAILURE naming why there is no answer.
      Map<String, Object?> row(String name) {
        final failure = armingFailure;
        if (failure != null) fail(failure);
        final found = rows[name];
        if (found == null) {
          fail(
            'the probe emitted no $name row.\n'
            'exit=${result.exitCode}\n$output',
          );
        }
        return found;
      }

      /// One arm of a control row, in the shape `drive` emits.
      Map<String, Object?> arm(String rowName, String armName) =>
          row(rowName)[armName]! as Map<String, Object?>;

      /// Asserts the named row is a refusal that names `congestionControl`.
      void expectRefused(String name, {required String what}) {
        final refusal = row(name);
        expect(
          refusal['threw'],
          isTrue,
          reason:
              '$what accepted blockFirst on a native without '
              'Z_FEATURE_UNSTABLE_API — canon received a discriminant '
              'outside its enum, and nothing was reported',
        );
        expect(
          refusal['type'],
          'ArgumentError',
          reason: '${refusal['message']}',
        );
        expect(refusal['name'], 'congestionControl');
        expect(refusal['invalidValue'], 'CongestionControl.blockFirst');
      }

      /// Asserts all three control arms of [name] completed.
      void expectControlsPass(String name, {required String what}) {
        for (final which in const ['block', 'drop', 'omitted']) {
          final call = arm(name, which);
          expect(
            call['threw'],
            isFalse,
            reason:
                '$what with congestionControl=$which threw '
                '${call['message']} on the stable native — the guard is not '
                'specific to blockFirst',
          );
        }
      }

      // --- the instrument -------------------------------------------------

      test('the instrument is armed before any row is read', () {
        // ⛔ THIS CELL IS WHY EVERY OTHER ONE MEANS ANYTHING. It reads the
        // same first row `armingFailure` was computed from, so a probe that
        // loaded the wrong native fails HERE, by name, rather than producing
        // a page of confident greens about a variant nobody selected.
        expect(armingFailure, isNull, reason: '$armingFailure');
        final armed = row('ARMED');
        expect(armed['unstableApi'], isFalse);
        expect(
          '${armed['libraryPath']}',
          contains('native/linux/x86_64/stable/'),
        );
      });

      // --- A1: the refusal ------------------------------------------------

      test('Session.put refuses blockFirst', () {
        expectRefused('PUT', what: 'Session.put');
      });

      test('the diagnostic names the real cause and BOTH real remedies', () {
        final message = '${row('PUT')['message']}';
        // The cause, at the two names a reader can search canon for.
        expect(message, contains('Z_FEATURE_UNSTABLE_API'));
        expect(message, contains('Z_CONGESTION_CONTROL_BLOCK_FIRST'));
        // Remedy one — a value every build carries. `requireUnstable()`'s
        // text lacks this entirely, which is half of why it is the wrong
        // message to reuse here.
        expect(message, contains('CongestionControl.block'));
        expect(message, contains('CongestionControl.drop'));
        // Remedy two — the variant selection, at the key a reader must type.
        expect(message, contains('user_defines'));
        expect(message, contains('variant: unstable'));
        // ⛔ THE NEGATIVE NEEDLE IS THE HALF THAT DISCRIMINATES. Every
        // positive above also passes on `requireUnstable()`'s message with a
        // sentence appended. This one does not: a stable-door caller never
        // imported `zenoh_unstable`, so telling them it "requires the
        // unstable native variant" names a door they are not standing at.
        expect(
          message,
          isNot(
            contains('zenoh_unstable requires the `unstable` native variant'),
          ),
          reason: "the door gate's text reached a stable-door refusal",
        );
      });

      test('Session.putBytes refuses blockFirst', () {
        expectRefused('PUTBYTES', what: 'Session.putBytes');
      });

      test('Session.deleteResource refuses blockFirst', () {
        expectRefused('DELETE', what: 'Session.deleteResource');
      });

      test('Session.declarePublisher refuses blockFirst, and declares '
          'nothing', () {
        expectRefused('DECLPUB', what: 'Session.declarePublisher');
        expect(
          row('DECLPUB_HANDLE')['produced'],
          isFalse,
          reason:
              'a refused declaration produced a Publisher, so a failed '
              'call left the caller owning something to close',
        );
      });

      test('Session.get refuses blockFirst synchronously', () {
        // ⛔ SYNCHRONOUSLY IS THE POINT. `get` returns its Stream without an
        // await, so the probe drives it without one: a guard sited after the
        // ReceivePort at session.dart:1743 would still throw -- with a port
        // already open, pinning the isolate. The exit-code cell in the next
        // slice is the other half of that claim.
        expectRefused('GET', what: 'Session.get');
      });

      test('Session.pullGet refuses blockFirst', () {
        expectRefused('PULLGET', what: 'Session.pullGet');
      });

      test(
        'Session.declareQuerier refuses blockFirst, and declares nothing',
        () {
          expectRefused('DECLQUERIER', what: 'Session.declareQuerier');
          expect(
            row('DECLQUERIER_HANDLE')['produced'],
            isFalse,
            reason:
                'a refused declaration produced a Querier, so a failed call '
                'left the caller owning something to close',
          );
        },
      );

      test('the congestion guard runs AHEAD of the timeout and capacity '
          'guards', () {
        // ⛔ A STATED ORDER, NOT AN INCIDENTAL ONE. Both alternatives throw
        // ArgumentError, so a cell asserting only the type would pass either
        // way; the discriminator is WHICH argument is named. Of the three
        // faults a caller can trip at once this is the only one no change to
        // the call's other arguments can fix -- a zero timeout and a negative
        // capacity are both expressible correctly by choosing another number.
        final getFirst = row('ORDER_GET');
        expect(getFirst['threw'], isTrue);
        expect(
          getFirst['name'],
          'congestionControl',
          reason:
              'get(timeout: zero, congestionControl: blockFirst) reported '
              '${getFirst['name']} -- the congestion guard is not first',
        );

        final pullFirst = row('ORDER_PULLGET');
        expect(pullFirst['threw'], isTrue);
        expect(
          pullFirst['name'],
          'congestionControl',
          reason:
              'pullGet(capacity: -1, timeout: zero, congestionControl: '
              'blockFirst) reported ${pullFirst['name']} -- the stated order '
              'is congestion, then capacity, then timeout',
        );
      });

      test('the seven marshal expressions are unchanged, and the wire value '
          'at three of them is unobservable', () {
        // ⛔ THE REASON IS PART OF THE DELIVERABLE. At `get`, `pullGet` and
        // `declareQuerier` canon exposes NO request-side QoS accessor --
        // measured over both build-generated headers, zero hits for
        // congestion, priority or express on `z_query_*`, against a live
        // `z_sample_congestion_control`. Nothing a Dart receiver holds can
        // report what those three put on the wire.
        //
        // ⛔ So A2 is discharged STRUCTURALLY there, and NO round-trip pair
        // may be manufactured for them: a cell that appeared to observe one
        // could not go red.
        const marshal = 'congestionControl?.value ?? -1';
        var total = 0;
        for (final path in const [
          'lib/src/session.dart',
          'lib/src/publisher.dart',
          'lib/src/querier.dart',
        ]) {
          total += marshal.allMatches(code(path)).length;
        }
        expect(
          total,
          7,
          reason:
              'the send-side marshal moved: this unit adds a refusal '
              'ahead of these expressions and changes none of them',
        );
      });

      test('the guard refuses ONE value at each of the four push entries', () {
        // The positive control. Without it, a guard that threw on every
        // congestion control would pass every refusal cell above.
        expectControlsPass('PUT_CTRL', what: 'Session.put');
        expectControlsPass('PUTBYTES_CTRL', what: 'Session.putBytes');
        expectControlsPass('DELETE_CTRL', what: 'Session.deleteResource');
        expectControlsPass('DECLPUB_CTRL', what: 'Session.declarePublisher');
      });

      test(
        'the guard refuses ONE value at each of the three request entries',
        () {
          expectControlsPass('GET_CTRL', what: 'Session.get');
          expectControlsPass('PULLGET_CTRL', what: 'Session.pullGet');
          expectControlsPass(
            'DECLQUERIER_CTRL',
            what: 'Session.declareQuerier',
          );
        },
      );

      // --- A7: a refused call does nothing --------------------------------

      test('a refused call leaves the caller payload unconsumed', () {
        // ⛔ THE SECOND CALL IS THE ASSERTION. `markConsumed()` runs after the
        // native call on every path, so a guard sited at the marshal would
        // ALSO leave the payload intact -- but only because the throw happens
        // to precede the move. This cell pins the outcome; the siting cell
        // below pins that it is by design rather than by accident.
        final reuse = row('REUSE_PAYLOAD');
        final first = reuse['first']! as Map<String, Object?>;
        final second = reuse['second']! as Map<String, Object?>;
        expect(first['threw'], isTrue);
        expect(first['name'], 'congestionControl');
        expect(
          second['threw'],
          isFalse,
          reason:
              'the refused putBytes consumed the payload anyway: the '
              'second call reported ${second['message']}',
        );
      });

      test('a refused call leaves the caller attachment unconsumed', () {
        final reuse = row('REUSE_ATTACHMENT');
        final first = reuse['first']! as Map<String, Object?>;
        final second = reuse['second']! as Map<String, Object?>;
        expect(first['threw'], isTrue);
        expect(first['name'], 'congestionControl');
        expect(
          second['threw'],
          isFalse,
          reason:
              'the refused put consumed the attachment anyway: the second '
              'call reported ${second['message']}',
        );
      });

      test('the refusal precedes even the closed-session check, and only for '
          'the refused value', () {
        // ⛔ A SECOND BREAKING CHANGE, ASSERTED HERE AND ANNOUNCED IN THE
        // CHANGELOG. `putBytes` is the only one of the seven with an explicit
        // `_ensureOpen()` as its first statement, and the guard now precedes
        // it: a closed session carrying blockFirst reports the ARGUMENT fault
        // rather than StateError. The ground is diagnosis -- a closed session
        // is discoverable from any other call on it, a build-configuration
        // fault is discoverable from nothing else in the program.
        final refused = row('CLOSED_BLOCKFIRST');
        expect(refused['threw'], isTrue);
        expect(refused['type'], 'ArgumentError');
        expect(refused['name'], 'congestionControl');

        // ⛔ AND THE CONTROL, which is what keeps this from being a general
        // reordering of the closed-session check: the same call carrying a
        // representable value still reports the lifecycle fault.
        final stillStateError = row('CLOSED_DROP');
        expect(stillStateError['threw'], isTrue);
        expect(
          stillStateError['type'],
          'StateError',
          reason:
              'a closed session with congestionControl: drop reported '
              '${stillStateError['type']} -- the change was supposed to be '
              'scoped to the refused value',
        );
        expect(
          '${stillStateError['message']}',
          contains('Session has been closed'),
        );
      });

      test('a refused query leaves no port pinning the isolate', () {
        // The behavioural half of "synchronously, before the ReceivePort".
        // The probe calls no `exit()`: if a refused `get` or `pullGet` had
        // opened its port first, this child would still be alive and would
        // have had to be killed.
        final failure = armingFailure;
        if (failure != null) fail(failure);
        expect(
          result.timedOut,
          isFalse,
          reason:
              'the probe drove refused get/pullGet calls, printed every '
              'row and then had to be KILLED — something it refused left a '
              'port open.\n$output',
        );
        expect(result.exitCode, 0, reason: output);
      });

      test('the guard is sited ahead of every allocation and every native '
          'call, at all seven entry points', () {
        // ⛔ THE ONLY INSTRUMENT THIS BINDING HAS FOR THE LEAK CLAUSE, and
        // this cell says so rather than implying otherwise. The blocks a
        // marshal-sited guard would strand -- `publisher.dart:57` and
        // `querier.dart:78` calloc their entity handle BEFORE the marshal,
        // and `Querier.declare` has no `try` at all -- are exactly the ones
        // Dart no longer holds, so the discipline's named leak instrument
        // (distinct block addresses over N cycles) cannot reach them.
        // ⛔ NO CELL IN THIS FILE CLAIMS TO MEASURE A LEAK.
        const forbiddenBefore = <String>[
          '_ensureOpen(',
          '_rejectSentinelTimeout(',
          '_withKeyExprArg(',
          'allocLengthCarriedUtf8(',
          'ZBytes.fromString(',
          'calloc',
          'ReceivePort(',
        ];
        final source = code('lib/src/session.dart');
        for (final signature in sevenEntryPoints) {
          final at = source.indexOf(signature);
          expect(at, greaterThanOrEqualTo(0), reason: '$signature not found');
          expect(
            source.indexOf(signature, at + 1),
            -1,
            reason:
                '$signature is not unique in session.dart, so the window '
                'below is not the one it names',
          );
          final guard = source.indexOf(
            'requireCongestionControlSupported(',
            at,
          );
          expect(
            guard,
            greaterThanOrEqualTo(0),
            reason: '$signature does not call the guard at all',
          );
          final preamble = source.substring(at, guard);
          for (final marker in forbiddenBefore) {
            expect(
              preamble,
              isNot(contains(marker)),
              reason:
                  'in $signature, $marker runs BEFORE the guard — a '
                  'refused call would reach it having already allocated, '
                  'validated or opened something',
            );
          }
        }
      });

      // --- A3: the decoder is untouched, on both natives ------------------

      test('fromWire(2) still answers blockFirst on the stable native', () {
        // ⛔ THE CHEAPEST AVAILABLE RED for "the guard leaked into the decode
        // seam on the one variant where it fires". The probe evaluates it
        // BEFORE opening any session.
        //
        // ⚠️ NOT the same claim as observing wire 2 arriving FROM a peer on a
        // stable receiver — canon never emits it there (a stable receiver
        // returns Drop for the block-first flag), so that cell is not
        // writable and none is written. This is a DIRECT call.
        final decoded = row('FROMWIRE2');
        expect(decoded['isBlockFirst'], isTrue);
        expect(decoded['name'], 'blockFirst');
      });

      test('the guard is not reachable from the decode path', () {
        final source = code('lib/src/congestion_control.dart');
        final at = source.indexOf('static CongestionControl fromWire(');
        expect(at, greaterThanOrEqualTo(0));
        // ⛔ THE WINDOW MUST END AT THE ENUM'S CLOSING BRACE, not at
        // end-of-file. The guard is a top-level function declared BELOW the
        // enum, so a window running to EOF contains it and this cell passes
        // on nothing — which is exactly what the first cut did, and it went
        // red on its own text. `\n}` at column 0 is the enum's closer;
        // `fromWire` is its last member.
        final closer = source.indexOf('\n}', at);
        expect(
          closer,
          greaterThan(at),
          reason:
              'no enum-closing brace after fromWire, so the window below '
              'is not the decode path',
        );
        final body = source.substring(at, closer);
        expect(
          body,
          isNot(contains('requireCongestionControlSupported')),
          reason:
              'fromWire calls the guard, so a decode would consult the '
              "loaded native's feature bits",
        );
        expect(
          body,
          isNot(contains('ZenohFeatures')),
          reason: 'fromWire reads the feature bits directly',
        );
      });

      test('blockFirst is still a member of the stable-door enum', () {
        // ⛔ THE VALUE IS NOT REMOVED AND MUST NOT BE. A stable-door `Sample`
        // still has to represent wire 2 when the loaded native IS the
        // unstable one; this unit refuses it on the SEND side only.
        expect(CongestionControl.values, hasLength(3));
        expect(
          CongestionControl.values,
          contains(CongestionControl.blockFirst),
        );
        expect(CongestionControl.blockFirst.value, 2);
        expect(CongestionControl.fromWire(2), CongestionControl.blockFirst);
      });

      // --- A4 / A5 / R-9: the text stops asserting silent substitution -----

      test("blockFirst's dartdoc states the refusal, not a substitution", () {
        final doc = dartdocAbove(
          'lib/src/congestion_control.dart',
          'blockFirst(2);',
        );
        expect(
          doc,
          isNot(contains('silently substituted')),
          reason:
              'the shipped text still asserts the mechanism this unit '
              'measured to be wrong',
        );
        expect(doc, contains('refused'));
        expect(doc, contains('z_feature_unstable_api'));
        // The mechanism the refusal prevents, named at source rather than
        // described as an outcome.
        expect(doc, contains('#[repr(c)]'));
        expect(doc, contains('undefined behaviour'));
        // Both remedies, matching the refusal message.
        expect(doc, contains('user_defines'));
      });

      test("the shim's domain comment no longer asserts a range that is "
          'false on stable', () {
        // Read as `../src/zenoh_dart.c`: the C shim sits above the package
        // root, and this is the only cell in the suite that reads it.
        final shim = File('../src/zenoh_dart.c').readAsStringSync();
        expect(
          shim,
          isNot(contains('congestion 0..2')),
          reason:
              'the shim still states a congestion domain that is false '
              'on a stable build, at the one site that states a domain',
        );
        expect(shim, contains('congestion 0..1'));
        expect(shim, contains('Z_FEATURE_UNSTABLE_API'));
      });

      test('features.dart no longer claims the partition is compile-time '
          'only', () {
        final doc = dartdocAbove(
          'lib/src/unstable/features.dart',
          'abstract final class ZenohFeatures',
        );
        expect(
          doc,
          isNot(contains('this covers only the orthogonal runtime case')),
          reason:
              'the dartdoc still says this file covers ONE runtime case; '
              'a stable-door member now gates on the same predicate',
        );
        expect(doc, contains('congestioncontrol.blockfirst'));
        expect(doc, contains('orthogonal'));
      });

      // --- Edge cases -----------------------------------------------------

      test('the correction did not travel to the reply path', () {
        // reply_options_test.dart:295 pins this. Asserted here too because
        // this unit is what could break it, and a red should name the unit
        // that caused it.
        expect(
          code('lib/src/query.dart'),
          isNot(contains('congestionControl')),
          reason:
              'a congestion-control edit reached query.dart, where canon '
              'deprecates and ignores the field',
        );
      });

      test('a refused declaration returns no entity to release', () {
        // No handle means no close/dispose obligation created by a failed
        // call. Both are asserted at their own refusal cells too; gathered
        // here because A7 is the criterion that owns the claim.
        expect(row('DECLPUB_HANDLE')['produced'], isFalse);
        expect(row('DECLQUERIER_HANDLE')['produced'], isFalse);
      });

      test('the pre-existing domain guards are unmoved for a caller who trips '
          'only one', () {
        // D1c reorders nothing for anyone not passing blockFirst.
        final timeout = row('GUARD_GET_TIMEOUT');
        expect(timeout['threw'], isTrue);
        expect(timeout['name'], 'timeout');

        final capacity = row('GUARD_PULLGET_CAPACITY');
        expect(capacity['threw'], isTrue);
        expect(capacity['name'], 'capacity');
      });

      test('a value that is not blockFirst consults no feature bits, so the '
          'decode-seam cells stay native-free', () async {
        // ⛔ A WHOLE-PROCESS PROPERTY, so it needs its own process: this one
        // loaded a native long before the first cell ran.
        // `resolvedLibraryPath` is null until `ensureInitialized()`, and
        // reading the feature bits is what would call it.
        final probe = await runProbe('blockfirst_native_free_probe.dart');
        final out = probe.stdout;
        expect(
          out,
          contains('PROBE_DONE'),
          reason: '$out${probe.stderr}',
        );
        expect(out, contains('VALUE=2'));
        expect(out, contains('FROMWIRE2=blockFirst'));
        expect(out, contains('GUARD_NULL=ok'));
        expect(out, contains('GUARD_BLOCK=ok'));
        expect(
          out,
          contains('LOADED=null'),
          reason:
              'touching .value, fromWire and the guard with a '
              'non-blockFirst value LOADED A NATIVE. enum_wire_value_test '
              'and wire_enum_decode_test run native-free today; the guard '
              'must short-circuit before it reads ZenohFeatures.\n$out',
        );
      });

      test("the door's export count did not move", () {
        // The guard rides the EXISTING export directive, not a new one, so
        // both pins stay green: finalizer_ownership_test.dart:1916 and
        // log_sink_test.dart:242 each assert 36.
        final door = File('lib/zenoh.dart').readAsLinesSync();
        final exports = door.where((l) => l.startsWith('export')).toList();
        expect(exports, hasLength(36));
        // ⛔ CONVERTED AT SEED [API] SLICE 2, NOT RETIRED. This half used to
        // require the literal `hide requireCongestionControlSupported` on
        // the congestion_control line. The door now ALLOW-LISTS, so the
        // guard is fenced by being absent from a `show` clause and there is
        // no `hide` text to match — but retiring the check outright would
        // lose a real one, because this file carries no census of its own
        // and nothing else here would notice the guard going public.
        //
        // ⭐ SO IT ASSERTS ABSENCE FROM THE DOOR'S NAMESPACE INSTEAD, which
        // is the property the text was standing in for, and which survives
        // a reformat, a re-order and a wrap. Read directive-wise: `[^;]`
        // spans a newline, so a wrapped clause is picked up whole.
        final shown = RegExp('show ([^;]+);')
            .allMatches(door.join('\n'))
            .expand((m) => m.group(1)!.split(','))
            .map((n) => n.trim())
            .toSet();
        expect(
          shown,
          isNot(contains('requireCongestionControlSupported')),
          reason:
              'the @internal guard is nameable by a consumer of the '
              'stable door, which is what the hide clause used to prevent',
        );
        expect(
          shown,
          contains('CongestionControl'),
          reason:
              'the enum the guard protects is gone from the door too, so '
              'the absence above passes for the wrong reason',
        );
      });
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  // ⛔ A SEPARATE GROUP, and it loads no probe. These are source assertions
  // over seven dartdoc blocks; coupling them to the child process would make
  // a prose regression unreadable behind an instrument failure.
  group("[CC] each entry point's contract names the refusal", () {
    test('all seven document it at their own declaration', () {
      // ADJACENCY, not a file-wide mention: a caller reads the entry point,
      // not the file.
      for (final signature in sevenEntryPoints) {
        final doc = dartdocAbove('lib/src/session.dart', signature);
        expect(
          doc,
          contains('argumenterror'),
          reason: '$signature does not name the exception type',
        );
        expect(
          doc,
          contains('blockfirst'),
          reason: '$signature does not name the refused value',
        );
        expect(
          doc,
          contains('z_feature_unstable_api'),
          reason: '$signature does not name the condition',
        );
      }
    });

    test('putBytes documents that the refusal precedes the closed-session '
        'check', () {
      // The ONE entry point of the seven whose observable behaviour changed.
      // The other six say nothing about it, because for them nothing did.
      final doc = dartdocAbove('lib/src/session.dart', 'void putBytes(');
      expect(doc, contains('before'));
      expect(doc, contains('stateerror'));
      expect(doc, contains('session-closed check'));
    });

    test('the existing send-options prose is not disturbed', () {
      // ⛔ SIX, NOT SEVEN, AND THE SEVENTH IS NAMED. `pullGet` carries no
      // "canon decides" sentence and names no default of its own at HEAD: it
      // delegates to [get] deliberately, saying it carries "its identical
      // option surface". The plan's cell read "each still states"; measured,
      // that is true of six. Asserting it of seven would have meant ADDING
      // prose this unit was not asked for, so the DELEGATION is pinned
      // instead -- which is the non-regression check that actually applies to
      // it. Recorded as a departure rather than absorbed.
      for (final signature in const [
        'void put(',
        'void putBytes(',
        'void deleteResource(',
        'Publisher declarePublisher(',
      ]) {
        final doc = dartdocAbove('lib/src/session.dart', signature);
        expect(doc, contains('canon decides'), reason: signature);
        expect(
          doc,
          contains('congestioncontrol.drop'),
          reason: "$signature stopped naming canon's own push default",
        );
      }
      for (final signature in const [
        'Querier declareQuerier(',
        'Stream<Reply> get(',
      ]) {
        final doc = dartdocAbove('lib/src/session.dart', signature);
        expect(doc, contains('canon decides'), reason: signature);
        expect(
          doc,
          contains('congestioncontrol.block'),
          reason: "$signature stopped naming canon's own request default",
        );
      }
      final pull = dartdocAbove(
        'lib/src/session.dart',
        'PullReplies pullGet(',
      );
      expect(
        pull,
        contains('identical option surface'),
        reason:
            'pullGet delegates its option semantics to [get]; that '
            'delegation stands in for the sentence the other six carry, and '
            'it must not be silently dropped',
      );
    });

    // --- Edge cases ---

    test('the advice does not tell a stable-door caller to import the '
        'unstable door', () {
      final prose = flattenedProse('lib/src/session.dart');
      expect(
        prose,
        isNot(contains('zenoh_unstable')),
        reason:
            'an entry point points a stable-door caller at a door they '
            'are not standing at; the remedies are another value, or the '
            'variant selection',
      );
    });

    test('the change is recorded as breaking, in BOTH of its consequences', () {
      // ⛔ THE SECOND CONSEQUENCE IS ASSERTED IN ONE CELL AND ANNOUNCED IN
      // THIS ONE. Neither may land alone: a behaviour change visible only
      // inside an edge-case cell is a behaviour change that ships
      // unannounced.
      // ⛔ SCOPED TO THIS UNIT'S OWN TWO BULLETS, not to the section. The
      // `### Breaking` block already carries other units' entries, and a
      // `contains` over the whole of it is satisfied by any of them -- which
      // is not an assertion about this change at all. The first cut did
      // exactly that and was caught by its own greenfield clause, which read
      // "migration" out of a neighbouring entry.
      const refusalBullet = '- **`CongestionControl.blockFirst` is now REFUSED';
      const orderingBullet = '- **`Session.putBytes` on a CLOSED session';
      final changelog = File('../CHANGELOG.md').readAsStringSync();
      // The section that announced this unit, found above the last release
      // before it (0.19.0). A release renames `## Unreleased`, so the cell
      // cannot find it by that name — see helpers/changelog_section.dart.
      final announcing = changelogSectionAnnouncing(
        changelog,
        refusalBullet,
        anchor: '0.19.0',
      );
      expect(
        announcing,
        isNotNull,
        reason: 'no entry announces the refusal at all',
      );
      final section = announcing!;
      final from = section.indexOf(refusalBullet);
      expect(
        from,
        greaterThanOrEqualTo(0),
        reason: 'no entry announces the refusal at all',
      );
      final orderingAt = section.indexOf(orderingBullet, from);
      expect(
        orderingAt,
        greaterThan(from),
        reason:
            'no entry announces that the refusal precedes the '
            'closed-session check — the second breaking change, which one '
            'cell in this file asserts and only this entry announces',
      );
      final nextBullet = section.indexOf('\n- **', orderingAt);
      final ours = section.substring(
        from,
        nextBullet < 0 ? section.length : nextBullet,
      );

      // Both bullets are inside `### Breaking`, not merely inside the section.
      final breakingAt = section.indexOf('### Breaking');
      expect(breakingAt, greaterThanOrEqualTo(0));
      final nextHeading = section.indexOf('\n### ', breakingAt + 1);
      expect(
        from,
        greaterThan(breakingAt),
        reason: 'the entry is not under ### Breaking',
      );
      if (nextHeading >= 0) {
        expect(
          orderingAt,
          lessThan(nextHeading),
          reason: 'the ordering entry escaped the ### Breaking section',
        );
      }

      // (a) the refusal itself.
      expect(ours, contains('Z_FEATURE_UNSTABLE_API'));
      expect(ours, contains('ArgumentError'));
      expect(
        ours,
        contains('seven'),
        reason: 'the entry does not say how many entry points it changes',
      );
      // The mechanism, stated as what it is rather than as a substitution.
      expect(ours, contains('undefined'));
      expect(
        ours,
        isNot(contains('silently substituted')),
        reason: 'the changelog repeats the claim this unit corrected',
      );
      // Both remedies.
      expect(ours, contains('CongestionControl.drop'));
      expect(ours, contains('user_defines'));

      // (b) the ordering against the closed-session check.
      expect(ours, contains('StateError'));
      expect(ours, contains('session-closed check'));

      // ⛔ GREENFIELD: migration cost is not a pricing input in this package
      // and must not be weighed in the entry.
      for (final forbidden in const ['migration', 'backward compat']) {
        expect(
          ours.toLowerCase(),
          isNot(contains(forbidden)),
          reason:
              'the entry prices migration cost, which is not a tradeoff '
              'here',
        );
      }
    });

    test('the prose cells calibrated on this file still hold', () {
      // undecodable_payload_test.dart:336-362 pins these two needles in
      // session.dart. Asserted here too because this unit's dartdoc pass is
      // what could remove them.
      final prose = flattenedProse('lib/src/session.dart');
      expect(prose, contains('never as empty or absent data'));
      expect(prose, contains('keeps running'));
    });
  });
}
