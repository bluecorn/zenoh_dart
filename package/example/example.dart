import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main() async {
  Zenoh.initLog('error');

  // Open a zenoh session in peer mode (default). Guarded the way canon's
  // examples guard it -- report and exit, rather than letting the failure
  // present as an unhandled exception. The guard is inline here because this
  // file is the package showcase, not one of the canon-mirroring `z_*`
  // examples, and so does not take the shared `common_args.dart` block.
  final Session session;
  try {
    session = await Session.open();
  } on ZenohException {
    print('Unable to open session!');
    exit(255);
  }

  try {
    session
      // Put a value on a key expression
      ..put('demo/example/greeting', 'Hello from Dart!')
      // Delete a resource
      ..deleteResource('demo/example/greeting');
  } finally {
    // Always release the native resources held by the session
    session.close();
  }
}
