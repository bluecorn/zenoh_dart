// The interleaved-rounds driver for seed [D1] slice 1, criterion B's
// adversarial half.
//
// ⚠️ THIS IS A REGRESSION GUARD, NOT THE PROOF, and the distinction is the
// whole reason this comment exists. Under the mechanism this unit installs the
// detail is fixed at throw time — it is a `String` already sitting on the
// exception — so no amount of interleaving can make a message name another
// round. The cell CANNOT FAIL on a correct implementation.
//
// What it is for: it fails loudly the day someone reintroduces a read that is
// separate from its capture. The structural proof that no such read exists is
// `last_error_binding_test.dart`'s first cell; this one is the behavioural
// tripwire underneath it.
//
// The shape it drives is the one the defect was measured on
// (`development/independent/concurrency-reappraisal-20260827.md:118` — a
// thread-local read straddling an event-loop turn returned ANOTHER
// operation's message 249 times in 300):
//
//   * TWO isolates, running concurrently, so canon's per-thread
//     ERROR_DESCRIPTION is being overwritten while each round is in flight;
//   * a full event-loop turn between the failing call and the inspection of
//     what it produced;
//   * a round token that rides CANON'S OWN TEXT, not ours. `Config.fromFile`'s
//     base text also contains the path, so the check is made against the
//     detail segment only — measured: canon renders
//     `Failed to read config from /nonexistent/zdrc-a-7.json5: No such file
//     or directory (os error 2) at …`.
//
// ⛔ UNSTABLE ONLY. On the `stable` variant the capture is compiled out and
// there is no detail segment at all, so every round would report a violation
// that is an honest absence rather than a defect. The calling cell gates on
// `ZenohFeatures.hasUnstableApi`.
import 'dart:isolate';

import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';

/// Matches the round tokens this harness mints, in canon's rendering of them.
final RegExp _roundToken = RegExp(r'zdrc-[ab]-\d+');

/// Runs [rounds] rounds in each of two concurrent isolates.
///
/// Returns the violations found — empty means every message named its own
/// round and no round came back without a detail. A non-empty list is
/// returned rather than thrown so the caller can report *how many* of how many
/// failed, which is what distinguishes a probabilistic defect from a lucky
/// read.
Future<List<String>> runInterleavedRounds({int rounds = 300}) async {
  final batches = await Future.wait([
    Isolate.run(() => driveRounds('a', rounds)),
    Isolate.run(() => driveRounds('b', rounds)),
  ]);
  return [...batches[0], ...batches[1]];
}

/// One isolate's rounds. Top-level so it is reachable from an `Isolate.run`
/// closure that captures nothing but an `int` and a `String`.
///
/// ⚠️ No `Config` crosses the isolate boundary — each round builds and
/// discards its own inside the isolate that made it. `Config` is unsendable
/// under the ownership-and-lifetime contract, and sending one would throw
/// `ArgumentError` rather than measure anything.
Future<List<String>> driveRounds(String label, int rounds) async {
  final violations = <String>[];
  for (var round = 0; round < rounds; round++) {
    final token = 'zdrc-$label-$round';
    final path = '/nonexistent/$token.json5';
    final base = 'Failed to create config from file "$path"';

    String? message;
    try {
      Config.fromFile(path);
    } on ZenohException catch (e) {
      message = e.message;
    }

    // The straddle. Under the deleted mechanism this is where the detail was
    // fetched, on whichever OS thread the VM had migrated the isolate onto.
    await Future<void>.delayed(Duration.zero);

    if (message == null) {
      violations.add('$token: Config.fromFile did not throw');
      continue;
    }
    if (!message.startsWith('$base: ')) {
      violations.add('$token: no detail segment — $message');
      continue;
    }
    final detail = message.substring(base.length + 2);
    final named = _roundToken
        .allMatches(detail)
        .map((m) => m.group(0)!)
        .toSet();
    if (named.isEmpty) {
      violations.add('$token: detail names no round — $detail');
    } else if (named.length != 1 || named.first != token) {
      violations.add('$token: detail names $named');
    }
  }
  return violations;
}
