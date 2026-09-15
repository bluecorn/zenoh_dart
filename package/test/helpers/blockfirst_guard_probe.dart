// Drives seed [CC]'s stable-native half — the block-first guard — and prints
// what came out, one JSON object per line.
//
// ⛔ WHY A SUBPROCESS. Everything this unit asserts is a property of the
// LOADED NATIVE, not of the Dart code: `CongestionControl.blockFirst` is
// representable under `Z_FEATURE_UNSTABLE_API` and not otherwise. The variant
// is selected by `ZENOH_DART_VARIANT`, and an environment variable can only
// be set for a CHILD process. An in-process cell would assert the `unstable`
// behaviour and report it as coverage of the stable one — the structural
// false green seed [D1]'s criterion F2 exists to forbid.
//
// ⛔ THE INSTRUMENT ARMS ITSELF FIRST, and it is the first row emitted. It
// reports the loaded native's unstable-API bit and the resolved library path.
// If that row says `unstable`, every row below is worthless rather than
// reassuring — so the parent FAILS on it. It does not skip: a skip reports a
// blind instrument as "did not run".
//
// ⛔ THE CONTROLS ARE PART OF THE INSTRUMENT. Every refusal row is paired
// with a control row driving `block`, `drop` and the omitted parameter
// through the same entry point. Without them a guard that refused everything
// would read exactly like a guard that refuses one value.
//
// No endpoints and no multicast: this probe must not scout the developer's
// network, and it needs no peer — every assertion here is raised before
// anything reaches the wire. It therefore reserves no ports.
//
// Output: one JSON object per line, `{"case": "<NAME>", ...}`, then
// `PROBE_DONE`.
import 'dart:convert';
import 'dart:io';

import 'package:zenoh_dart/src/bytes.dart';
import 'package:zenoh_dart/src/channel_kind.dart';
import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/congestion_control.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/publisher.dart';
import 'package:zenoh_dart/src/querier.dart';
import 'package:zenoh_dart/src/session.dart';
import 'package:zenoh_dart/src/unstable/features.dart';

void emit(String name, Map<String, Object?> row) =>
    stdout.writeln(jsonEncode(<String, Object?>{'case': name, ...row}));

/// Runs [body] and reports the throw, or its absence, in ONE row shape.
///
/// A refusal and a non-refusal differ by field VALUE, never by row shape, so
/// the parent never has to tell two shapes apart to read an answer.
Map<String, Object?> drive(void Function() body) {
  try {
    body();
    return <String, Object?>{'threw': false};
    // ⛔ CATCHING AN ERROR SUBTYPE IS THE POINT HERE: `ArgumentError` is what
    // the guard throws, and reporting it as an unclassified `Object` would
    // lose the two fields the parent asserts on -- the argument name and the
    // offending value.
    // ignore: avoid_catching_errors
  } on ArgumentError catch (e) {
    return <String, Object?>{
      'threw': true,
      'type': 'ArgumentError',
      'name': '${e.name}',
      'invalidValue': '${e.invalidValue}',
      'message': '$e',
    };
  } on Object catch (e) {
    return <String, Object?>{
      'threw': true,
      'type': '${e.runtimeType}',
      'name': null,
      'invalidValue': null,
      'message': '$e',
    };
  }
}

/// [drive], for an arm that has to be awaited before it is released.
Future<Map<String, Object?>> driveAsync(Future<void> Function() body) async {
  try {
    await body();
    return <String, Object?>{'threw': false};
    // As in `drive`: the Error subtype IS the measurement, and reporting it
    // as an unclassified `Object` would lose the argument name and the
    // offending value the parent asserts on.
    // ignore: avoid_catching_errors
  } on ArgumentError catch (e) {
    return <String, Object?>{
      'threw': true,
      'type': 'ArgumentError',
      'name': '${e.name}',
      'invalidValue': '${e.invalidValue}',
      'message': '$e',
    };
  } on Object catch (e) {
    return <String, Object?>{
      'threw': true,
      'type': '${e.runtimeType}',
      'name': null,
      'invalidValue': null,
      'message': '$e',
    };
  }
}

/// The three arms of a control row, driven through one entry point.
///
/// ⛔ THE OMITTED ARM IS NOT REDUNDANT beside `block` and `drop`: it is the
/// only one that reaches the guard with `null`, which is what every caller
/// who never heard of this unit passes.
Map<String, Object?> controls(
  Map<String, Object?> Function(CongestionControl? cc) arm,
) => <String, Object?>{
  'block': arm(CongestionControl.block),
  'drop': arm(CongestionControl.drop),
  'omitted': arm(null),
};

Future<Map<String, Object?>> controlsAsync(
  Future<Map<String, Object?>> Function(CongestionControl? cc) arm,
) async => <String, Object?>{
  'block': await arm(CongestionControl.block),
  'drop': await arm(CongestionControl.drop),
  'omitted': await arm(null),
};

const key = 'zenoh/dart/test/cc/blockfirst-guard';

/// Short enough that the control arms complete quickly with no responder, and
/// >= 1 ms so the sentinel-timeout guard is not what refuses them.
const shortTimeout = Duration(milliseconds: 300);

Future<Session> openQuiet() => Session.open(
  config: Config()..insertJson5('scouting/multicast/enabled', 'false'),
);

Future<void> main() async {
  emit('ARMED', <String, Object?>{
    'unstableApi': ZenohFeatures.hasUnstableApi,
    'libraryPath': resolvedLibraryPath,
  });

  // BEFORE ANY SESSION EXISTS. The decode seam is a pure function of the wire
  // byte and must not have learned about the native.
  emit('FROMWIRE2', <String, Object?>{
    'name': CongestionControl.fromWire(2).name,
    'isBlockFirst':
        CongestionControl.fromWire(2) == CongestionControl.blockFirst,
  });

  final session = await openQuiet();

  // ---- the four SAMPLE-emitting sites ----------------------------------

  emit(
    'PUT',
    drive(
      () => session.put(
        key,
        'v',
        congestionControl: CongestionControl.blockFirst,
      ),
    ),
  );
  emit(
    'PUT_CTRL',
    controls((cc) => drive(() => session.put(key, 'v', congestionControl: cc))),
  );

  emit(
    'PUTBYTES',
    drive(
      () => session.putBytes(
        key,
        ZBytes.fromString('v'),
        congestionControl: CongestionControl.blockFirst,
      ),
    ),
  );
  emit(
    'PUTBYTES_CTRL',
    controls(
      (cc) => drive(
        () => session.putBytes(
          key,
          ZBytes.fromString('v'),
          congestionControl: cc,
        ),
      ),
    ),
  );

  emit(
    'DELETE',
    drive(
      () => session.deleteResource(
        key,
        congestionControl: CongestionControl.blockFirst,
      ),
    ),
  );
  emit(
    'DELETE_CTRL',
    controls(
      (cc) => drive(() => session.deleteResource(key, congestionControl: cc)),
    ),
  );

  // The refused declaration's handle is captured rather than discarded: a
  // throw that had ALREADY produced a Publisher would leave the caller owning
  // something a failed call created, and only the variable can report that.
  Publisher? refusedPublisher;
  emit(
    'DECLPUB',
    drive(() {
      refusedPublisher = session.declarePublisher(
        key,
        congestionControl: CongestionControl.blockFirst,
      );
    }),
  );
  emit('DECLPUB_HANDLE', <String, Object?>{
    'produced': refusedPublisher != null,
  });
  emit(
    'DECLPUB_CTRL',
    controls(
      (cc) => drive(
        () => session.declarePublisher(key, congestionControl: cc).close(),
      ),
    ),
  );

  // ---- the three REQUEST-emitting sites --------------------------------
  //
  // ⛔ THE REFUSAL ARMS ARE DRIVEN SYNCHRONOUSLY, ON PURPOSE. All three return
  // their handle synchronously, so a guard sited AFTER the ReceivePort was
  // opened would still throw -- just with a port already leaked. Driving them
  // without an await is what lets "before any Stream is returned" be
  // falsified rather than assumed; the process's own exit code is the other
  // half of that claim.

  emit(
    'GET',
    drive(
      () => session.get(key, congestionControl: CongestionControl.blockFirst),
    ),
  );
  emit(
    'GET_CTRL',
    await controlsAsync(
      (cc) => driveAsync(
        () => session
            .get(key, timeout: shortTimeout, congestionControl: cc)
            .drain<void>(),
      ),
    ),
  );

  emit(
    'PULLGET',
    drive(
      () => session.pullGet(
        key,
        kind: ChannelKind.fifo,
        capacity: 4,
        congestionControl: CongestionControl.blockFirst,
      ),
    ),
  );
  emit(
    'PULLGET_CTRL',
    controls(
      (cc) => drive(
        () => session
            .pullGet(
              key,
              kind: ChannelKind.fifo,
              capacity: 4,
              timeout: shortTimeout,
              congestionControl: cc,
            )
            .dispose(),
      ),
    ),
  );

  Querier? refusedQuerier;
  emit(
    'DECLQUERIER',
    drive(() {
      refusedQuerier = session.declareQuerier(
        key,
        congestionControl: CongestionControl.blockFirst,
      );
    }),
  );
  emit('DECLQUERIER_HANDLE', <String, Object?>{
    'produced': refusedQuerier != null,
  });
  emit(
    'DECLQUERIER_CTRL',
    controls(
      (cc) => drive(
        () => session.declareQuerier(key, congestionControl: cc).close(),
      ),
    ),
  );

  // ---- the ORDER against the other domain guards -----------------------
  //
  // Both alternatives throw ArgumentError, so WHICH argument is named is the
  // only discriminator. The stated order is congestion, then capacity, then
  // timeout.

  emit(
    'ORDER_GET',
    drive(
      () => session.get(
        key,
        timeout: Duration.zero,
        congestionControl: CongestionControl.blockFirst,
      ),
    ),
  );
  emit(
    'ORDER_PULLGET',
    drive(
      () => session.pullGet(
        key,
        kind: ChannelKind.fifo,
        capacity: -1,
        timeout: Duration.zero,
        congestionControl: CongestionControl.blockFirst,
      ),
    ),
  );
  // And the pre-existing guards, unmoved for a caller who trips only one.
  emit(
    'GUARD_GET_TIMEOUT',
    drive(() => session.get(key, timeout: Duration.zero)),
  );
  emit(
    'GUARD_PULLGET_CAPACITY',
    drive(() => session.pullGet(key, kind: ChannelKind.fifo, capacity: -1)),
  );

  // ---- a refused call consumes nothing ---------------------------------
  //
  // ⛔ THE SECOND CALL IS THE ASSERTION, not the first. `markConsumed()` runs
  // after the native call on every path, so a guard sited at the marshal
  // would ALSO leave the payload intact -- but only because the throw happens
  // to precede the move. Reusing the value is what shows the outcome; the
  // siting cell in the parent shows it is by design.

  final payload = ZBytes.fromString('reuse-me');
  emit('REUSE_PAYLOAD', <String, Object?>{
    'first': drive(
      () => session.putBytes(
        key,
        payload,
        congestionControl: CongestionControl.blockFirst,
      ),
    ),
    'second': drive(() => session.putBytes(key, payload)),
  });

  final attachment = ZBytes.fromString('attach-me');
  emit('REUSE_ATTACHMENT', <String, Object?>{
    'first': drive(
      () => session.put(
        key,
        'v',
        attachment: attachment,
        congestionControl: CongestionControl.blockFirst,
      ),
    ),
    'second': drive(() => session.put(key, 'v', attachment: attachment)),
  });

  session.close();

  // ---- the refusal precedes even the closed-session check --------------
  //
  // A SECOND session, closed on purpose. Closing the first one earlier would
  // have taken every row above with it.
  final closed = await openQuiet();
  closed.close();
  emit(
    'CLOSED_BLOCKFIRST',
    drive(
      () => closed.putBytes(
        key,
        ZBytes.fromString('x'),
        congestionControl: CongestionControl.blockFirst,
      ),
    ),
  );
  emit(
    'CLOSED_DROP',
    drive(
      () => closed.putBytes(
        key,
        ZBytes.fromString('x'),
        congestionControl: CongestionControl.drop,
      ),
    ),
  );

  stdout.writeln('PROBE_DONE');
}
