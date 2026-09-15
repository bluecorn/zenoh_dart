// Red-leg harness for ownership-sweep F12: Session.get() used to leave its
// ReceivePort and StreamController open when a disposed/consumed payload made
// the call throw partway through.
//
// A heap leak is invisible here, but a PORT leak is not: an open ReceivePort
// keeps the isolate alive, and no native sentinel can ever close it because
// zd_get never ran. So the observable consequence is a process that will not
// exit.
//
//   fixed  -> prints THREW, then EXITING, exit 0
//   leaked -> prints THREW, then hangs forever
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  final session = await Session.open(
    config: Config()..insertJson5('scouting/multicast/enabled', 'false'),
  );

  final payload = ZBytes.fromString('payload')..dispose();
  // Caught as Object and type-tested rather than `on StateError`, which the
  // lints reject: the leg under test IS the StateError path, since a disposed
  // payload is the only way to make get() throw partway through the call.
  var threw = false;
  try {
    session.get('zenoh/dart/own/f12', payload: payload);
  } on Object catch (e) {
    threw = e is StateError;
  }
  stdout.writeln(threw ? 'THREW' : 'NO_THROW');

  session.close();
  stdout.writeln('EXITING');
}
