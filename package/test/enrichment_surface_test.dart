// Seed [D1] slice 2 — the enrichment surface is defined, enumerated, and
// fenced against silent widening.
//
// ⛔ WHAT A FENCE IS FOR. The roadmap row's headline task was to enrich ~35
// more throw sites. Two independent bars stand in front of that, with
// different fixes: a wrong-attribution defect (closed by slice 1) and a
// secrets-echo defect (NOT closed — canon echoes the offending config value,
// its surrounding source line, and a caret under the offending token). This
// file makes the second bar mechanical: the surface cannot grow by one site
// without a cell going red and naming the precondition.
//
// ⚠️ LINE NUMBERS APPEAR IN PROSE ONLY, NEVER IN AN ASSERTION. Slice 4 of this
// same unit edits dartdoc at the very sites counted here, so a pinned-line
// assertion would be broken from inside the unit by its own dependent.
// File + pattern + count is the instrument.
import 'dart:io';

import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// THE DEFINITION, WRITTEN BEFORE THE COUNT
// ---------------------------------------------------------------------------
//
// An ENRICHED SITE is a throw or post site in `package/lib` whose
// `ZenohException` carries canon's own text for the failure being reported.
//
// ⛔ The obvious definition — "a call to the enriching factory" — is WRONG,
// and getting it wrong is a recorded defect in this unit's own seed: it cannot
// see the offloaded open path at all, which is exactly the path the security
// ruling this fence implements was about. There are TWO mechanisms, so there
// are two instruments:
//
//   (a) THE FACTORY — a call receiving the detail from the failing call in
//       caller-supplied storage, matched by the factory pattern below.
//   (b) THE POST — the offloaded `Session.open`, where the detail is captured
//       on the worker immediately after the failing call and marshalled WITH
//       the post, rendered as `. Zenoh says: `. It never calls the factory,
//       so instrument (a) is blind to it.
//
// A third mechanism was considered and DISSOLVED: "capture at site, read back
// later" is what slice 1 deleted. Nothing carries a detail that way any more.
//
// ⚠️ THE FACTORY'S OWN DECLARATION MATCHES PATTERN (a) AND IS NOT A SITE.
// That is why the census reads 4 and the call-site count is 3 — the two
// numbers are not a subset relation, and presenting one as "of which" was a
// recorded error.

/// Instrument (a). Matches calls **and** the declaration.
const _factoryPattern = 'ZenohException.enriched(';

/// Instrument (b). The posted-detail rendering.
const _postedPattern = 'Zenoh says:';

/// Instrument for the plain form, which is disjoint from (a): `ZenohException(`
/// cannot match `ZenohException.enriched(`, because the `.` sits between.
const _plainPattern = 'ZenohException(';

/// The fenced surface: file → expected count, for instrument (a).
const _expectedFactory = <String, int>{
  'lib/src/config.dart': 3,
  'lib/src/exceptions.dart': 1, // the declaration; not a site
  // ⚖️ ADDED 2026-09-02 by [SHM] shared-memory-lifetime, slice 8, and this
  // line IS the record of the decision rather than a note about it.
  //
  // The precondition below was met at the site, not waived. Canon's text for
  // the provider-creation failure was MEASURED to carry absolute filesystem
  // paths from inside the building developer's home directory -- so this
  // widening does echo host detail, and it ships anyway, with no redaction and
  // the reason stated at the throw: a general redactor is not implementable
  // where the shim receives one opaque string with no structure to redact
  // against, and a partial one manufactures confidence.
  //
  // What the site buys for that: canon answers all THREE provider-rejection
  // classes with the same -1, so without its text the one signal a caller gets
  // points away from the cause -- and the ceiling is the process's
  // RLIMIT_MEMLOCK, which moves.
  'lib/src/unstable/shm_provider.dart': 1,
};

/// The fenced surface for instrument (b).
const _expectedPosted = <String, int>{'lib/src/session.dart': 1};

/// The precondition any widening must clear, named in every violation.
const _wideningPrecondition =
    'widening the enrichment surface requires deciding REDACTION first: '
    'canon echoes the offending config value and its surrounding source line, '
    'including adjacent intact secrets, and prints a caret under the '
    'offending token';

/// Every `.dart` file under `package/lib`, keyed by its package-relative path.
///
/// ⚠️ RECURSIVE, and that is load-bearing. A non-recursive glob
/// (`lib/src/*.dart`) misses `lib/src/unstable/`'s eleven files and returns a
/// clean, wrong number — the instrument-cannot-see-its-own-domain defect this
/// unit's seed committed and then caught.
Map<String, String> libCorpus() {
  final corpus = <String, String>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    if (entity.path.endsWith('src/bindings.dart')) continue;
    corpus[entity.path] = entity.readAsStringSync();
  }
  return corpus;
}

/// Counts non-overlapping occurrences of [needle] in [haystack].
int countOf(String haystack, String needle) {
  var count = 0;
  var at = haystack.indexOf(needle);
  while (at >= 0) {
    count++;
    at = haystack.indexOf(needle, at + needle.length);
  }
  return count;
}

/// The fence. Returns one violation per file whose count is not the fenced
/// one, each naming the widening precondition rather than merely reporting a
/// number.
///
/// Pure over [corpus] so it can be run against a synthetic tree — a fence that
/// has never been shown to fail is not a fence.
List<String> fenceViolations(Map<String, String> corpus) {
  final violations = <String>[];
  for (final entry in <String, Map<String, int>>{
    _factoryPattern: _expectedFactory,
    _postedPattern: _expectedPosted,
  }.entries) {
    final pattern = entry.key;
    final expected = entry.value;
    final actual = <String, int>{};
    corpus.forEach((path, text) {
      final n = countOf(text, pattern);
      if (n > 0) actual[path] = n;
    });
    for (final path in {...expected.keys, ...actual.keys}) {
      final want = expected[path] ?? 0;
      final got = actual[path] ?? 0;
      if (want != got) {
        violations.add(
          '$path: expected $want occurrence(s) of "$pattern", found $got — '
          '$_wideningPrecondition',
        );
      }
    }
  }
  return violations;
}

void main() {
  group('[D1] S2 — the enrichment surface is fenced', () {
    test('the surface is exactly five sites, by file, pattern and count', () {
      final corpus = libCorpus();
      expect(
        fenceViolations(corpus),
        isEmpty,
        reason: 'the enrichment surface moved',
      );

      // Stated as absolutes too, so the totals are visible without running the
      // fence's own arithmetic in one's head.
      var factory = 0;
      var posted = 0;
      var plain = 0;
      corpus.forEach((_, text) {
        factory += countOf(text, _factoryPattern);
        posted += countOf(text, _postedPattern);
        plain += countOf(text, _plainPattern);
      });
      // ⚠️ 4 -> 5 at [SHM] slice 8, and the DELTA IS NAMED so the number stays
      // an instrument rather than a rubber stamp that gets bumped whenever it
      // goes red: `ShmProvider._create` is the new call site. If this goes red
      // again, find the delta BEFORE changing the number -- a site added
      // without a plan entry is exactly what this cell exists to catch, and
      // the precondition it guards (deciding redaction) is not waivable by
      // editing an integer.
      expect(factory, 5, reason: '4 call sites + 1 declaration');
      expect(posted, 1, reason: 'the offloaded open, and nothing else');
      // ⚠️ 103 -> 105 at this unit's close, and the DELTA IS NAMED so the
      // number stays an instrument: `undecodableError` and `session.dart`'s
      // `_canonNames` both construct a PLAIN exception. The fenced surface --
      // the enriched form -- did not move, which is the point: the census and
      // the fence answer different questions and only one of them is a gate.
      // ⚠️ 105 -> 104 at [SHM] slice 8, and the delta is the OTHER HALF of the
      // factory's 4 -> 5: `ShmProvider._create`'s throw was CONVERTED from the
      // plain form to the enriched one, so one site left this census as it
      // entered the other. ⭐ A conversion is the one delta shape that moves
      // both numbers at once, in opposite directions -- worth naming, because
      // a reader who saw only the factory rise would conclude a site had been
      // ADDED.
      // ⚠️ 104 -> 106 at [SHM] slice 10, and the DELTA IS NAMED, per the
      // instruction three comments up: `ShmProvider.allocGcDefragAsync`'s
      // carriage adds TWO plain sites, both required by the entry's contract
      // rather than incidental -- `_startAsync` throwing when the shim reports
      // that nothing started, and `_resultFromPost` throwing on canon's OK
      // status arriving with no buffer to take. ⭐ NEITHER IS A CANDIDATE FOR
      // THE ENRICHED FORM, which is why only this number moved: the fenced
      // surface is unchanged at 5 and 1. An enriched site must carry canon's
      // own text for the failure it reports, received from the very call it
      // reports; the first of these two carries a SHIM-minted code from a call
      // canon never saw, and the second reports a shim heap failure discovered
      // on a background thread, where there is no canon text to carry and no
      // redaction decision to make.
      // ⚠️ 106 -> 107 at [SHM] slice 11: close() now ANSWERS an outstanding
      // async request with a plain exception naming that the provider was
      // closed with it in flight. No canon detail exists to enrich from --
      // the condition is this binding's own -- so the plain form is right.
      //
      // ⛔⛔ AND THE WAY THIS WAS FOUND IS THE PART TO KEEP. This is the
      // SECOND time in one unit that the two censuses of this quantity
      // disagreed because ONE was updated and the other was not. The first
      // time, `diagnosability_baselines_test.dart` had been red since an
      // earlier slice and nobody saw it; it was written up, with the lesson
      // "a change's risk scope is the set of instruments calibrated on what
      // changed, not the set of files touched" -- and then the SAME author
      // updated that file to 107 and left THIS one at 106.
      //
      // ⭐ The rule stated in a document does not bind the next document, and
      // it plainly does not bind its own author either. ▶ So the two cells now
      // NAME EACH OTHER: if you are here changing this number, the sibling in
      // diagnosability_baselines_test.dart counts the same quantity with a
      // different instrument (an awk LINE count against this substring
      // OCCURRENCE count) and almost certainly needs the same change.
      expect(plain, 107, reason: 'the plain form, disjoint from the factory');
    });

    test("the fence's domain is stated, because conflating it with the "
        "sweep's is how a call site was missed", () {
      final exceptions = File('lib/src/exceptions.dart').readAsStringSync();
      expect(
        exceptions,
        contains('fence counts `package/lib`'),
        reason: "the fence's domain must be written down",
      );
      expect(
        exceptions,
        contains('config_test.dart'),
        reason:
            'the fifth call, outside the fence domain BY DESIGN, must be '
            'named — an impact sweep that assumed the fence covered the whole '
            'tree is how it was missed',
      );

      // And the claim is true: the fifth call exists, in the test tree.
      expect(
        countOf(
          File('test/config_test.dart').readAsStringSync(),
          _factoryPattern,
        ),
        greaterThanOrEqualTo(1),
        reason:
            'the documented fifth call must actually be there, or the '
            'documentation is describing a tree that does not exist',
      );
    });

    test(
      'one mechanism now carries all four sites, and the dartdoc says so',
      () {
        final exceptions = File('lib/src/exceptions.dart').readAsStringSync();
        expect(
          exceptions,
          contains('plain constructor carries nothing'),
          reason: 'the two-mechanism split must be stated where a caller reads',
        );
        expect(
          exceptions,
          contains('captures at the failing call'),
          reason: 'every detail-carrying path now does exactly this',
        );
        expect(
          exceptions,
          isNot(contains('durable buffer')),
          reason:
              'the dartdoc must no longer DESCRIBE a read-back as the '
              'mechanism; it may only record that one was deleted',
        );
      },
    );

    test('the census numbers are stated as two disjoint counts with their '
        'instruments', () {
      for (final path in const [
        'lib/src/exceptions.dart',
        '../src/zenoh_dart.c',
      ]) {
        final text = File(path).readAsStringSync();
        expect(text, contains('103'), reason: '$path omits the plain count');
        expect(
          text,
          contains('find package/lib -name'),
          reason:
              '$path states a number without the awk form that produced '
              'it — which is how a number becomes luck',
        );
        expect(
          text,
          contains('disjoint'),
          reason: '$path must say the two patterns cannot both match one site',
        );
        expect(
          text,
          contains('3 call sites'),
          reason:
              '$path must record that the 4 includes the declaration, so '
              'the call-site count is 3',
        );
      }
    });

    test('the deliberate non-adoptions are recorded, not silent', () {
      final exceptions = File('lib/src/exceptions.dart').readAsStringSync();
      // M5: scout's eligibility was VERIFIED in an earlier unit. Silence on it
      // is the disallowed outcome — it would be rediscovered and re-argued.
      expect(exceptions, contains('zd_scout'));
      expect(exceptions, contains('deliberately not adopted'));
      // zd_config_to_string: removed rather than promoted.
      expect(exceptions, contains('zd_config_to_string'));
      expect(exceptions, contains('removed rather than promoted'));
      // The two renderings, left un-unified because unification is not in
      // scope — recorded rather than left to look like an oversight.
      expect(exceptions, contains('not unified'));
      expect(exceptions, contains('Zenoh says'));
    });

    // --- Edge cases ---

    test('a newly added enriched call anywhere in package/lib fails the fence '
        'with the right reason', () {
      // ⛔ THE CALIBRATION. A fence that has only ever been run against a tree
      // it passes on has not been shown to be a fence at all.
      final synthetic = Map<String, String>.from(libCorpus());
      synthetic['lib/src/synthetic_widening.dart'] =
          'void f() { throw ZenohException.enriched("base", -1, null); }';

      final violations = fenceViolations(synthetic);
      expect(violations, hasLength(1));
      expect(violations.single, contains('lib/src/synthetic_widening.dart'));
      expect(
        violations.single,
        contains('REDACTION first'),
        reason:
            'the violation must name the PRECONDITION, not merely report '
            'a count mismatch — a reader who sees only "expected 0, found 1" '
            'will add the site to the expected map and move on',
      );

      // And the other direction: a site REMOVED is a violation too, so the
      // fence cannot be satisfied by deleting enrichment either.
      final shrunk = Map<String, String>.from(libCorpus())
        ..['lib/src/session.dart'] = '// nothing here';
      expect(fenceViolations(shrunk), isNotEmpty);
    });
  });
}
