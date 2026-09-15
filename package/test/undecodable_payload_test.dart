// Seed [D1] slice 13 — a value that cannot be converted is not delivered as
// an empty success.
//
// ⛔ THE DEFECT, AND WHY IT IS THIS UNIT'S CHARTER IN ONE LINE. The shim tests
// `z_bytes_len(bytes) > 0 && z_bytes_to_slice(bytes, slice) == 0` and, when
// the second half is false, posts a ZERO-LENGTH BUFFER WITH NO ERROR SIGNAL —
// on every receive surface. A failure rendered as an empty success. And empty
// is a legitimate value on every one of these paths, so a consumer cannot tell
// the two apart even in principle.
//
// ⛔ THE BRANCH IS UNREACHABLE AT THE PIN, which is why it survived: canon's
// `z_bytes_to_slice` returns `Z_OK` unconditionally, from a single definition
// (`extern/zenoh-c/src/zbytes.rs:144-152`). So the fix needs an injector, and
// every cell here reads `UD_FIRED` — a run producing the expected output with
// that at 0 never entered the branch and proves nothing.
//
// ⛔ FOUR SEAMS, NOT THREE. `session.dart` and `querier.dart` parse the SAME
// reply post through INDEPENDENT code, so a three-seam fix leaves the querier
// column silently broken. That fourth seam was missed by an earlier
// enumeration and is asserted here by name.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

typedef SeamRun = ({
  int exitCode,
  int fired,
  List<String> errors,
  List<String> samples,
  List<String> attachments,
  String raw,
  String stderr,
});

/// Ports, one per seam, from this unit's reserved 19743-19762 block. Each
/// child opens a listening peer, so they cannot share.
const _ports = <String, int>{
  'subscriber': 19755,
  'attachment': 19756,
  'queryable': 19757,
  'session-get': 19758,
  'querier-get': 19759,
};

/// See `open_detail_secrets_test.dart` for why prose is read flattened.
///
/// ⚠️ USE THIS, NEVER A LOCAL NORMALIZER. The first cut of the claim cell here
/// wrote its own — whitespace collapse and lowercase, but no comment-marker
/// stripping — and every claim inside a dartdoc came back as `never /// as
/// empty`, unmatchable. That is the same false-red class this helper exists to
/// close, reintroduced by not reaching for it.
String flattenedProse(String path) =>
    File(path)
        .readAsStringSync()
        .replaceAll(RegExp(r'^\s*///?', multiLine: true), ' ')
        .replaceAll('*', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .toLowerCase();

final bool haveClang = Process.runSync('clang', ['--version']).exitCode == 0;

Future<String?> buildInjector(Directory dir) async {
  if (!haveClang) return null;
  final path = '${dir.path}/slice_fail_injector.so';
  final build = await Process.run('clang', [
    '-shared',
    '-fPIC',
    '-O0',
    '-g',
    '-o',
    path,
    'test/helpers/slice_fail_injector.c',
    '-ldl',
  ]);
  return build.exitCode == 0 ? path : null;
}

Future<SeamRun> runSeam(
  String seam,
  String mode,
  String injectorPath, {
  Duration timeout = const Duration(minutes: 3),
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      'run',
      'test/helpers/undecodable_payload_harness.dart',
      seam,
      mode,
      '${_ports[seam]}',
      injectorPath,
    ],
    environment: {
      'ZENOH_DART_VARIANT': 'unstable',
      // ⛔ The interposition itself. `z_bytes_to_slice` is a TEXT symbol that
      // libzenoh_dart.so imports from libzenohc.so, so the call goes through
      // the PLT and a preloaded definition wins.
      'LD_PRELOAD': injectorPath,
    },
  );
  final out = StringBuffer();
  final err = StringBuffer();
  process.stdout.transform(utf8.decoder).listen(out.write);
  process.stderr.transform(utf8.decoder).listen(err.write);

  var timedOut = false;
  final code = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  await Future<void>.delayed(const Duration(milliseconds: 100));

  final raw = out.toString();
  var fired = -1;
  final errors = <String>[];
  final samples = <String>[];
  final attachments = <String>[];
  var done = false;
  for (final line in const LineSplitter().convert(raw)) {
    if (line.startsWith('UD_FIRED=')) {
      fired = int.parse(line.substring(9));
    } else if (line.startsWith('UD_ERROR=')) {
      errors.add(jsonDecode(line.substring(9)) as String);
    } else if (line.startsWith('UD_SAMPLE=')) {
      samples.add(line.substring(10));
    } else if (line.startsWith('UD_ATTACH=')) {
      attachments.add(line.substring(10));
    } else if (line == 'UD_DONE') {
      done = true;
    }
  }
  expect(timedOut, isFalse, reason: 'the $seam/$mode child hung:\n$raw$err');
  expect(
    done,
    isTrue,
    reason:
        'the $seam/$mode child did not reach the end, so an absent error '
        'or an absent sample below would be a crash rather than a result:\n'
        '$raw$err',
  );
  expect(
    err.toString(),
    isNot(contains('ZDI_UNRESOLVED')),
    reason:
        'the injector could not resolve canon through the loaded library, '
        'so it degraded instead of measuring',
  );
  return (
    exitCode: code,
    fired: fired,
    errors: errors,
    samples: samples,
    attachments: attachments,
    raw: raw,
    stderr: err.toString(),
  );
}

void main() {
  group('[D1] S13 — an unconvertible value is an error', () {
    late Directory tmp;
    late String injector;

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('zd_d1_s13_');
      final built = await buildInjector(tmp);
      if (built == null) {
        markTestSkipped('clang unavailable — cannot build the injector');
      }
      injector = built ?? '';
    });
    tearDownAll(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('a failed payload conversion surfaces as an error, not empty bytes', () async {
      if (injector.isEmpty) return;
      final run = await runSeam('subscriber', 'armed', injector);
      expect(
        run.fired,
        1,
        reason:
            'the injector did not fire, so the branch under test was '
            'never entered and everything below is vacuous',
      );
      expect(run.errors, hasLength(1));
      expect(run.errors.single, contains('a payload'));
      expect(
        run.errors.single,
        contains('Z_EDESERIALIZE'),
        reason:
            "the rc is CANON'S OWN, passed through — no binding code is "
            'minted for this, because there is no rc channel here to allocate '
            'into and an invented number would mean nothing to anybody',
      );
      // ⛔ AND NO SAMPLE CARRYING EMPTY BYTES. That is the defect: it used to
      // be delivered as a successful, empty-payload sample.
      expect(
        run.samples,
        isNot(contains('""')),
        reason:
            'a sample with an empty payload was delivered for a value '
            'that failed to convert — which is exactly the old behaviour',
      );
    }, timeout: const Timeout(Duration(minutes: 4)));

    test(
      'a failed attachment conversion is not delivered as "no attachment"',
      () async {
        if (injector.isEmpty) return;
        final run = await runSeam('attachment', 'armed', injector);
        expect(run.fired, 1, reason: 'the injector did not fire');
        expect(run.errors, hasLength(1));
        expect(
          run.errors.single,
          contains('an attachment'),
          reason:
              'the payload converted and the ATTACHMENT failed; an error '
              'naming the payload would mean the skip did not reach the '
              'attachment branch at all',
        );
        // ⛔ THE ATTACHMENT IS LEGITIMATELY OPTIONAL, so a silent null conflates
        // a failure with a real value. Nothing may be delivered at all.
        expect(
          run.attachments,
          isEmpty,
          reason: 'the sample was delivered anyway: ${run.attachments}',
        );
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test('all four decode seams are covered', () async {
      if (injector.isEmpty) return;
      // ⛔ FOUR, and the fourth is the point: session.dart and querier.dart
      // parse the same reply post through independent code. A three-seam
      // implementation passes every other cell in this file.
      for (final seam in const [
        'subscriber',
        'queryable',
        'session-get',
        'querier-get',
      ]) {
        final run = await runSeam(seam, 'armed', injector);
        expect(run.fired, 1, reason: '$seam: the injector did not fire');
        expect(
          run.errors,
          isNotEmpty,
          reason:
              '$seam surfaced no error — this seam still delivers a '
              'failed conversion as data',
        );
        expect(run.errors.first, contains('could not convert'));
      }
    }, timeout: const Timeout(Duration(minutes: 12)));

    test('the success path is byte-identical in the same run', () async {
      if (injector.isEmpty) return;
      // ⛔ THE DISARMED ARM, and it is not a formality: the seed's Scope OUT
      // forbids any behavioural change to payloadBytes' success path, and an
      // earlier unit shipped a criterion asserting it unchanged. The injector
      // is PRESENT and merely disarmed, so this measures the same code path
      // the armed run used.
      final subscriber = await runSeam('subscriber', 'disarmed', injector);
      expect(subscriber.fired, 0);
      expect(subscriber.errors, isEmpty);
      expect(subscriber.samples, ['"PAYLOAD-ONE"', '"PAYLOAD-TWO"']);

      final attachment = await runSeam('attachment', 'disarmed', injector);
      expect(attachment.fired, 0);
      expect(attachment.errors, isEmpty);
      expect(attachment.samples, ['"WITH-ATTACHMENT"']);
      expect(attachment.attachments, ['"ATTACH-ONE"']);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('a conversion failure is a failed call, not a dead channel', () async {
      if (injector.isEmpty) return;
      // The shipped in-tree rule this follows rather than inventing one:
      // call failure -> error channel, stream continues; terminal state ->
      // result type. The armed subscriber run publishes a SECOND, good
      // payload after the window closes.
      final run = await runSeam('subscriber', 'armed', injector);
      expect(run.errors, hasLength(1));
      expect(
        run.samples,
        contains('"PAYLOAD-TWO"'),
        reason:
            'the subscriber stopped delivering after a conversion '
            'failure. A failed conversion is a failed CALL; terminating the '
            'channel would lose every later sample for one bad value',
      );
    }, timeout: const Timeout(Duration(minutes: 4)));

    // --- Edge cases ---

    test('legitimately empty and absent values are unchanged', () async {
      if (injector.isEmpty) return;
      // Empty is not absent and neither is a failure. The disarmed queryable
      // arm carries a real payload; the disarmed subscriber arm carries no
      // attachment at all and delivers normally.
      final run = await runSeam('queryable', 'disarmed', injector);
      expect(run.fired, 0);
      expect(run.errors, isEmpty);
      expect(run.samples, hasLength(1));
      expect(
        run.samples.single,
        isNot('[]'),
        reason:
            'the query payload came through empty with the injector '
            'disarmed, which would mean the success path itself is broken',
      );
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('the pin fact is asserted, so a moved pin becomes visible', () {
      // The branch is unreachable at THIS pin, and that is why an injector is
      // needed at all. If canon ever starts failing here, this cell goes red
      // and a reader learns the driver has become unnecessary rather than
      // discovering it by accident.
      final zbytes = File('../extern/zenoh-c/src/zbytes.rs').readAsStringSync();
      final at = zbytes.indexOf('pub unsafe extern "C" fn z_bytes_to_slice(');
      expect(at, greaterThanOrEqualTo(0));
      final body = zbytes.substring(at, at + 400);
      expect(
        body,
        contains('result::Z_OK'),
        reason: 'canon returns Z_OK unconditionally at this pin',
      );
      expect(
        body,
        isNot(contains('return Err')),
        reason:
            'a fallible arm appeared in canon; the injector may no longer '
            'be the only way to reach the branch',
      );

      // And the shim records the same fact where the branch lives.
      final shim = File('../src/zenoh_dart.c').readAsStringSync();
      expect(shim, contains('zbytes.rs:144-152'));
      expect(shim, contains('slice_fail_injector'));
    });

    test('the behaviour is stated at every affected surface', () {
      for (final path in const [
        'lib/src/subscriber.dart',
        'lib/src/queryable.dart',
        'lib/src/session.dart',
        'lib/src/querier.dart',
      ]) {
        final text = flattenedProse(path);
        // ⚠️ THE NEEDLE IS THE WHOLE SENTENCE, not a fragment. The first cut
        // used 'never an', which matched unrelated pre-existing prose in
        // three of the four files and only failed on the fourth — so it was
        // reporting three passes it had not earned. A claim check has to
        // match the claim.
        expect(
          text,
          contains('never as empty or absent data'),
          reason:
              '$path does not state that a value it cannot convert '
              'becomes an error rather than empty or absent data',
        );
        expect(
          text,
          contains('keeps running'),
          reason:
              '$path does not state that the stream survives the error, '
              'which is the half a reader needs in order to keep listening',
        );
      }
    });
  });
}
