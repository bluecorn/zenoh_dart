// The predefined MIME table is canon's, verified against canon.
//
// `Encoding` carries a table of predefined constants. Every entry is a claim
// about what canon calls that encoding, and until this file existed the only
// thing checking those claims was a hand-written list in `encoding_test.dart`
// transcribed from the same place the constants were. That kind of test proves
// the code agrees with itself and nothing more, which is why the table is
// generated from canon's own declarations and checked here against TWO
// independent canon-derived instruments:
//
//   * PRIMARY -- a runtime oracle. `helpers/encoding_constants_oracle.c` calls
//     all 53 `z_encoding_*(void)` accessors in the linked `libzenohc.so` and
//     prints what `z_encoding_to_string` renders for each. This is what canon
//     actually returns, not what canon says it returns.
//   * CONTROL -- the doc-line extraction over the pinned generated header.
//     Weaker evidence on its own: canon's own test suite asserts just 2 of the
//     53 documented alias strings. Its value is as a SECOND witness, and its
//     agreement with the runtime values is itself the control. Disagreement
//     between the two is a red, not a tie to be broken.
//
// Both instruments are variant-scoped through `helpers/canon_peer.dart`, so
// this file runs on both matrix legs. Measured at authoring: the unstable and
// stable header trees carry identical 53-entry alias sets, and all 53
// accessors are at guard depth 0.
//
// WHY 53 AND NOT 54. The accessor-declaration grep over the same header
// returns 54. The extra one is `z_encoding_loan_default`, a loan helper: its
// doc says "Returns a loaned default", it carries no `Constant alias for
// string:` line, and it returns the same value as `z_encoding_zenoh_bytes()`.
// It is excluded from the oracle's table.
import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/canon_peer.dart';

/// How many predefined encodings canon declares. Stated as a literal so a
/// silently-broken instrument that returns an empty set cannot pass as an
/// empty difference against another empty set.
const canonEncodingCount = 53;

/// The type under test, as source. Read relative to `package/`, which is the
/// working directory `dart test` runs from.
const encodingSourcePath = 'lib/src/encoding.dart';

/// Matches a predefined-constant DECLARATION, single-line or wrapped.
///
/// ⚠️ ANCHORED ON THE DECLARATION, deliberately. An unanchored
/// `Encoding\('[^']+'\)` also matches the file's own dartdoc, which cites
/// `Encoding('text/plain;utf-8')` and friends as examples -- measured, and it
/// silently inflates the constant set with strings that are not constants.
/// The `^  static const ` prefix is what excludes them, and the `\s*` runs
/// are what let a long declaration wrap without falling out of the instrument.
///
/// ⛔ WIDENED 2026-09-12, AND IT HAD GONE RED. The pattern allowed exactly one
/// wrap shape -- a break after `=`, with `Encoding('…');` contiguous:
///
///     static const applicationJavaSerializedObject =
///         Encoding('application/java-serialized-object');
///
/// Dart's tall formatter rewraps the same declaration the other way, putting
/// the argument on its own line with a trailing comma:
///
///     static const applicationJavaSerializedObject = Encoding(
///       'application/java-serialized-object',
///     );
///
/// Five constants took that shape and the instrument stopped seeing them.
/// ⭐ It was caught because [canonEncodingCount] is asserted as a literal
/// rather than derived from this scan -- the case that comment anticipated.
final declarationPattern = RegExp(
  r"^  static const ([a-zA-Z][A-Za-z0-9]*) =\s+Encoding\(\s*'([^']+)',?\s*\);",
  multiLine: true,
);

/// Matches canon's alias doc line.
///
/// ⚠️ THE BACKTICKS ARE LOAD-BEARING. The same pattern without them returns
/// ZERO matches against this header -- measured -- which reads exactly like
/// "canon carries no doc lines" rather than like a broken instrument. That is
/// why [canonEncodingCount] is asserted explicitly wherever this is used.
final aliasLinePattern = RegExp('Constant alias for string: `"([^"]+)"`');

/// A predefined constant as the SOURCE declares it: its MIME string and the
/// contiguous dartdoc block immediately above it.
typedef DeclaredConstant = ({String mime, String doc});

/// Every predefined constant declared in [encodingSourcePath].
Map<String, DeclaredConstant> declaredConstants() {
  final source = File(encodingSourcePath).readAsStringSync();
  final out = <String, DeclaredConstant>{};
  for (final match in declarationPattern.allMatches(source)) {
    final before = source.substring(0, match.start).trimRight().split('\n');
    final doc = <String>[];
    for (var i = before.length - 1; i >= 0; i--) {
      if (!before[i].trimLeft().startsWith('///')) break;
      doc.insert(0, before[i].trim());
    }
    out[match.group(1)!] = (mime: match.group(2)!, doc: doc.join('\n'));
  }
  return out;
}

/// Every predefined constant as the RUNTIME holds it: identifier -> mimeType,
/// read off the live objects rather than off the source text.
///
/// The source read above cannot distinguish a declaration from its value; this
/// one asks the constructed [Encoding] what its [Encoding.mimeType] actually
/// is, which is the property every send site uses.
Map<String, String> runtimeConstants() {
  final mirror = reflectClass(Encoding);
  final out = <String, String>{};
  mirror.declarations.forEach((symbol, declaration) {
    if (declaration is! VariableMirror) return;
    if (!declaration.isStatic || !declaration.isConst) return;
    final value = mirror.getField(symbol).reflectee;
    if (value is Encoding) out[MirrorSystem.getName(symbol)] = value.mimeType;
  });
  return out;
}

/// The MIME strings canon's generated header documents, for the loaded
/// variant.
///
/// No locale sort is involved: this is set membership in Dart, not `comm` over
/// two shell pipelines, so the `LC_ALL=C` the shell instrument needs to keep
/// its ordering trustworthy has no analogue here.
Set<String> canonDocLineMimes() {
  final header = File('$canonIncludeDir/zenoh_commons.h');
  if (!header.existsSync()) {
    fail('the pinned generated header is missing at ${header.path}');
  }
  return aliasLinePattern
      .allMatches(header.readAsStringSync())
      .map((m) => m.group(1)!)
      .toSet();
}

/// Runs the compiled oracle and returns accessor -> rendered MIME string.
Future<Map<String, String>> runOracle(String binary) async {
  final result = await Process.run(binary, const []);
  if (result.exitCode != 0) {
    fail(
      'the encoding oracle exited ${result.exitCode}\n'
      '--- stderr ---\n${result.stderr}',
    );
  }
  final out = <String, String>{};
  int? trailer;
  for (final line in const LineSplitter().convert('${result.stdout}')) {
    if (line.startsWith('ENC ')) {
      final rest = line.substring(4);
      final space = rest.indexOf(' ');
      out[rest.substring(0, space)] = rest.substring(space + 1);
    } else if (line.startsWith('ORACLE_COUNT ')) {
      trailer = int.parse(line.substring('ORACLE_COUNT '.length));
    }
  }
  expect(trailer, isNotNull, reason: 'the oracle printed no ORACLE_COUNT');
  expect(
    out.length,
    equals(trailer),
    reason: 'the oracle emitted ${out.length} lines but claims $trailer',
  );
  return out;
}

/// The two-sided difference between what canon has and what we ship, rendered
/// for a failure message -- or `null` when the two sets are equal.
///
/// Factored out and named so cell 5 can prove it able to REPORT a difference.
/// An empty difference from an instrument never shown to detect a non-empty
/// one is not evidence.
String? diffReport(Set<String> canon, Set<String> ours) {
  final missing = canon.difference(ours);
  final unknown = ours.difference(canon);
  if (missing.isEmpty && unknown.isEmpty) return null;
  final parts = <String>[];
  if (missing.isNotEmpty) {
    parts.add('missing from Encoding: ${_render(missing)}');
  }
  if (unknown.isNotEmpty) {
    parts.add('unknown to canon: ${_render(unknown)}');
  }
  return parts.join('; ');
}

String _render(Set<String> values) => (values.toList()..sort()).join(', ');

/// Canon's MIME string -> our identifier.
///
/// Split on `/`, `+` and `-`, then lowerCamelCase:
/// `application/octet-stream` -> `applicationOctetStream`,
/// `application/json-patch+json` -> `applicationJsonPatchJson`.
///
/// ⚠️ LOSSY: all three separators fold to the same word boundary, so the
/// transform does NOT round-trip -- `applicationJsonPatchJson` cannot be
/// mapped back to its MIME string. That is why every constant's dartdoc has to
/// carry the MIME string itself, asserted below.
String deriveIdentifier(String mime) {
  final words = mime.split(RegExp('[/+-]')).where((w) => w.isNotEmpty).toList();
  final tail = words.skip(1).map((w) => w[0].toUpperCase() + w.substring(1));
  return words.first.toLowerCase() + tail.join();
}

/// Dart's reserved words: the identifiers the grammar forbids outright.
///
/// The PRIMARY proof that no derived name is one of these is that
/// `encoding.dart` compiles at all -- a reserved word there is a parse error,
/// not a failing assertion. This list makes the check explicit anyway, so the
/// property is stated where the derivation is, rather than left implicit in
/// the build.
const dartReservedWords = {
  'assert',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
};

/// The ten constants that shipped before the table was completed, with the
/// MIME strings they shipped with. Named here so cell 4 can assert that the
/// additive expansion renamed nothing and revalued nothing.
const shippedTen = <String, String>{
  'zenohBytes': 'zenoh/bytes',
  'zenohString': 'zenoh/string',
  'textPlain': 'text/plain',
  'applicationJson': 'application/json',
  'applicationOctetStream': 'application/octet-stream',
  'applicationProtobuf': 'application/protobuf',
  'textHtml': 'text/html',
  'textCsv': 'text/csv',
  'imagePng': 'image/png',
  'imageJpeg': 'image/jpeg',
};

void main() {
  group("Predefined encodings are canon's 53, verified against canon", () {
    late Directory tmp;
    late Set<String> oracleMimes;
    late Set<String> docLineMimes;
    late Map<String, String> runtime;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('seed10_enc_oracle_');
      final binary = await buildCanonPeer(
        'test/helpers/encoding_constants_oracle.c',
        tmp,
        'encoding_constants_oracle',
      );
      oracleMimes = (await runOracle(binary)).values.toSet();
      docLineMimes = canonDocLineMimes();
      runtime = runtimeConstants();
    });

    tearDownAll(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    // 1. The primary instrument.
    test('every constant matches the value canon returns at runtime', () {
      expect(
        oracleMimes.length,
        equals(canonEncodingCount),
        reason:
            'the oracle should render $canonEncodingCount distinct MIME '
            'strings; a different number means the accessor table drifted',
      );
      expect(
        diffReport(oracleMimes, runtime.values.toSet()),
        isNull,
        reason:
            'Encoding must carry exactly the predefined encodings canon '
            'returns -- no missing constant, no invented one',
      );
      expect(runtime.length, equals(canonEncodingCount));
    });

    // 2. The control instrument, asserted non-empty in its own right.
    test('every constant matches the MIME string canon documents', () {
      expect(
        docLineMimes.length,
        equals(canonEncodingCount),
        reason:
            'the doc-line extraction returned ${docLineMimes.length} '
            'strings, not $canonEncodingCount -- the pattern is broken, and a '
            'broken pattern would otherwise pass as an empty difference',
      );
      expect(diffReport(docLineMimes, runtime.values.toSet()), isNull);
    });

    // 3. The two witnesses against each other.
    test('the runtime oracle and the doc lines agree with each other', () {
      expect(
        diffReport(oracleMimes, docLineMimes),
        isNull,
        reason:
            'canon returns one set of strings and documents another; '
            'neither instrument can be trusted until that is resolved',
      );
    });

    // 4. The additive-expansion regression guard.
    test(
      'the ten previously shipped constants keep their names and values',
      () {
        expect(Encoding.zenohBytes.mimeType, equals('zenoh/bytes'));
        expect(Encoding.zenohString.mimeType, equals('zenoh/string'));
        expect(Encoding.textPlain.mimeType, equals('text/plain'));
        expect(Encoding.applicationJson.mimeType, equals('application/json'));
        expect(
          Encoding.applicationOctetStream.mimeType,
          equals('application/octet-stream'),
        );
        expect(
          Encoding.applicationProtobuf.mimeType,
          equals('application/protobuf'),
        );
        expect(Encoding.textHtml.mimeType, equals('text/html'));
        expect(Encoding.textCsv.mimeType, equals('text/csv'));
        expect(Encoding.imagePng.mimeType, equals('image/png'));
        expect(Encoding.imageJpeg.mimeType, equals('image/jpeg'));

        // ...and the same ten as the runtime sees them, so a rename that left a
        // deprecated alias behind would still be caught.
        for (final entry in shippedTen.entries) {
          expect(
            runtime[entry.key],
            equals(entry.value),
            reason:
                '${entry.key} must still be declared and still mean '
                '"${entry.value}"',
          );
        }
      },
    );

    // 5. The comparator's own control. Without it an empty difference in cells
    // 1-3 proves only that the comparator is silent.
    test('the comparator reports a difference when there is one', () {
      final fake = {...oracleMimes, 'not/a-real-mime'};

      final weHaveOneExtra = diffReport(oracleMimes, fake);
      expect(weHaveOneExtra, isNotNull);
      expect(weHaveOneExtra, contains('not/a-real-mime'));
      expect(weHaveOneExtra, contains('unknown to canon'));

      final weAreMissingOne = diffReport(fake, oracleMimes);
      expect(weAreMissingOne, isNotNull);
      expect(weAreMissingOne, contains('not/a-real-mime'));
      expect(weAreMissingOne, contains('missing from Encoding'));

      // ...and it is still silent when the two sets really are equal, so the
      // cell is not green merely because the comparator shouts at everything.
      expect(diffReport(oracleMimes, {...oracleMimes}), isNull);
    });

    // 6. The naming rule, and the documentation the rule makes necessary.
    test('the identifier derivation is total, collision-free and documented', () {
      final derived = <String, String>{};
      for (final mime in oracleMimes) {
        final identifier = deriveIdentifier(mime);
        expect(
          derived.containsKey(identifier),
          isFalse,
          reason:
              '"$mime" and "${derived[identifier]}" both derive '
              '"$identifier" -- the transform is not collision-free',
        );
        derived[identifier] = mime;
      }
      expect(derived.length, equals(canonEncodingCount));

      for (final identifier in derived.keys) {
        expect(
          identifier,
          matches(RegExp(r'^[a-z][A-Za-z0-9]*$')),
          reason: '"$identifier" is not a lowerCamelCase Dart identifier',
        );
        expect(
          dartReservedWords.contains(identifier),
          isFalse,
          reason: '"$identifier" is a Dart reserved word',
        );
      }

      // The shipped names ARE that derivation -- not merely compatible with
      // it. This is what makes the table checkable rather than curated.
      final declared = declaredConstants();
      expect(declared.keys.toSet(), equals(derived.keys.toSet()));
      for (final entry in derived.entries) {
        expect(declared[entry.key]?.mime, equals(entry.value));
        expect(runtime[entry.key], equals(entry.value));
      }

      // The transform does not round-trip, so the MIME string has to appear in
      // the dartdoc or the reader cannot recover it from the name.
      for (final entry in declared.entries) {
        expect(
          entry.value.doc,
          contains(entry.value.mime),
          reason:
              '${entry.key} has no MIME string in its dartdoc, and '
              '"${entry.value.mime}" cannot be recovered from the name',
        );
      }
    });

    // 7. The harness fails loud rather than skipping. A skipped oracle is
    // indistinguishable from a working one, and this oracle is the only thing
    // standing between the table and a silent transcription error.
    test('the oracle fails loud when the canon headers are absent', () {
      expect(
        () => requireCanonHeaders('/nonexistent/build/tree/include'),
        throwsA(
          isA<TestFailure>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('/nonexistent/build/tree/include'),
              contains('cmake --preset'),
              contains('--target install'),
            ),
          ),
        ),
      );

      // ...and it passes for the real one, so the cell above is not green
      // merely because the guard rejects everything.
      requireCanonHeaders();
    });
  });
}
