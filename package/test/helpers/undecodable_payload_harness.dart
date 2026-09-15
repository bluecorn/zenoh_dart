// The child behind seed [D1] slice 13 — a value the binding cannot convert.
//
// ⛔ WHY A CHILD AT ALL. The failure is injected with LD_PRELOAD, which can
// only be set for a process at spawn. `z_bytes_to_slice` is a TEXT symbol that
// `libzenoh_dart.so` imports from `libzenohc.so`, so the call goes through the
// PLT and a preloaded definition wins — unlike the post site, which is a data
// pointer and needed a dlsym swap instead.
//
// ⛔ AND THE ARMING WINDOW IS EXACT. The injector is armed from HERE, through
// the same already-preloaded object (dlopen of a loaded library returns the
// existing handle), immediately before the operation under test and disarmed
// immediately after. An env-armed injector would fire on the nth process-wide
// call, and setup makes an unpredictable number of those — the cell would be
// asserting against whichever call happened to be nth, which is not a
// controlled experiment.
//
// Markers:
//   UD_START <seam> <mode>
//   UD_FIRED=<n>          injected failures — ⛔ THE POSITIVE CONTROL
//   UD_ERROR=<message>    an error reached the stream's error channel
//   UD_SAMPLE=<payload>   a value was delivered
//   UD_ATTACH=<value>     an attachment was delivered (or `<none>`)
//   UD_RESUMED=<payload>  a good value delivered AFTER an error
//   UD_DONE
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

/// The injector's arming surface, resolved out of the preloaded object.
class Injector {
  Injector(String path) {
    final lib = DynamicLibrary.open(path);
    arm = lib
        .lookupFunction<
          Void Function(Int, Int, Int),
          void Function(int, int, int)
        >('zdi_arm');
    disarm = lib.lookupFunction<Void Function(), void Function()>(
      'zdi_disarm',
    );
    fired = lib.lookupFunction<Int Function(), int Function()>('zdi_fired');
  }

  late final void Function(int, int, int) arm;
  late final void Function() disarm;
  late final int Function() fired;
}

Config peerConfig(int port, {required bool listen}) {
  final config = Config()
    ..insertJson5('mode', '"peer"')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  if (listen) {
    config.insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]');
  } else {
    config.insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]');
  }
  return config;
}

void emitError(Object error) =>
    stdout.writeln('UD_ERROR=${jsonEncode('$error')}');

Future<void> main(List<String> args) async {
  final seam = args.isEmpty ? 'subscriber' : args[0];
  final mode = args.length > 1 ? args[1] : 'armed';
  final port = args.length > 2 ? int.parse(args[2]) : 19755;
  final injectorPath = args.length > 3 ? args[3] : '';

  stdout.writeln('UD_START $seam $mode');
  final injector = Injector(injectorPath);

  final listener = await Session.open(config: peerConfig(port, listen: true));
  final connector = await Session.open(config: peerConfig(port, listen: false));
  await Future<void>.delayed(const Duration(milliseconds: 400));

  const keyExpr = 'zenoh/dart/d1/undecodable';

  switch (seam) {
    case 'subscriber':
      final subscriber = listener.declareSubscriber(keyExpr);
      final errors = <Object>[];
      final samples = <Sample>[];
      subscriber.stream.listen(samples.add, onError: errors.add);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      if (mode == 'armed') injector.arm(0, 1, -7);
      connector.putBytes(keyExpr, ZBytes.fromString('PAYLOAD-ONE'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      injector.disarm();

      // ⛔ AND THEN A GOOD ONE, in the same run: a conversion failure is a
      // failed CALL, not a dead channel, so the stream must keep delivering.
      connector.putBytes(keyExpr, ZBytes.fromString('PAYLOAD-TWO'));
      await Future<void>.delayed(const Duration(milliseconds: 600));

      errors.forEach(emitError);
      for (final s in samples) {
        stdout.writeln('UD_SAMPLE=${jsonEncode(s.payload)}');
      }
      subscriber.close();

    case 'attachment':
      final subscriber = listener.declareSubscriber(keyExpr);
      final errors = <Object>[];
      final samples = <Sample>[];
      subscriber.stream.listen(samples.add, onError: errors.add);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // ⛔ SKIP ONE, FAIL ONE. A sample carrying both converts its PAYLOAD
      // first, so arming from zero fails the payload and never reaches the
      // attachment branch — which the first run of this did, reporting a
      // "payload" error from a cell about attachments.
      if (mode == 'armed') injector.arm(1, 1, -7);
      connector.putBytes(
        keyExpr,
        ZBytes.fromString('WITH-ATTACHMENT'),
        attachment: ZBytes.fromString('ATTACH-ONE'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      injector.disarm();

      errors.forEach(emitError);
      for (final s in samples) {
        stdout
          ..writeln('UD_SAMPLE=${jsonEncode(s.payload)}')
          ..writeln('UD_ATTACH=${jsonEncode(s.attachment ?? '<none>')}');
      }
      subscriber.close();

    case 'queryable':
      final queryable = listener.declareQueryable(keyExpr);
      final errors = <Object>[];
      final queries = <Query>[];
      queryable.stream.listen(queries.add, onError: errors.add);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      if (mode == 'armed') injector.arm(0, 1, -7);
      unawaited(
        connector
            .get(keyExpr, payload: ZBytes.fromString('QUERY-PAYLOAD'))
            .drain<void>()
            .catchError((_) {}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 900));
      injector.disarm();

      errors.forEach(emitError);
      for (final q in queries) {
        stdout.writeln('UD_SAMPLE=${jsonEncode(q.payloadBytes ?? [])}');
        q.dispose();
      }
      queryable.close();

    case 'session-get':
    case 'querier-get':
      final queryable = listener.declareQueryable(keyExpr);
      queryable.stream.listen((q) {
        q
          ..reply(keyExpr, 'REPLY-BODY')
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final errors = <Object>[];
      final replies = <Reply>[];
      if (mode == 'armed') injector.arm(0, 1, -7);
      final stream = seam == 'session-get'
          ? connector.get(keyExpr)
          : connector.declareQuerier(keyExpr).get();
      final done = Completer<void>();
      stream.listen(
        replies.add,
        onError: errors.add,
        onDone: done.complete,
        cancelOnError: false,
      );
      await done.future.timeout(
        const Duration(seconds: 12),
        onTimeout: () {},
      );
      injector.disarm();

      errors.forEach(emitError);
      for (final r in replies) {
        stdout.writeln('UD_SAMPLE=${jsonEncode(r.isOk ? r.ok.payload : '')}');
      }
      queryable.close();

    default:
      stdout.writeln('UD_UNKNOWN_SEAM $seam');
  }

  stdout.writeln('UD_FIRED=${injector.fired()}');
  connector.close();
  listener.close();
  stdout.writeln('UD_DONE');
}
