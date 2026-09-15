// Does the query posting's borrowed encoding storage outlive the post?
//
// `_zd_str_to_cobject` BORROWS: its own doc comment states that
// `Dart_PostCObject_DL` copies typed data before it returns and that `data`
// borrows storage that outlives the post. The sample path and both reply arms
// already declare their `z_owned_string_t` in a scope enclosing the post and
// drop it after. The QUERY path did not — its owned string lived and died
// inside an `if (q_encoding != NULL)` block that closed before the post, and
// was safe only because the value posted was a malloc'd COPY. Deleting that
// copy without hoisting the string turns a correct-looking edit into a
// use-after-free.
//
// WHY A SUBPROCESS, AND WHY THIS INSTRUMENT. A freed glibc block still holds
// its bytes, so a use-after-free here reads back the right value and every
// behavioural assertion passes — the discipline's §3a class. `MALLOC_PERTURB_`
// makes glibc overwrite freed memory, which turns the silent case into a
// visible one; glibc reads it once at libc startup, so it cannot be set from
// inside the test process.
//
// Prints BORROW_OK and exits 0 when the received encoding is byte-identical.
// Anything else — a mismatch, a timeout, a crash — leaves the marker unprinted.
import 'dart:async';
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

const _endpoint = 'tcp/127.0.0.1:19571';
const _key = 'zenoh/dart/s10/probe/borrow';

/// NUL-free on purpose: this probe is about the STORAGE, not about length
/// carriage, and it runs before the send side is length-carried. A separator
/// and a long tail are what make a perturbed read obviously wrong.
const _encoding = 'text/plain;charset=utf-8';

Future<void> main() async {
  final hostConfig = Config()
    ..insertJson5('listen/endpoints', '["$_endpoint"]')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  final host = await Session.open(config: hostConfig);

  await Future<void>.delayed(const Duration(milliseconds: 500));

  final clientConfig = Config()
    ..insertJson5('connect/endpoints', '["$_endpoint"]')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false');
  final client = await Session.open(config: clientConfig);

  await Future<void>.delayed(const Duration(seconds: 1));

  final queryable = host.declareQueryable(_key);
  final first = queryable.stream.first;

  await Future<void>.delayed(const Duration(milliseconds: 500));

  unawaited(
    client
        .get(
          _key,
          payload: ZBytes.fromString('probe'),
          encoding: const Encoding(_encoding),
          timeout: const Duration(seconds: 3),
        )
        .drain<void>(),
  );

  String? seen;
  try {
    final query = await first.timeout(const Duration(seconds: 10));
    seen = query.encoding;
    query.dispose();
  } on TimeoutException {
    stdout.writeln('BORROW_FAIL no query arrived');
  }

  if (seen == _encoding) {
    stdout.writeln('BORROW_OK $seen');
  } else if (seen != null) {
    // Under MALLOC_PERTURB_ a released block reads back as the perturb byte,
    // so a hoisting failure surfaces here as a run of U+FFFD rather than as
    // the value that was actually sent.
    stdout.writeln('BORROW_FAIL expected="$_encoding" got="$seen"');
  }

  queryable.close();
  client.close();
  host.close();
  exit(seen == _encoding ? 0 : 1);
}
