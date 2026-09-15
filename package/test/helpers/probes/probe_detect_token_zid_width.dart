// probe_detect_token_zid_width.dart — seed #8, Slice 6/9.
//
// QUESTION. The detect stream's token key expression is
// `<ke>/@adv/pub/<zid>/<sn-source>/<metadata>`. Slice 6's shape cell first
// asserted the zid segment as `[0-9a-f]{32}` and went red on a re-run. Is that
// segment fixed-width, or is it canon's leading-zero-STRIPPED rendering — in
// which case the assertion was about a sample, not about canon, and carried a
// ~1-in-16 per-run red exactly as `interop/canon.dart` already records for
// `z_id_to_string`?
//
// METHOD. Forty fresh publisher sessions (the zid is per session, so each is
// one independent draw), each detected once, recording the segment's width.
// Counting the draws is the point: replication cannot separate 100% from 94%.
//
// Run with: cd package && fvm dart run test/helpers/probes/probe_detect_token_zid_width.dart
import 'dart:async';
import 'dart:io';

import 'package:zenoh_dart/zenoh_unstable.dart';

Future<String?> draw(int port, String key) async {
  final c1 = Config()
    ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false')
    ..insertJson5('timestamping/enabled', 'true');
  final s1 = await Session.open(config: c1);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final c2 = Config()
    ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]')
    ..insertJson5('scouting/multicast/enabled', 'false')
    ..insertJson5('scouting/gossip/enabled', 'false')
    ..insertJson5('timestamping/enabled', 'true');
  final s2 = await Session.open(config: c2);
  await Future<void>.delayed(const Duration(milliseconds: 700));

  final sub = s2.declareAdvancedSubscriber(
    key,
    options: const AdvancedSubscriberOptions(
      detectPublishers: DetectPublishersOptions(),
    ),
  );
  final seen = <Sample>[];
  final ss = sub.detectedPublishers!.listen(seen.add);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final pub = s1.declareAdvancedPublisher(
    key,
    options: const AdvancedPublisherOptions(publisherDetection: true),
  );

  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (seen.isEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final ke = seen.isEmpty ? null : seen.first.keyExpr;
  final ourZid = s1.zid.toHexString();
  await ss.cancel();
  sub.close();
  pub.close();
  s2.close();
  s1.close();
  if (ke == null) return null;
  return '$ke  ours=$ourZid';
}

Future<void> main() async {
  final widths = <int, int>{};
  for (var i = 0; i < 40; i++) {
    final r = await draw(19500 + i, 'zenoh/probe/tok$i');
    if (r == null) {
      stdout.writeln('$i: NO EVENT');
      continue;
    }
    final ke = r.split('  ').first;
    final segs = ke.split('/');
    final zid = segs[segs.length - 3];
    widths[zid.length] = (widths[zid.length] ?? 0) + 1;
    if (zid.length != 32) stdout.writeln('$i: SHORT(${zid.length}) $r');
  }
  stdout.writeln('zid-segment width distribution: $widths');
}
