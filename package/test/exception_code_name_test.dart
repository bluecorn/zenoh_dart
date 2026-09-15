// Seed [D1] slice 11 — `ZenohException` names canon's code, and stays honest
// where the numbering cannot.
//
// A reader who sees `-7` has to go looking. Canon names it `Z_EDESERIALIZE`,
// and this binding has had two file-local, provisional rc→name maps in
// `session.dart` whose own dartdoc names this accessor as their successor.
//
// ⛔ THREE CASES A NAIVE BIJECTION GETS WRONG, and each has an explicit,
// tested answer here rather than a convenient one:
//
//   1. A CODE WITH NO NAME. Canon does not define every integer, and the
//      accessor must invent nothing.
//   2. A CODE WITH TWO NAMES. `Z_EINVAL_MUTEX` and `Z_EPOISON_MUTEX` are BOTH
//      `-22`. A map keyed by number cannot render that honestly by picking
//      one, so the accessor returns a LIST and the collision becomes
//      type-level rather than a silent choice.
//   3. A BINDING-OWNED NUMBER CARRYING TWO MEANINGS. `12` is the shim's
//      allocation failure on the open channel AND trailing data on the
//      deserialize channel. Those are CHANNEL-SCOPED, and a number-keyed
//      global accessor structurally cannot render them — so it renders
//      neither, and says why.
import 'dart:io';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/session.dart';

/// See `open_detail_secrets_test.dart` for why prose is read flattened.
/// ⚠️ LOWERCASED, and needles must be lowercase too.
String flattenedProse(String path) =>
    File(path)
        .readAsStringSync()
        .replaceAll(RegExp(r'^\s*///?', multiLine: true), ' ')
        .replaceAll('*', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .toLowerCase();

/// Canon's error table, **parsed from the build-generated header at test
/// time**, in declaration order.
///
/// ⛔ NOT AN EMBEDDED COPY. A copy asserted against the code's own copy is
/// self-agreement: both would drift together and the cell would stay green
/// through a zenoh-c bump that renamed or added a code. The oracle has to be
/// the artefact the shim is actually compiled against.
///
/// The instrument, named beside the number it produces:
/// `awk '/^#define Z_E/ {print $2, $3}' <build-generated zenoh_concrete.h>`
List<({String name, int value})> canonErrorTable() {
  const header =
      '../build/linux-x64/extern/zenoh-c/release/include/zenoh_concrete.h';
  final table = <({String name, int value})>[];
  for (final line in File(header).readAsLinesSync()) {
    if (!line.startsWith('#define Z_E')) continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 3) continue;
    final raw = parts[2];
    // ⚠️ ONE ENTRY IS NOT A LITERAL. `Z_EGENERIC` is `INT8_MIN`, and
    // resolving it is a DECISION rather than a parse — so it is resolved
    // here, visibly, instead of being silently skipped by a
    // `int.tryParse ?? continue` that would drop it from the oracle and make
    // the exhaustiveness check weaker without saying so.
    final value = raw == 'INT8_MIN' ? -128 : int.tryParse(raw);
    if (value == null) {
      fail('unparsed canon code "$raw" in $line — the oracle must not drop it');
    }
    table.add((name: parts[1], value: value));
  }
  return table;
}

void main() {
  group('[D1] S11 — canon code names', () {
    test('a canon code renders its symbol alongside its number', () {
      final e = ZenohException('boom', -7);
      expect(e.codeNames, ['Z_EDESERIALIZE']);
      final rendered = e.toString();
      expect(rendered, contains('Z_EDESERIALIZE'));
      expect(
        rendered,
        contains('-7'),
        reason:
            'the symbol is ALONGSIDE the number, never in place of it: a '
            'reader matching on a code, or pasting one into a search, still '
            'needs the integer',
      );
      // ⛔ SUPERSET, checked as one. Today's exact rendering must survive
      // verbatim, or every shipped message assertion in the suite breaks.
      expect(rendered, startsWith('ZenohException: boom (code: -7)'));
    });

    test('the mapping is exhaustive against a parsed oracle', () {
      final table = canonErrorTable();
      expect(
        table,
        hasLength(14),
        reason:
            'canon defines 14 error names; the oracle read '
            '${table.length}, so either the header moved or the parse is '
            'dropping entries',
      );
      expect(
        table.map((e) => e.value).toSet(),
        hasLength(13),
        reason: '14 names over 13 distinct values — exactly one collision',
      );

      // Every value canon defines renders exactly canon's name set for it.
      for (final value in table.map((e) => e.value).toSet()) {
        final expected = table
            .where((e) => e.value == value)
            .map((e) => e.name)
            .toList();
        expect(
          ZenohException('x', value).codeNames,
          expected,
          reason: 'code $value should render $expected',
        );
      }
    });

    test('-22 renders both of its names, in canon declaration order', () {
      // The collision, made type-level. An accessor returning one name would
      // imply a precision the numbering does not have.
      final names = ZenohException('x', -22).codeNames;
      expect(names, ['Z_EINVAL_MUTEX', 'Z_EPOISON_MUTEX']);
      final rendered = ZenohException('x', -22).toString();
      expect(rendered, contains('Z_EINVAL_MUTEX'));
      expect(
        rendered,
        contains('Z_EPOISON_MUTEX'),
        reason:
            'rendering only the first would hide that canon aliases this '
            'number, which is the thing a reader needs to know',
      );

      // And the order is canon's, not alphabetical or insertion-by-accident.
      final table = canonErrorTable();
      final canonOrder = table
          .where((e) => e.value == -22)
          .map((e) => e.name)
          .toList();
      expect(names, canonOrder);
    });

    // --- Edge cases ---

    test('a code canon does not define yields no name', () {
      const undefined = -99;
      expect(canonErrorTable().map((e) => e.value), isNot(contains(undefined)));
      expect(ZenohException('x', undefined).codeNames, isEmpty);
      expect(
        ZenohException('x', undefined).toString(),
        'ZenohException: x (code: -99)',
        reason:
            'it degrades to exactly the shipped rendering, inventing '
            'nothing',
      );
    });

    test('a binding-owned positive yields no canon name, and the dartdoc says '
        'why', () {
      expect(ZenohException('x', 12).codeNames, isEmpty);
      expect(ZenohException('x', 11).codeNames, isEmpty);

      final doc = flattenedProse('lib/src/exceptions.dart');
      expect(doc, contains('channel-scoped'));
      expect(
        doc,
        contains('12'),
        reason:
            'the double meaning is ACCEPTED rather than resolved, so it '
            'has to be written down: 12 is the allocation failure on the open '
            'channel and trailing data on the deserialize channel',
      );
      expect(
        doc,
        contains('accepted'),
        reason:
            'an accepted collision recorded as a collision is honest; one '
            'left silent reads as an oversight',
      );
    });

    // --- Slice 12: the provisional maps in session.dart ---

    test('the open-failure rendering uses the general accessor for names', () {
      // The retirement, asserted at both ends: the message still names the
      // symbol, and the file-local map that used to supply it is gone.
      final message = openFailureMessage(-4, callerSuppliedConfig: true);
      expect(message, contains('Z_ENETWORK'));
      expect(message, contains('-4'));

      final session = File('lib/src/session.dart').readAsStringSync();
      expect(
        session,
        isNot(contains('_openErrorNames')),
        reason:
            'the provisional map named this accessor as its successor and '
            'existed to be deleted when it landed; leaving it would give the '
            'binding two rc->name tables that can drift apart',
      );
    });

    test('the open-specific qualification survives the retirement', () {
      // ⛔ WHAT THE ACCESSOR MUST NOT ABSORB. Canon defines NAMES, not
      // meanings, so a general accessor inventing "what -4 implies" would
      // assert semantics canon does not define. The qualification is
      // open-path-specific prose and stays open-path-local.
      final message = openFailureMessage(-4, callerSuppliedConfig: true);
      expect(message, contains('catch-all'));
      expect(
        message,
        contains('not specifically a network fault'),
        reason:
            'the catch-all covers every open failure, so the symbol '
            'alone sends a reader after a fault that may not exist',
      );
    });

    test('the start-failure codes keep their own rendering', () {
      // A start failure is a POSITIVE code raised synchronously -- nothing
      // ran, nothing is coming. A canon failure is a negative code on a
      // rejected future. The delivery channel discriminates and the sign
      // confirms it, so the two renderings must stay distinct.
      expect(openStartFailureMessage(12), contains('ZD_OPEN_EALLOC'));
      expect(openStartFailureMessage(13), contains('ZD_OPEN_ETHREAD'));
      expect(
        openStartFailureMessage(12),
        contains('never opened'),
        reason:
            'the start rendering says nothing was attempted, which the '
            'canon rendering must never say',
      );
      // And they are NOT canon names, deliberately: codeNames must not
      // suddenly start rendering them.
      expect(ZenohException('x', 12).codeNames, isEmpty);
      expect(ZenohException('x', 13).codeNames, isEmpty);
    });

    test('an unmapped canon code on the open path still degrades cleanly', () {
      // An rc z_open cannot actually produce. It carries the bare number with
      // no invented name, exactly as before the retirement.
      final message = openFailureMessage(-99, callerSuppliedConfig: false);
      expect(message, contains('-99'));
      expect(message, isNot(contains('Z_E')));
    });

    test('the two surviving maps record why they stay', () {
      final session = flattenedProse('lib/src/session.dart');
      // ⛔ ENACTED IS NOT RECORDED. A map that simply remained would read as
      // an oversight -- the same oversight the retired one was.
      expect(
        session,
        contains('defines error names, not meanings'),
        reason:
            '_openErrorMeanings stays local because a general accessor '
            'inventing meanings would assert semantics canon does not define',
      );
      expect(
        session,
        contains('channel-scoped'),
        reason:
            '_openStartFailures stays because the general accessor '
            'excludes binding-owned positives, and the reason is the same one '
            'that excludes them',
      );
    });

    test('canon channel states are not rendered as errors', () {
      // `Z_CHANNEL_DISCONNECTED` (1) and `Z_CHANNEL_NODATA` (2) are canon's,
      // but they are STATES rather than errors. The `!= 0` convention this
      // codebase applies everywhere else must not be applied to the recv
      // family, or a normal empty channel reads as a failure.
      expect(ZenohException('x', 1).codeNames, isEmpty);
      expect(ZenohException('x', 2).codeNames, isEmpty);

      final doc = flattenedProse('lib/src/exceptions.dart');
      expect(doc, contains('z_channel_nodata'));
      expect(
        doc,
        contains('recv'),
        reason:
            'the dartdoc must name WHERE the != 0 convention does not '
            'apply, or the warning is unactionable',
      );

      // And the oracle agrees these are outside the error table.
      final names = canonErrorTable().map((e) => e.name);
      expect(names, isNot(contains('Z_CHANNEL_DISCONNECTED')));
      expect(names, isNot(contains('Z_CHANNEL_NODATA')));
    });
  });
}
