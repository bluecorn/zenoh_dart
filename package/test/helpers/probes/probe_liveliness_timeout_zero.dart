// Probe: is livelinessGet's timeout_ms == 0 a literal value or canon's
// config-default sentinel? The intended discriminator was COMPLETION LATENCY
// with NO alive token -- a literal 0 completes at once, the ~10 s config
// default does not. It turned out not to discriminate: see the README.
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<int> elapsed(Stream<Reply> s) async {
  final sw = Stopwatch()..start();
  await s.toList().timeout(const Duration(seconds: 30));
  return sw.elapsedMilliseconds;
}

Future<void> main() async {
  final a = await Session.open(
    config: Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19338"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final b = await Session.open(
    config: Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19338"]')
      ..insertJson5('scouting/multicast/enabled', 'false')
      ..insertJson5('scouting/gossip/enabled', 'false'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));

  // NO alive token on this key expression anywhere.
  const none = 'probe/none/*';
  for (final label in ['ZERO', 'ZERO', '3S', 'DEFAULT']) {
    final t = switch (label) {
      'ZERO' => Duration.zero,
      '3S' => const Duration(seconds: 3),
      _ => null,
    };
    final ms = await elapsed(b.livelinessGet(none, timeout: t));
    stdout.writeln('NOTOKEN_${label}_MS=$ms');
  }

  // And the same three with an alive token, for the delivery question.
  final token = a.declareLivelinessToken('probe/live/zero');
  await Future<void>.delayed(const Duration(seconds: 1));
  final sw = Stopwatch()..start();
  final r0 = await b
      .livelinessGet('probe/live/*', timeout: Duration.zero)
      .toList();
  stdout.writeln('TOKEN_ZERO count=${r0.length} ms=${sw.elapsedMilliseconds}');

  token.close();
  b.close();
  a.close();
  stdout.writeln('PROBE_DONE');
}
