// Drives every `Session.open` failure class this unit measured, with a
// recognisable fake secret planted in the config, and reports what came out.
//
// ⛔ WHY THIS EXISTS AT ALL. The shipped open path carries canon's own failure
// text — captured on the worker, marshalled with the post. Its input is the
// WHOLE CONFIG, secrets included. Nobody had measured what it emits, and the
// security ruling this unit implements was written before that path existed.
// A "no leak" claim with no instrument behind it is worth nothing.
//
// ⛔ THE POSITIVE CONTROL RUNS IN THE SAME PROCESS, ON THE SAME VARIANT, AND
// ITS RESULT IS REPORTED. It puts the same marker through the enriched config
// channel, where the echo is measured and expected. If the control does not
// show the marker, this instrument is blind and every negative below is
// worthless rather than reassuring.
//
// ⛔ A SUBPROCESS, because the variant is selected by `ZENOH_DART_VARIANT` and
// an environment variable can only be set for a child. On `stable` the capture
// is compiled out, so the open path carries no detail at all — an honest
// absence, and the variant consumers actually get.
//
// Ports 19743-19750, this unit's reserved block (the tree's high-water was
// 19742). Several cases below are LISTEN endpoints that get far enough to
// touch the port before failing, so they cannot borrow another group's.
//
// Output, one JSON object per line:
//   {"case":"CONTROL","fired":bool,"marker":bool,"message":"..."}
//   {"case":"A","fired":bool,"carried":bool,"marker":bool,"rc":int,...}
//   PROBE_DONE
import 'dart:convert';
import 'dart:io';

import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/session.dart';
import 'package:zenoh_dart/src/unstable/features.dart';

/// The marker. Deliberately not a real secret shape, and deliberately
/// unmistakable in a haystack of canon's own prose.
const secret = 'S3CR3T-D1-CELL-c0ffee';

/// The nine drivers measured to reach a canon open failure, by the letter the
/// probe record gives them, plus the config each installs.
///
/// ⚠️ Three of the probe's twelve are absent BY MEASUREMENT, not oversight:
/// two opened successfully (the driver never fired) and one failed at the
/// insert rather than the open. Including them would have added three cases
/// that assert nothing about the open path.
const drivers = <String, Map<String, String>>{
  'A': {
    'connect/endpoints':
        '["bogusproto/127.0.0.1:19748#listen_private_key_base64=$secret"]',
  },
  'B': {
    'listen/endpoints':
        '["bogusproto/127.0.0.1:19749#listen_private_key_base64=$secret"]',
  },
  'C': {
    'listen/endpoints':
        '["tls/127.0.0.1:19743#listen_private_key_base64='
        '$secret&listen_certificate_base64=bm90LWEtY2VydA=="]',
  },
  'D': {
    'listen/endpoints': '["bogusproto/127.0.0.1:19750"]',
    'transport/auth/usrpwd/password': '"$secret"',
  },
  'F': {
    'listen/endpoints':
        '["tcp/@@not a locator@@#listen_private_key_base64=$secret"]',
  },
  'H': {
    'listen/endpoints': '["tcp/127.0.0.1:19744"]',
    'transport/auth/usrpwd':
        '{"user":"u","password":"$secret",'
        '"dictionary_file":"/nonexistent/$secret.txt"}',
  },
  'I': {
    'listen/endpoints': '["tcp/127.0.0.1:19745"]',
    'access_control':
        '{"enabled":true,"default_permission":"deny",'
        '"rules":[{"id":"$secret","messages":["put"],'
        '"flows":["egress"],"permission":"allow","key_exprs":["**"]}]}',
  },
  'J': {
    'listen/endpoints':
        '["tls/127.0.0.1:19746#listen_private_key_file=/nonexistent/$secret'
        '.pem&listen_certificate_file=/nonexistent/$secret.crt"]',
  },
  'L': {
    'listen/endpoints':
        '["tls/127.0.0.1:19747&listen_private_key_base64='
        'UzNDUjNULUQxLUNFTEwtYzBmZmVl"]',
  },
};

void emit(Map<String, Object?> row) => stdout.writeln(jsonEncode(row));

Future<void> main() async {
  emit({
    'case': 'VARIANT',
    'variant': ZenohFeatures.hasUnstableApi ? 'unstable' : 'stable',
  });

  // The positive control, first and in this same process.
  try {
    Config().insertJson5('connect/endpoints', '["tcp/1.2.3.4:7447" $secret]');
    emit({'case': 'CONTROL', 'fired': false, 'marker': false, 'message': ''});
  } on ZenohException catch (e) {
    emit({
      'case': 'CONTROL',
      'fired': true,
      'marker': e.message.contains(secret),
      'message': e.message,
    });
  }

  for (final entry in drivers.entries) {
    final config = Config();
    try {
      entry.value.forEach(config.insertJson5);
      // Off the LAN: this probe must not scout the developer's network.
      config.insertJson5('scouting/multicast/enabled', 'false');
    } on Object catch (e) {
      emit({'case': entry.key, 'fired': false, 'setupFailed': '$e'});
      config.dispose();
      continue;
    }
    try {
      (await Session.open(config: config)).close();
      emit({'case': entry.key, 'fired': false, 'opened': true});
    } on ZenohException catch (e) {
      emit({
        'case': entry.key,
        'fired': true,
        'carried': e.message.contains('Zenoh says:'),
        'marker': e.message.contains(secret),
        'rc': e.returnCode,
        'message': e.message,
      });
    }
  }

  stdout.writeln('PROBE_DONE');
}
