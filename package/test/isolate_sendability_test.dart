// ⛔ FILE-LEVEL TIMEOUT ABOVE THE HARNESS DEADLINE — same reason as
// `finalizer_ownership_test.dart`: the bounded children here carry a 60 s
// OS-level deadline, and `package:test`'s 30 s default would fire first and
// throw away the harness's diagnosis.
@Timeout(Duration(minutes: 3))
library;

// Seed [OWN], slices 1 and 2 — the unsendable marker, and the double-close
// sequence it closes.
//
// WHAT THIS FILE ASSERTS, AND WHY THE ASSERTION IS ON THE *REASON*
//
// Every public wrapper in this package holds its native object as a bare
// `Pointer` (or, for `Query`, a bare `int`) plus a private `bool`. Dart's
// isolate boundary copies such an object freely: the copy gets the SAME
// address and its OWN, fresh `_closed = false`. Two Dart objects then believe
// they own one native handle, and the second release is a use-after-free —
// reproduced three times at CI's own hand before the marker landed, at
// `development/research/probes-ci-own-20260828/pre-fix-double-close.txt`.
//
// ⚠️ Six of the twenty classes were ALREADY rejected before this seed, and
// that is the trap this file is built around. They hold a non-nullable
// `ReceivePort`, which is on the SDK's own unsendable list — so they were
// protected by ACCIDENT, by a field nobody chose for that purpose. A cell that
// asserted only "some exception was thrown" would have passed on the unfixed
// tree for those six, and three more classes (`Publisher`, `Querier`,
// `AdvancedPublisher`) are sendable or not DEPENDING ON A CALLER'S BOOLEAN.
//
// So the assertion is on the VM's stated reason, which is measurable. The
// rejection message names the class it refused:
//
//   Illegal argument in isolate message: object is unsendable -
//   Library:'file:///…/publisher.dart' Class: Publisher (see restrictions …)
//
// and for an accidental rejection it names the FIELD's class instead, with the
// holder demoted to a trailing provenance line:
//
//   … object is unsendable - Library:'dart:isolate'
//   Class: _ReceivePortImpl@1026248 (see restrictions …)
//    <- rp in Instance of 'Subscriber' (from file:///…/subscriber.dart)
//
// The migration from the second shape to the first IS the whole difference
// between protected-by-accident and protected-by-design (seed criterion A1).
//
// ⚠️ THE MATCH IS A WORD-BOUNDED REGEXP, NOT `contains`. `Class: Query` is a
// prefix of `Class: Queryable`, so a bare substring test would let a
// `Queryable` satisfy a `Query` cell. `\b` after the name separates them and
// still matches the `@1026248` suffix form, which is what the negative
// assertion needs.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/bounded_subprocess.dart';

// ---------------------------------------------------------------------------
// The instrument
// ---------------------------------------------------------------------------

/// What one `SendPort.send` attempt produced.
class _SendVerdict {
  _SendVerdict.rejected(this.message) : sendable = false, arrivedType = null;
  _SendVerdict.sendable(this.arrivedType) : sendable = true, message = null;

  /// True when the VM carried the object across; the defect this seed closes.
  final bool sendable;

  /// The refusal text, when refused.
  final String? message;

  /// The runtime type that arrived on the far side, when carried.
  final String? arrivedType;

  @override
  String toString() =>
      sendable ? 'SENDABLE (arrived as $arrivedType)' : 'REJECTED: $message';
}

/// Sends [o] across a local `ReceivePort` and reports what happened.
///
/// Never throws: a refusal is a result, not an error, because the whole point
/// of the table below is that some rows refuse and some (before the fix) do
/// not.
Future<_SendVerdict> _trySend(Object o) async {
  final rp = ReceivePort();
  try {
    rp.sendPort.send(o);
    // The VM's refusal for an unsendable object IS an `ArgumentError` (measured
    // on this SDK, all shapes). Catching it is the whole instrument, not a
    // swallowed programming error, so the lint is overridden with its reason
    // rather than worked around by catching `Object` and re-testing the type.
    // ignore: avoid_catching_errors
  } on ArgumentError catch (e) {
    rp.close();
    return _SendVerdict.rejected(e.toString());
  }
  final got = await rp.first;
  rp.close();
  return _SendVerdict.sendable('${got.runtimeType}');
}

/// Matches `Class: <name>` on a word boundary — see the header note.
RegExp _namesClass(String className) =>
    RegExp('Class: ${RegExp.escape(className)}\\b');

/// The A1 assertion, in one place: refused, refused FOR THIS CLASS, and not
/// refused for the incidental-port reason.
void _expectRejectedNaming(_SendVerdict v, String className) {
  expect(
    v.sendable,
    isFalse,
    reason:
        '$className crossed an isolate boundary. The copy shares this '
        "object's native address and gets its own fresh `_closed` flag, so "
        'the second release is a use-after-free. Verdict: $v',
  );
  expect(
    v.message,
    matches(_namesClass(className)),
    reason:
        'the VM refused, but not because $className is unsendable. The '
        'message must name `Class: $className` — an accidental rejection '
        'names the FIELD (`Class: _ReceivePortImpl`) and would pass a '
        'weaker cell unchanged on the unfixed tree. Message: ${v.message}',
  );
  expect(
    v.message,
    isNot(contains('_ReceivePortImpl')),
    reason:
        '$className is still protected by its incidental ReceivePort field '
        'rather than by the marker — this is exactly the migration A1 '
        'requires. Message: ${v.message}',
  );
}

Config _quiet() => Config()
  ..insertJson5('scouting/multicast/enabled', 'false')
  ..insertJson5('scouting/gossip/enabled', 'false');

/// Top-level so `Isolate.spawn` can reference it (a closure is not sendable
/// as an entry point).
void _childEntry(Object message) {
  if (message is List && message.length == 2 && message[1] is SendPort) {
    (message[1] as SendPort).send('CHILD_RAN');
  }
}

void main() {
  // -------------------------------------------------------------------------
  // Slice 1 — the marker, on all twenty
  // -------------------------------------------------------------------------
  group('isolate sendability — the twenty census classes', () {
    late Session session;

    setUpAll(() async {
      // ONE session, multicast and gossip off. Two such sessions cannot
      // discover each other (the seed's own measured counter-case), and the
      // `Query` cell below needs a real query round-trip, so one session is
      // both sufficient and necessary here.
      session = await Session.open(config: _quiet());
    });

    tearDownAll(() {
      session.close();
    });

    // --- Test 1: every census class, rejected for the right reason ---------

    test('Config is rejected naming its own class', () async {
      _expectRejectedNaming(await _trySend(_quiet()), 'Config');
    });

    test('KeyExpr is rejected naming its own class', () async {
      _expectRejectedNaming(
        await _trySend(KeyExpr('demo/own/send')),
        'KeyExpr',
      );
    });

    test('ZBytes is rejected naming its own class', () async {
      _expectRejectedNaming(await _trySend(ZBytes.fromString('x')), 'ZBytes');
    });

    test('ZBytesWriter is rejected naming its own class', () async {
      _expectRejectedNaming(await _trySend(ZBytesWriter()), 'ZBytesWriter');
    });

    test('ZSerializer is rejected naming its own class', () async {
      _expectRejectedNaming(await _trySend(ZSerializer()), 'ZSerializer');
    });

    test('ZDeserializer is rejected naming its own class', () async {
      _expectRejectedNaming(
        await _trySend(ZDeserializer(ZBytes.fromString('x'))),
        'ZDeserializer',
      );
    });

    test('Session is rejected naming its own class', () async {
      _expectRejectedNaming(await _trySend(session), 'Session');
    });

    test('LivelinessToken is rejected naming its own class', () async {
      final token = session.declareLivelinessToken('demo/own/send/lt');
      addTearDown(token.close);
      _expectRejectedNaming(await _trySend(token), 'LivelinessToken');
    });

    test('Query is rejected naming its own class', () async {
      // A RECEIVED query — the object the shim's clone travels into, and the
      // one census row that holds a bare `int` rather than a `Pointer`.
      final qa = session.declareQueryable('demo/own/send/q');
      addTearDown(qa.close);
      final firstQuery = qa.stream.first;
      session.get('demo/own/send/q').listen((_) {}, onError: (Object _) {});
      final query = await firstQuery.timeout(const Duration(seconds: 5));
      addTearDown(query.dispose);
      _expectRejectedNaming(await _trySend(query), 'Query');
    });

    // --- Test 3: the six accidental rejections have MIGRATED ---------------
    //
    // These are the rows that pass a weak cell on the unfixed tree. The
    // `isNot(contains('_ReceivePortImpl'))` leg inside `_expectRejectedNaming`
    // is what makes them RED before the marker lands.

    test('Subscriber has migrated off the incidental-port rejection', () async {
      final sub = session.declareSubscriber('demo/own/send/s');
      addTearDown(sub.close);
      _expectRejectedNaming(await _trySend(sub), 'Subscriber');
    });

    test('Queryable has migrated off the incidental-port rejection', () async {
      final qa = session.declareQueryable('demo/own/send/qa');
      addTearDown(qa.close);
      _expectRejectedNaming(await _trySend(qa), 'Queryable');
    });

    test(
      'PullSubscriber has migrated off the incidental-port rejection',
      () async {
        final ps = session.declarePullSubscriber(
          'demo/own/send/ps',
          capacity: 4,
        );
        addTearDown(ps.close);
        _expectRejectedNaming(await _trySend(ps), 'PullSubscriber');
      },
    );

    test(
      'PullQueryable has migrated off the incidental-port rejection',
      () async {
        final pq = session.declarePullQueryable(
          'demo/own/send/pq',
          kind: ChannelKind.ring,
          capacity: 4,
        );
        addTearDown(pq.close);
        _expectRejectedNaming(await _trySend(pq), 'PullQueryable');
      },
    );

    test(
      'PullReplies has migrated off the incidental-port rejection',
      () async {
        final pr = session.pullLivelinessGet(
          'demo/own/send/**',
          kind: ChannelKind.ring,
          capacity: 4,
        );
        addTearDown(pr.dispose);
        _expectRejectedNaming(await _trySend(pr), 'PullReplies');
      },
    );

    // --- Test 2: the conditional classes, in BOTH configurations -----------
    //
    // ⭐ The sharpest fact in the census: the SAME class is sendable or not
    // depending on `enableMatchingListener`, a caller-supplied boolean that
    // defaults to false. No static reading of the class tells you whether it
    // is protected. The `ml:off` half of each pair is SENDABLE on the unfixed
    // tree; the `ml:ON` half is rejected as `_ReceivePortImpl`. Both halves
    // must end up naming the wrapper.

    test(
      'Publisher is rejected in BOTH matching-listener configurations',
      () async {
        final off = session.declarePublisher('demo/own/send/p1');
        addTearDown(off.close);
        final on = session.declarePublisher(
          'demo/own/send/p2',
          enableMatchingListener: true,
        );
        addTearDown(on.close);
        _expectRejectedNaming(await _trySend(off), 'Publisher');
        _expectRejectedNaming(await _trySend(on), 'Publisher');
      },
    );

    test(
      'Querier is rejected in BOTH matching-listener configurations',
      () async {
        final off = session.declareQuerier('demo/own/send/q1');
        addTearDown(off.close);
        final on = session.declareQuerier(
          'demo/own/send/q2',
          enableMatchingListener: true,
        );
        addTearDown(on.close);
        _expectRejectedNaming(await _trySend(off), 'Querier');
        _expectRejectedNaming(await _trySend(on), 'Querier');
      },
    );

    // --- Test 4: the spawn path, with its own positive control -------------

    test(
      'Isolate.spawn refuses a Session at the spawn call, and no child runs',
      () async {
        final rp = ReceivePort();
        addTearDown(rp.close);
        final arrivals = <Object?>[];
        rp.listen(arrivals.add);

        Object? thrown;
        try {
          await Isolate.spawn(_childEntry, <Object>[session, rp.sendPort]);
          // Same override, same reason as `_trySend` above: the refusal under
          // test is an Error subtype by the SDK's own contract.
          // ignore: avoid_catching_errors
        } on ArgumentError catch (e) {
          thrown = e;
        }

        expect(
          thrown,
          isA<ArgumentError>(),
          reason: 'Isolate.spawn carried a Session into a child isolate',
        );
        expect(thrown.toString(), matches(_namesClass('Session')));

        // No child output, because no child isolate ever started.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(
          arrivals,
          isEmpty,
          reason: 'a child isolate ran despite the spawn being refused',
        );

        // ⛔ POSITIVE CONTROL. Without it the `isEmpty` above is vacuous: it
        // would read identically if `Isolate.spawn` never delivered anything in
        // this harness for an unrelated reason. A sendable payload must arrive.
        final control = ReceivePort();
        addTearDown(control.close);
        final iso = await Isolate.spawn(
          _childEntry,
          <Object>['a plain string', control.sendPort],
        );
        addTearDown(() => iso.kill(priority: Isolate.immediate));
        expect(
          await control.first.timeout(const Duration(seconds: 5)),
          'CHILD_RAN',
          reason:
              'the control spawn did not deliver either — the emptiness above '
              'proves nothing about the refusal',
        );
      },
    );

    // --- Edge cases --------------------------------------------------------

    test('a value type holding no native handle is still sendable', () async {
      // The blast radius is exactly the census: the marker went on the twenty
      // handle-holders and on nothing else. If a value type has become
      // unsendable, the edit was applied too widely.
      final zid = session.zid;
      final ts = Timestamp.fromRaw(Uint8List(24));
      final sample = Sample(
        keyExpr: 'demo/own/send/v',
        payload: 'v',
        payloadBytes: Uint8List.fromList(<int>[118]),
        kind: SampleKind.put,
      );
      final hello = Hello(
        zid: zid,
        whatami: WhatAmI.peer,
        locators: const <String>['tcp/127.0.0.1:7447'],
      );
      final egid = EntityGlobalId(zid, 7);

      for (final MapEntry(key: label, value: v) in <String, Object>{
        'ZenohId': zid,
        'Timestamp': ts,
        'Sample': sample,
        'Hello': hello,
        'EntityGlobalId': egid,
      }.entries) {
        final verdict = await _trySend(v);
        expect(
          verdict.sendable,
          isTrue,
          reason:
              '$label is a value type with no native handle and must still '
              'cross. Verdict: $verdict',
        );
      }
    });

    test(
      'a wrapper nested inside a sendable container is still refused',
      () async {
        // The shape a real consumer hits: "I sent a result object that happens
        // to hold a session." The marker is not defeated by nesting, and the
        // message still names the wrapper rather than the container.
        final ke = KeyExpr('demo/own/send/nested');

        for (final container in <Object>[
          <Object>[ke],
          <String, Object>{'k': ke},
          (a: 1, b: ke),
        ]) {
          final verdict = await _trySend(container);
          expect(
            verdict.sendable,
            isFalse,
            reason:
                'a ${container.runtimeType} holding a live KeyExpr crossed the '
                'boundary. Verdict: $verdict',
          );
          expect(
            verdict.message,
            matches(_namesClass('KeyExpr')),
            reason:
                'the container was refused, but the message does not name the '
                'wrapper inside it. Message: ${verdict.message}',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // The unstable-tier census rows
  // -------------------------------------------------------------------------
  group(
    'isolate sendability — the advanced pair',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late Session session;

      setUpAll(() async {
        session = await Session.open(
          config: _quiet()..insertJson5('timestamping/enabled', 'true'),
        );
      });

      tearDownAll(() {
        session.close();
      });

      test(
        'AdvancedPublisher is rejected in BOTH matching-listener '
        'configurations',
        () async {
          final off = session.declareAdvancedPublisher('demo/own/send/ap1');
          addTearDown(off.close);
          final on = session.declareAdvancedPublisher(
            'demo/own/send/ap2',
            options: const AdvancedPublisherOptions(
              enableMatchingListener: true,
            ),
          );
          addTearDown(on.close);
          _expectRejectedNaming(await _trySend(off), 'AdvancedPublisher');
          _expectRejectedNaming(await _trySend(on), 'AdvancedPublisher');
        },
      );

      test(
        'AdvancedSubscriber has migrated off the incidental-port rejection',
        () async {
          final sub = session.declareAdvancedSubscriber('demo/own/send/as');
          addTearDown(sub.close);
          _expectRejectedNaming(await _trySend(sub), 'AdvancedSubscriber');
        },
      );
    },
  );

  group(
    'isolate sendability — the shared-memory pair',
    skip: ZenohFeatures.hasSharedMemory
        ? false
        : 'requires the unstable variant (shared memory)',
    () {
      test('ShmProvider is rejected naming its own class', () async {
        final provider = ShmProvider(size: 65536);
        addTearDown(provider.close);
        _expectRejectedNaming(await _trySend(provider), 'ShmProvider');
      });

      test('ShmMutBuffer is rejected naming its own class', () async {
        final provider = ShmProvider(size: 65536);
        addTearDown(provider.close);
        final r = provider.alloc(1024);
        expect(r, isA<AllocOk>(), reason: 'alloc did not return a buffer: $r');
        final buffer = (r as AllocOk).buffer;
        addTearDown(buffer.dispose);
        _expectRejectedNaming(await _trySend(buffer), 'ShmMutBuffer');
      });
    },
  );

  // -------------------------------------------------------------------------
  // Slice 2 — the double-close sequence no longer reaches native code
  // -------------------------------------------------------------------------
  //
  // ⛔ THE RED ARM OF THIS GROUP IS STRUCTURAL, NOT RUNNABLE, AND THAT IS
  // DELIBERATE. A calibration that "proves" these cells by crashing or hanging
  // the test process is not an assertion (the no-fake-red-leg rule). The RED
  // evidence is the PRE-FIX TRANSCRIPT captured in slice 1 —
  // `development/research/probes-ci-own-20260828/pre-fix-double-close.txt` —
  // three runs at HEAD before the marker landed.
  //
  // ⛔ AND NO CELL BELOW NAMES A SIGNAL, A STACK FRAME, OR AN EXIT CODE OTHER
  // THAN 0. Measured seven times, the pre-fix observable has three signatures
  // (Rust-panic-abort, silent hang, SIGSEGV in `z_close`). There is nothing
  // stable to name, so the assertions are on the POST-FIX contract only.
  group('the double-close sequence', () {
    const harness = 'test/helpers/double_close_harness.dart';

    test('the open-send-close-close program is refused at the spawn call '
        'and exits cleanly', () async {
      final outcome = await runBoundedHarness(
        harness,
        ['--arm', 'session'],
        deadline: const Duration(seconds: 60),
        label: 'double_close[session]',
      );

      expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
      expect(outcome.exitCode, 0, reason: outcome.diagnosis);
      expect(
        outcome.hasMarker('DC_DONE'),
        isTrue,
        reason: 'the harness did not reach its own end. ${outcome.diagnosis}',
      );
      expect(
        outcome.output,
        contains('DC_SPAWN_REJECTED='),
        reason:
            'the Session was carried into a spawned isolate. '
            '${outcome.diagnosis}',
      );
      expect(
        outcome.output,
        matches(_namesClass('Session')),
        reason:
            'the spawn was refused, but not because Session is unsendable. '
            '${outcome.diagnosis}',
      );
      expect(
        outcome.hasMarker('DC_CHILD_RAN'),
        isFalse,
        reason:
            'a child isolate ran despite the spawn being refused. '
            '${outcome.diagnosis}',
      );

      // ⛔ THE CALIBRATION FOR THE LINE ABOVE. `DC_CHILD_RAN` being absent is
      // an ABSENCE, and an absence is only evidence once the same harness has
      // been shown to produce the presence. The control arm differs in exactly
      // one thing — a plainly sendable payload — and its child must run.
      final control = await runBoundedHarness(
        harness,
        ['--arm', 'control'],
        deadline: const Duration(seconds: 60),
        label: 'double_close[control]',
      );
      expect(control.frozen, isFalse, reason: control.diagnosis);
      expect(control.exitCode, 0, reason: control.diagnosis);
      expect(
        control.hasMarker('DC_CHILD_RAN'),
        isTrue,
        reason:
            'the control arm did not run its child either, so the absence '
            'asserted above proves nothing about the refusal. '
            '${control.diagnosis}',
      );
      expect(
        control.output,
        isNot(contains('DC_SPAWN_REJECTED=')),
        reason:
            'the control payload was refused too — the arms do not differ in '
            'the one variable they are supposed to. ${control.diagnosis}',
      );
    });

    test('the run is bounded by the parent, not by a Dart timer', () async {
      // ⛔ A Dart-side `Timeout` CANNOT bound this class of failure: while the
      // mutator is inside native code the event loop never runs, so the timer
      // never fires and the serial suite freezes with no output. The bound is
      // the parent's OS-level deadline plus SIGKILL, applied by
      // `runBoundedHarness`, and this cell asserts the harness is nowhere near
      // it — a run that only just fits is a hang waiting for a slower host.
      const deadline = Duration(seconds: 60);
      final sw = Stopwatch()..start();
      final outcome = await runBoundedHarness(
        harness,
        ['--arm', 'session'],
        deadline: deadline,
        label: 'double_close[bounded]',
      );
      sw.stop();

      expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
      expect(
        sw.elapsed,
        lessThan(deadline * 0.5),
        reason:
            'the harness took ${sw.elapsed.inSeconds}s of a '
            '${deadline.inSeconds}s deadline — it is not comfortably inside '
            'its bound. ${outcome.diagnosis}',
      );
    });

    test(
      'the SHM arm is refused the same way',
      skip: ZenohFeatures.hasSharedMemory
          ? false
          : 'requires the unstable variant (shared memory)',
      () async {
        final outcome = await runBoundedHarness(
          harness,
          ['--arm', 'shm'],
          deadline: const Duration(seconds: 60),
          label: 'double_close[shm]',
        );

        expect(outcome.frozen, isFalse, reason: outcome.diagnosis);
        expect(outcome.exitCode, 0, reason: outcome.diagnosis);
        expect(outcome.hasMarker('DC_DONE'), isTrue, reason: outcome.diagnosis);
        expect(
          outcome.output,
          matches(_namesClass('ShmProvider')),
          reason: outcome.diagnosis,
        );
        expect(
          outcome.hasMarker('DC_CHILD_RAN'),
          isFalse,
          reason: outcome.diagnosis,
        );

        // ⚠️ NO ASSERTION IS MADE ABOUT STDERR SILENCE HERE, deliberately:
        // upstream #814 means the SHM path can emit diagnostics on a healthy
        // run, and a cell requiring quiet stderr would go red on correct code.
      },
    );
  });

  // -------------------------------------------------------------------------
  // Slice 14 — the breaking inventory, RUN rather than reasoned
  // -------------------------------------------------------------------------
  //
  // ⛔ THE LOCATOR WAS RESOLVED, AND IT IS NOT A SCRIPT. `seed-10b:518-521` is
  // a POINTER — it says "run the recipe", and the recipe is seed #9's
  // criterion K (`seed-MICRO-session-identity.md:376-385`) plus the PR #91
  // precedent. A PROCEDURE, with two mandatory parts, not a command to
  // execute.
  //
  // CRITERION K, as it applies here: a CHANGELOG-shaped inventory in which
  // every new refusal of previously-accepted input is a NAMED Breaking entry,
  // and each entry carries (a) a callers measurement and (b) a recovery
  // recipe.
  //
  // ⚠️ THIS SLICE'S OBJECT IS THE MARKER'S REFUSAL SURFACE, AND NOTHING ELSE.
  // That is exact rather than convenient: A FINALIZER REFUSES NOTHING. It
  // releases memory a caller forgot and adds no new rejection of any
  // previously-accepted input, so slices 3–13 contribute ZERO entries to this
  // inventory.
  group('the breaking inventory', () {
    test('K(a) — the callers measurement, on SHIPPED surface', () {
      // ⚠️ THE PLAN ASKED FOR A GLOBAL ZERO ACROSS package/{lib,test,example}
      // AND THAT CANNOT HOLD — the same seed's test mandate requires A1/A2 to
      // "spawn a real isolate", so this unit ADDS isolate-spawning code to
      // package/test. An absence assertion whose scope includes the work that
      // creates the exceptions.
      //
      // What F-8 actually established, and what is asserted here: NO SHIPPED
      // PATH sends a wrapper across an isolate, so the exposure is
      // consumer-side only.
      int countIn(String dir, RegExp pattern) {
        var n = 0;
        for (final f in Directory(dir).listSync(recursive: true)) {
          if (f is! File || !f.path.endsWith('.dart')) continue;
          n += pattern.allMatches(f.readAsStringSync()).length;
        }
        return n;
      }

      final spawn = RegExp(r'Isolate\.spawn');
      final run = RegExp(r'Isolate\.run');
      final send = RegExp(r'sendPort\.send');

      for (final dir in const ['lib', 'example']) {
        expect(countIn(dir, spawn), 0, reason: '$dir uses Isolate.spawn');
        expect(countIn(dir, run), 0, reason: '$dir uses Isolate.run');
        expect(countIn(dir, send), 0, reason: '$dir uses sendPort.send');
      }

      // ⛔ POSITIVE CONTROL. Three zeros from a search that cannot see
      // anything would look identical. The same patterns MUST find the cells
      // this seed added.
      expect(
        countIn('test', spawn),
        greaterThan(0),
        reason:
            'the search found no Isolate.spawn even in this seed own cells, '
            'so the zeros above are a blind instrument rather than an absence',
      );
    });

    test('K — the send-and-read-only program is the refusal that classifies it', () async {
      // Seed #9's own test for Breaking: "an observable refusal of a
      // previously-accepted operation". The pre-fix transcript captured at
      // slice 1 shows the child SUCCESSFULLY READING `zid` from the copy
      // before the double-close — so this shape WORKED, on shipped surface,
      // and now throws at the spawn call.
      final session = await Session.open(config: _quiet());
      addTearDown(session.close);

      Object? thrown;
      try {
        final rp = ReceivePort();
        addTearDown(rp.close);
        await Isolate.spawn(_childEntry, <Object>[session, rp.sendPort]);
        // The refusal under test is an Error subtype by the SDK's contract.
        // ignore: avoid_catching_errors
      } on ArgumentError catch (e) {
        thrown = e;
      }
      expect(
        thrown,
        isA<ArgumentError>(),
        reason:
            'the send-and-read-only shape still crosses, so this unit creates '
            'no refusal and the inventory has nothing to classify',
      );
      expect(thrown.toString(), matches(_namesClass('Session')));
    });

    test('K — the SILENT-STOP class is named, and does not occur here', () {
      // ⚠️ A grep for throws CANNOT SEE this shape: a program keeps running
      // and stops receiving — no throw, no error, delivered 3 -> 0. It is an
      // inventory class that must be covered BY INSPECTION rather than by
      // search, and naming it is the deliverable.
      //
      // It does NOT occur in this unit's shipped diff, because no push-family
      // finalizer lands — which is itself the finding. The guard that would
      // catch it if one ever did is slice 13's `gc-sub` cell.
      final libDir = Directory('lib');
      final attachSites = <String>[];
      for (final f in libDir.listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final text = f.readAsStringSync();
        if (RegExp(r'\w+Finalizer\s*\.\s*attach|\.\.attach\(').hasMatch(text)) {
          attachSites.add(f.path.split('/').last);
        }
      }
      // The push family and Session must appear NOWHERE in that list.
      for (final forbidden in const [
        'subscriber.dart',
        'queryable.dart',
        'pull_subscriber.dart',
        'pull_queryable.dart',
        'pull_replies.dart',
        'advanced_subscriber.dart',
        'session.dart',
        'querier.dart',
        'query.dart',
        'liveliness.dart',
      ]) {
        expect(
          attachSites,
          isNot(contains(forbidden)),
          reason:
              'a finalizer is attached in $forbidden — an EXCLUDED class. '
              'That introduces the silent-stop class into this unit diff, '
              'which the inventory says does not occur here. ESCALATE.',
        );
      }
      // Positive control for the same search.
      expect(
        attachSites,
        contains('bytes.dart'),
        reason: 'the attach-site search found nothing even in bytes.dart',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // Seed [10a] slice 6 — the additive-vs-breaking PAIR, on the REAL types.
  //
  // ⛔ THIS PAIR CARRIES A RULING, AND REVERSING IT CHANGES THE UNIT'S TAG.
  // A retained payload is a `ZBytes`, which holds a native handle and is
  // therefore unsendable by design. The question this unit had to answer is
  // whether `Sample` and `Reply` must ALSO take an unsendable marker.
  //
  // The ruling is ADDITIVE — no marker on either — on this reasoning: the VM
  // refuses TRANSITIVELY, so a `Sample` carrying a payload is *already*
  // refused by the handle's own marker; and a `Sample` whose `payloadZBytes`
  // is null holds no native handle at all and is genuinely safe to send.
  // Marking `Sample` unconditionally would refuse something that is safe
  // today, which makes the conservative-looking alternative the BREAKING one.
  //
  // ⭐ The pair is what makes the ruling attackable: reversing it turns the
  // second cell red. These two were measured at the plan gate on synthetic
  // carriers; here they are the shipped regression on the real types.
  //
  // These live beside the sendability instrument rather than in this slice's
  // own lifetime file, DELIBERATELY: `_trySend` and the word-bounded
  // `Class: <name>` matcher are here, and copying them would reproduce the
  // repeated-shape defect this project has already paid for. Recorded as a
  // deviation from the plan's stated file, with its reason.
  // ═══════════════════════════════════════════════════════════════════════
  group('the retained-payload sendability pair', () {
    Sample sampleWith(ZBytes? retained) => Sample(
      keyExpr: 'test/sendability',
      payload: 'p',
      payloadBytes: Uint8List.fromList([1, 2, 3]),
      kind: SampleKind.put,
      payloadZBytes: retained,
    );

    test(
      'a Sample carrying a retained payload is refused, naming ZBytes',
      () async {
        // Given: a Sample whose payloadZBytes is non-null
        final retained = ZBytes.fromUint8List(Uint8List.fromList([1, 2, 3]));
        addTearDown(retained.dispose);

        // When: it is sent across an isolate boundary
        final verdict = await _trySend(sampleWith(retained));

        // Then: refused, and refused BY THE HANDLE'S OWN MARKER — not by
        // accident of some incidental field. `Class: ZBytes`, not
        // `Class: Sample`: the marker is on the thing that holds the handle,
        // and the refusal is transitive through the carrier.
        _expectRejectedNaming(verdict, 'ZBytes');
      },
    );

    test('a Sample with no retained payload still crosses', () async {
      // Given: a Sample from a retention-off carrier
      // When: it is sent across an isolate boundary
      final verdict = await _trySend(sampleWith(null));

      // Then: it crosses. ⛔ THIS IS THE CELL THAT MAKES THE UNIT ADDITIVE.
      // No previously-accepted operation is refused. If a marker were put on
      // `Sample` unconditionally, this would go red — and that is precisely
      // the reversal the ruling was weighed against.
      expect(
        verdict.sendable,
        isTrue,
        reason:
            'a payload-less Sample was refused, so this unit is BREAKING '
            "against the roadmap row's additive tag. That is a "
            'plan-affecting finding and goes back to CA — it is NOT a test '
            'to adjust. Verdict: $verdict',
      );
      expect(verdict.arrivedType, equals('Sample'));
    });

    test(
      'the refusal is transitive, not a property of Sample itself',
      () async {
        // Given: the retained handle ALONE, with no carrier
        final retained = ZBytes.fromUint8List(Uint8List.fromList([9]));
        addTearDown(retained.dispose);

        // When/Then: it is refused on its own terms, naming the same class.
        // Together with the two cells above this establishes the mechanism:
        // `Sample` is refused only WHILE it carries one, which is the whole
        // ground for not marking `Sample`.
        _expectRejectedNaming(await _trySend(retained), 'ZBytes');
      },
    );
  });
}
