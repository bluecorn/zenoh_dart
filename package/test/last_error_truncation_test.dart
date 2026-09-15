// Seed [D1] slice 14 — the truncation chain is stated, and what survives is
// asserted.
//
// ⛔ THE ROADMAP SAID "DOCUMENT THE 512 TRUNCATION". Both halves of that are
// wrong: the surviving length is **511**, because the copy clamps to
// `CAP - 1` to leave room for a terminator; and 512 is one stage of a chain
// of four, not the chain. Documenting one figure would leave a reader
// confident about the wrong number and unaware of the other three stages.
//
// ⚠️ NOTHING ON THE DART SURFACE SAID ANY OF IT before this slice.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/session.dart';
import 'package:zenoh_dart/src/unstable/features.dart';

/// See `open_detail_secrets_test.dart` for why prose is read flattened.
/// ⚠️ LOWERCASED, and needles must be lowercase too.
String flattenedProse(String path) =>
    File(path)
        .readAsStringSync()
        .replaceAll(RegExp(r'^\s*///?', multiLine: true), ' ')
        .replaceAll('*', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .toLowerCase();

/// Drives `Config.fromFile` on [path] and returns the detail segment, or null
/// when the message carried none.
String? detailFor(String path) {
  final base = 'Failed to create config from file "$path"';
  try {
    Config.fromFile(path);
    fail('expected the open to fail');
  } on ZenohException catch (e) {
    if (!e.message.startsWith('$base: ')) return null;
    return e.message.substring(base.length + 2);
  }
}

void main() {
  group('[D1] S14 — the truncation chain', () {
    test(
      'a message longer than the cap is truncated to the documented length',
      skip: ZenohFeatures.hasUnstableApi
          ? false
          : 'requires the unstable variant (no detail to truncate on stable)',
      () {
        // Canon renders "Failed to read config from <path>: ..." so a long
        // enough path drives a message past the cap without inventing one.
        final detail = detailFor('/nonexistent/${'x' * 700}.json5');
        expect(detail, isNotNull);
        expect(
          detail!.length,
          511,
          reason:
              '⛔ 511, NOT 512. The shim copies at most ZD_LAST_ERROR_CAP '
              '- 1 to leave room for a terminator, and the roadmap phrase '
              '"the 512 truncation" names a number that is off by one',
        );
      },
    );

    test('the whole chain is documented, not one figure', () {
      final doc = flattenedProse('lib/src/exceptions.dart');
      // Four stages, and the two middle ones can silently drop content.
      for (final needle in const [
        '1024-byte store', // canon's per-thread ERROR_DESCRIPTION
        '511 bytes plus a terminator', // the shim's clamp
        'the caller supplied', // ⚠️ re-derived: the third stage is the
        // caller's buffer, not a Dart read cap on a thread-local
        'lenient utf-8 decode', // and what a cut sequence becomes
      ]) {
        expect(
          doc,
          contains(needle),
          reason:
              'the chain is missing its "$needle" stage; documenting one '
              'figure leaves a reader confident about the wrong number',
        );
      }
      expect(
        doc,
        contains('silently drop'),
        reason:
            'which stages can drop content without saying so is the part '
            'a reader needs, and it is not derivable from the numbers',
      );
    });

    test(
      'a multi-byte sequence cut by the clamp degrades rather than throwing',
      skip: ZenohFeatures.hasUnstableApi
          ? false
          : 'requires the unstable variant',
      () {
        // ⛔ THREE ADJACENT OFFSETS, and that is not belt-and-braces. The
        // characters are three bytes wide, so exactly one of any three
        // consecutive prefix lengths puts the 511-byte cut on a character
        // boundary and the other two put it INSIDE a sequence. Picking one
        // offset by arithmetic against canon's own prefix would be a
        // calculation this cell cannot verify — and a boundary hit reports a
        // clean pass while testing nothing. Measured: a first attempt landed
        // exactly on a boundary and showed no replacement character at all.
        final seen = <bool>[];
        for (var pad = 0; pad < 3; pad++) {
          final path = '/nonexistent/${'a' * pad}${'あ' * 300}.json5';
          // The assertion that matters is that NOTHING THROWS: a decode that
          // threw while reporting an error would replace a diagnosable
          // failure with an undiagnosable one.
          final detail = detailFor(path);
          expect(detail, isNotNull);
          seen.add(detail!.contains('\u{FFFD}'));
        }
        expect(
          seen.any((hit) => hit),
          isTrue,
          reason:
              'no offset put the cut inside a multi-byte sequence, so the '
              'degrade path was never exercised: $seen',
        );
      },
    );

    // --- Edge cases ---

    test(
      "the open path's detail crosses the same chain",
      skip: ZenohFeatures.hasUnstableApi
          ? false
          : 'requires the unstable variant',
      () async {
        // The worker captures through the same helper, so the same bound
        // holds — and the dartdoc says so rather than leaving a reader to
        // assume the two paths differ.
        Object? error;
        try {
          final config = Config()
            ..insertJson5('scouting/multicast/enabled', 'false')
            ..insertJson5(
              'listen/endpoints',
              '["tls/127.0.0.1:19760#listen_private_key_file='
                  '/nonexistent/${'y' * 700}.pem'
                  '&listen_certificate_file=/nonexistent/cert.crt"]',
            );
          (await Session.open(config: config)).close();
        } on Object catch (e) {
          error = e;
        }
        expect(error, isA<ZenohException>());
        final message = (error! as ZenohException).message;
        const marker = '. Zenoh says: ';
        expect(message, contains(marker));
        final detail = message.substring(
          message.indexOf(marker) + marker.length,
        );
        expect(
          detail.length,
          lessThanOrEqualTo(511),
          reason:
              'the open path captured ${detail.length} bytes of detail, '
              'so it is NOT crossing the same clamp the config sites do',
        );

        final session = flattenedProse('lib/src/session.dart');
        expect(
          session,
          contains('same 511-byte clamp'),
          reason:
              'the open path must say it shares the bound, or a reader '
              'has to discover it by measuring',
        );
      },
    );

    test('on the stable variant there is no chain to document', () async {
      // ⛔ AN HONEST ABSENCE, not a truncation that did not occur. The capture
      // is compiled out, so there is nothing to truncate — reporting "0 bytes
      // truncated" would describe a stage that does not exist here.
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          'test/helpers/config_failure_probe.dart',
          'z' * 700,
        ],
        environment: {'ZENOH_DART_VARIANT': 'stable'},
      );
      final out = result.stdout as String;
      expect(out, contains('PROBE_DONE'), reason: '$out${result.stderr}');
      for (final line in const LineSplitter().convert(out)) {
        if (!line.startsWith('FILE=')) continue;
        final message = jsonDecode(line.substring(5)) as String;
        expect(
          message,
          startsWith('Failed to create config from file "/nonexistent/'),
        );
        expect(
          message,
          isNot(contains('Failed to read config from')),
          reason:
              'canon detail reached the message on the stable variant, '
              'where the capture is compiled out',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
