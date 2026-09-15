// Drives every detail-carrying `Config` failure and prints what came out.
//
// WHY A SUBPROCESS. The thing under test is a property of the loaded NATIVE,
// not of the Dart code: on the `stable` variant — the one consumers get, per
// `package/hook/build.dart`'s `?? 'stable'` — the last-error capture is
// compiled out, and the same call produces base text with no detail segment.
// The variant is selected by `ZENOH_DART_VARIANT`, and an environment
// variable can only be set for a CHILD process.
//
// ⛔ Every assertion about the `stable` arm in this unit runs through here.
// An in-process cell would assert the `unstable` behaviour and report it as
// coverage of the default variant — the structural false green seed [D1]
// names as the reason criterion F2 exists.
//
// Prints one line per driver, in a form the parent can split on the first
// `=`; the message itself may contain anything canon chose to put in it,
// newlines included, so each line is JSON-encoded.
//
//   VARIANT=<unstable|stable|absent>
//   FILE=<json string>
//   STR=<json string>
//   INSERT=<json string>
//   GET=<json string>
//   ENV=<json string>
//   PROBE_DONE
//
// An optional first argument is a marker string interpolated into the driven
// values, so a caller can put a recognisable fake secret through the paths
// and assert on what comes back (criterion F3).
import 'dart:convert';
import 'dart:io';

import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/unstable/features.dart';

String _drive(void Function() body) {
  try {
    body();
    return '<no throw>';
  } on ZenohException catch (e) {
    return e.message;
  } on Object catch (e) {
    return '<non-ZenohException: $e>';
  }
}

void main(List<String> args) {
  final marker = args.isEmpty ? 'zdmarker' : args[0];

  stdout.writeln(
    'VARIANT=${ZenohFeatures.hasUnstableApi ? 'unstable' : 'stable'}',
  );

  final config = Config();
  final lines = <String, String>{
    'FILE': _drive(() => Config.fromFile('/nonexistent/$marker.json5')),
    'STR': _drive(() => Config.fromStr('{ bad json $marker')),
    'INSERT': _drive(() => config.insertJson5('!!bad key!!', '"$marker"')),
    'GET': _drive(() => config.get('!!$marker!!')),
    'ENV': _drive(Config.fromEnv),
    // The CARET driver, added for slice 4. The other insert driver is
    // rejected by KEY ("unknown key") and canon renders no caret for it; this
    // one is rejected by VALUE, where canon's json5 parser echoes the source
    // line and points at the offending token. They are different failure
    // classes and only this one exercises the echo.
    'CARET': _drive(
      () => config.insertJson5(
        'connect/endpoints',
        '["tcp/1.2.3.4:7447" $marker]',
      ),
    ),
  };
  config.dispose();

  for (final entry in lines.entries) {
    stdout.writeln('${entry.key}=${jsonEncode(entry.value)}');
  }
  stdout.writeln('PROBE_DONE');
}
