import 'dart:convert';

import 'package:test/test.dart';
// The public surface only: every member this file exercises must be reachable
// the way a consumer reaches it, not through `src/`.
import 'package:zenoh_dart/zenoh.dart';

import 'helpers/poll.dart';

// ---------------------------------------------------------------------------
// The shared fixture table (seed #4).
//
// Every expected value below was MEASURED through canon's own entries at the
// plan gate -- never derived from a source read, and never computed by the
// function under test. The classes are consumed by every group in this file,
// which is why they live at the top rather than being duplicated per group.
//
// `$` is Dart's interpolation sigil, so every vector carrying a `$*` is a raw
// string. Interior-NUL vectors are spelled with the `\x00` escape (see the
// fidelity group) -- no repo file may contain a raw NUL byte, which would make
// `grep` classify the file as binary and suppress every match in it.
// ---------------------------------------------------------------------------

/// Key expressions already in canon form: canon rewrites none of them.
///
/// Measured: `z_keyexpr_is_canon` rc 0, `z_keyexpr_canonize` identity at
/// unchanged length, and the strict constructor accepts each byte-exact.
const canonVectors = <String>[
  'a/**/c',
  r'hello/foo$*/bar',
  'hello/**',
  'hello/*/bye',
  '*/hello/*/bye/*',
  'hello/*/**',
  'demo/example/test',
];

/// Non-canon but canonizable input, mapped to its MEASURED canonized output.
///
/// Each key is rejected by the strict constructor (rc -1) and each value is
/// what `z_keyexpr_canonize` produced for it. The last two entries are the
/// **length-preserving** rewrites (`**/*` -> `*/**`): the byte count does not
/// change, which is what makes the out-length load-bearing rather than
/// something a renderer may assume shrinks.
const canonizableVectors = <String, String>{
  'a/**/**/c': 'a/**/c',
  r'hello/foo$*$*/bar': r'hello/foo$*/bar',
  'hello/**/**': 'hello/**',
  'hello/**/**/bye': 'hello/**/bye',
  r'hello/$*/bye': 'hello/*/bye',
  r'$*$*$*/hello/$*$*/bye/$*$*': '*/hello/*/bye/*',
  'hello/**/*': 'hello/*/**',
  'demo/example/**/*': 'demo/example/*/**',
};

/// Input canon rejects outright -- invalid even after canonization.
///
/// Measured rc -1 on all four canon entries. The empty string belongs to this
/// class behaviourally but is kept out of the list and pinned as its own
/// length-0 boundary leg, because it is the one vector whose marshalling (a
/// non-null pointer with length 0) is itself the thing under test.
const invalidVectors = <String>[
  '/a/b',
  'a/b/',
  'a//b',
  'a?b',
  'a#b',
  r'a$b',
  r'a/b/*$*',
  r'a/b/$**',
  r'a/b/**$**',
  'x*/y',
  '**a',
  r'a/b/**$*',
  r'a/b/*$**',
  r'a/b/*$***',
  r'a/b/**$***',
  '/a/b/',
];

/// Interior-NUL key expressions measured to be already in CANON form.
///
/// The key expression grammar forbids `//`, a leading or trailing `/` and the
/// characters `?#$` -- it does not forbid NUL, and canon accepts one as an
/// ordinary chunk byte. Spelled with the `\x00` escape, never a raw NUL byte.
const nulCanonVectors = <String>['a\x00b', 'a/\x00/c'];

/// Interior-NUL key expressions that are non-canon, with the measured rewrite.
///
/// Canonization rewrites *around* the NUL and the NUL survives in position.
const nulCanonizableVectors = <String, String>{
  'a\x00b/**/**/c': 'a\x00b/**/c',
  'a\x00b/**/*': 'a\x00b/*/**',
};

/// Non-ASCII key expressions measured to be already in CANON form.
///
/// Construction and validation only -- see the fidelity group for why no
/// session operation may be performed on any of these.
const nonAsciiCanonVectors = <String>['例/data', 'demo/例'];

/// Non-ASCII non-canon key expressions, with the measured canonized output.
///
/// The rewrites operate on `/`-delimited chunks and ASCII metacharacters, so
/// no multi-byte character is ever split.
const nonAsciiCanonizableVectors = <String, String>{
  '例/**/**/data': '例/**/data',
  'café/**/*': 'café/*/**',
};

/// A Dart string carrying a lone surrogate -- the encode boundary.
///
/// `utf8.encode` substitutes U+FFFD **before** canon sees the bytes (measured
/// `[97, 239, 191, 189, 98]`), so every entry point judges and transforms the
/// substituted bytes. A read-back is therefore byte-identical to what canon
/// received and *not* `String`-identical to this input.
const loneSurrogate = 'a\uD800b';

/// The substituted form the encode boundary actually reaches canon as.
///
/// Built from the code point rather than pasted, so the expectation cannot
/// drift with an editor's encoding.
final String substitutedSurrogate = 'a${String.fromCharCode(0xFFFD)}b';

/// Matches a [ZenohException] carrying canon's `Z_EINVAL` (-1).
///
/// Canon's whole canonization family returns only `0`, `-1` and `-2`, and it
/// does not discriminate invalid from merely-non-canon: both are `-1`. Tests
/// assert that collapsed code and never invent a finer taxonomy.
final Matcher throwsCanonEinval = throwsA(
  isA<ZenohException>().having((e) => e.returnCode, 'returnCode', -1),
);

void main() {
  // Slice 1 -- the inherited RED, discharged.
  //
  // These are green-on-write PINS, not red-first tests: the strict
  // constructor's rejection behaviour is already correct at HEAD (re-measured
  // at the plan gate). Nothing here manufactures a red leg. Their value is
  // that a regression to silent acceptance -- or to silent canonization --
  // becomes visible to the suite, which is precisely the coverage defect the
  // corpus audit homed to this seed.
  group('KeyExpr strict constructor -- fixture-table pins', () {
    test('every canon vector constructs with a byte-exact read-back', () {
      for (final expr in canonVectors) {
        final ke = KeyExpr(expr);
        expect(
          utf8.encode(ke.value),
          equals(utf8.encode(expr)),
          reason: 'canon vector "$expr" must read back byte-exact',
        );
        ke.dispose();
      }
    });

    test('every canonizable vector is REJECTED by the strict door', () {
      // The strict constructor never silently accepts a non-canon expression,
      // and never silently canonizes one. Canon collapses "invalid" and
      // "merely non-canon" to the same -1, so this reads identically to the
      // invalid class below -- by canon's design, not by our flattening.
      for (final expr in canonizableVectors.keys) {
        expect(
          () => KeyExpr(expr),
          throwsCanonEinval,
          reason: 'expected Z_EINVAL for non-canon "$expr"',
        );
      }
    });

    test('every invalid vector is rejected with canon own code', () {
      for (final expr in invalidVectors) {
        expect(
          () => KeyExpr(expr),
          throwsCanonEinval,
          reason: 'expected Z_EINVAL for invalid "$expr"',
        );
      }
    });

    test('the empty string is rejected, and is the length-0 boundary', () {
      // The marshalling layer still hands canon a non-null 1-byte buffer here
      // (`_copyToNative` mallocs `len + 1`). That is what keeps canon's
      // missing NULL guard on `z_keyexpr_is_canon` out of reach -- so this leg
      // asserts the rejection AND that the process survives to assert it.
      expect(() => KeyExpr(''), throwsCanonEinval);
    });

    test('the fixture table itself is internally consistent', () {
      // A self-guard: without it, a table drift could make a later criterion
      // vacuously true (an empty class passes every "for each" assertion).
      expect(canonVectors, isNotEmpty);
      expect(canonizableVectors, isNotEmpty);
      expect(invalidVectors, isNotEmpty);

      final canon = canonVectors.toSet();
      final canonizable = canonizableVectors.keys.toSet();
      final invalid = invalidVectors.toSet();

      expect(canon.length, canonVectors.length, reason: 'canon has a dup');
      expect(invalid.length, invalidVectors.length, reason: 'invalid dup');
      expect(canon.intersection(canonizable), isEmpty);
      expect(canon.intersection(invalid), isEmpty);
      expect(canonizable.intersection(invalid), isEmpty);
      expect(canon, isNot(contains('')));
      expect(canonizable, isNot(contains('')));
      expect(invalid, isNot(contains('')));

      // Every canonized OUTPUT is genuinely canon-accepted. Asserting instead
      // that the canon class *contains* each output would be false against
      // these very constants -- `hello/**/bye` and `demo/example/*/**` are
      // outputs but not members of the seven-vector canon class -- and it is
      // the construct-through-strict property the guard actually wants.
      for (final output in canonizableVectors.values) {
        final ke = KeyExpr(output);
        expect(
          utf8.encode(ke.value),
          equals(utf8.encode(output)),
          reason: 'canonized output "$output" must be canon-accepted',
        );
        ke.dispose();
      }
    });
  });

  // Slice 2 -- the total truth function.
  group('KeyExpr.isCanon', () {
    test('is true on every canon vector', () {
      for (final expr in canonVectors) {
        expect(KeyExpr.isCanon(expr), isTrue, reason: 'canon "$expr"');
      }
    });

    test('is false on every canonizable vector', () {
      // Merely-non-canon reads as `false`. That is canon's own
      // non-discrimination -- it returns -1 for invalid and for non-canon
      // alike -- not a flattening this binding invented.
      for (final expr in canonizableVectors.keys) {
        expect(KeyExpr.isCanon(expr), isFalse, reason: 'non-canon "$expr"');
      }
    });

    test('is false on every invalid vector', () {
      for (final expr in invalidVectors) {
        expect(KeyExpr.isCanon(expr), isFalse, reason: 'invalid "$expr"');
      }
    });

    test('never throws, on any input in the table', () {
      // Totality is the whole point of the predicate: it is what makes it
      // usable instead of construct-and-catch, so the domain swept here is
      // the contract's, not the ASCII subset the examples use.
      final everything = <String>[
        ...canonVectors,
        ...canonizableVectors.keys,
        ...canonizableVectors.values,
        ...invalidVectors,
        ...nulCanonVectors,
        ...nulCanonizableVectors.keys,
        ...nonAsciiCanonVectors,
        ...nonAsciiCanonizableVectors.keys,
        loneSurrogate,
        '',
      ];
      for (final expr in everything) {
        expect(
          () => KeyExpr.isCanon(expr),
          returnsNormally,
          reason: 'isCanon must be total, and was not for "$expr"',
        );
      }
    });

    test('agrees exactly with the strict constructor', () {
      // The discriminator against a rendering that returned `rc != 0`, or
      // that swallowed the non-canon case: `true` precisely when the strict
      // door constructs.
      final everything = <String>[
        ...canonVectors,
        ...canonizableVectors.keys,
        ...invalidVectors,
        '',
      ];
      for (final expr in everything) {
        var constructs = false;
        try {
          KeyExpr(expr).dispose();
          constructs = true;
        } on ZenohException {
          constructs = false;
        }
        expect(
          KeyExpr.isCanon(expr),
          equals(constructs),
          reason: 'isCanon disagreed with KeyExpr() for "$expr"',
        );
      }
    });

    test('the empty string returns false rather than throwing', () {
      // Marshalled as a non-null pointer with length 0 -- the guard that
      // keeps canon's missing NULL check on this entry unreachable.
      expect(KeyExpr.isCanon(''), isFalse);
    });
  });

  // Slice 3 -- the pure transform.
  group('KeyExpr.canonize', () {
    test('is byte-exact identity on every canon vector', () {
      for (final expr in canonVectors) {
        expect(
          utf8.encode(KeyExpr.canonize(expr)),
          equals(utf8.encode(expr)),
          reason: 'canonize must not touch canon input "$expr"',
        );
      }
    });

    test('maps every canonizable vector to its measured output', () {
      canonizableVectors.forEach((input, expected) {
        expect(
          utf8.encode(KeyExpr.canonize(input)),
          equals(utf8.encode(expected)),
          reason: '"$input" must canonize to "$expected"',
        );
      });
    });

    test('honors the out-length on the length-PRESERVING rewrites', () {
      // `**/*` reorders to `*/**` at the same byte count. Together with the
      // shortening vectors above, this is what pins that the out-length is
      // READ rather than assumed: a rendering that carried the input length
      // would pass here and ship trailing NULs on every shortening vector,
      // and one that assumed shortening would truncate here.
      expect(utf8.encode(KeyExpr.canonize('hello/**/*')), hasLength(10));
      expect(KeyExpr.canonize('hello/**/*'), equals('hello/*/**'));
      expect(
        utf8.encode(KeyExpr.canonize('demo/example/**/*')),
        hasLength(17),
      );
      expect(
        KeyExpr.canonize('demo/example/**/*'),
        equals('demo/example/*/**'),
      );
    });

    test('throws only where canon errors', () {
      for (final expr in invalidVectors) {
        expect(
          () => KeyExpr.canonize(expr),
          throwsCanonEinval,
          reason: 'expected Z_EINVAL canonizing invalid "$expr"',
        );
      }
    });

    test('never throws on a canonizable input', () {
      // The exact inputs the strict constructor rejects. This is the member's
      // whole purpose, and the discriminator against a rendering that merely
      // re-validated instead of rewriting.
      for (final expr in canonizableVectors.keys) {
        expect(
          () => KeyExpr.canonize(expr),
          returnsNormally,
          reason: 'canonize must succeed on non-canon "$expr"',
        );
      }
    });

    test('composes with the strict constructor, and is idempotent', () {
      for (final input in canonizableVectors.keys) {
        final once = KeyExpr.canonize(input);

        final ke = KeyExpr(once);
        expect(utf8.encode(ke.value), equals(utf8.encode(once)));
        ke.dispose();

        expect(
          utf8.encode(KeyExpr.canonize(once)),
          equals(utf8.encode(once)),
          reason: 'canonize must be idempotent for "$input"',
        );
      }
    });

    test('the empty string throws rather than returning empty', () {
      // An empty return would be a silent-default substitution -- the class
      // of forbidden transform this seed exists to keep off the new paths.
      expect(() => KeyExpr.canonize(''), throwsCanonEinval);
    });

    test('a repeated call on the same input is independent', () {
      const input = 'a/**/**/c';
      expect(
        utf8.encode(KeyExpr.canonize(input)),
        equals(utf8.encode(KeyExpr.canonize(input))),
      );
    });
  });

  // Slice 4 -- the additive factory.
  group('KeyExpr.autocanonize', () {
    test('constructs through the rewrite', () {
      for (final input in canonizableVectors.keys) {
        final ke = KeyExpr.autocanonize(input);
        expect(
          utf8.encode(ke.value),
          equals(utf8.encode(KeyExpr.canonize(input))),
          reason: 'autocanonize("$input") must read back canonized',
        );
        ke.dispose();
      }
    });

    test('the product is semantically the canonized expression', () {
      for (final input in canonizableVectors.keys) {
        final product = KeyExpr.autocanonize(input);
        final peer = KeyExpr(KeyExpr.canonize(input));
        expect(product.equals(peer), isTrue, reason: 'for "$input"');
        peer.dispose();
        product.dispose();
      }
    });

    test('the out-length is honored, not assumed', () {
      // Two shortening vectors and two length-preserving ones. A rendering
      // that carried the INPUT length would over-read on the shorteners while
      // passing the preservers, which is why both classes are here.
      const vectors = <String>[
        'a/**/**/c',
        r'$*$*$*/hello/$*$*/bye/$*$*',
        'hello/**/*',
        'demo/example/**/*',
      ];
      for (final input in vectors) {
        final ke = KeyExpr.autocanonize(input);
        expect(
          utf8.encode(ke.value).length,
          equals(utf8.encode(KeyExpr.canonize(input)).length),
          reason: 'byte length disagreed for "$input"',
        );
        ke.dispose();
      }
    });

    test('is indistinguishable from the strict door on canon input', () {
      for (final expr in canonVectors) {
        final viaFactory = KeyExpr.autocanonize(expr);
        final viaStrict = KeyExpr(expr);
        expect(
          utf8.encode(viaFactory.value),
          equals(utf8.encode(viaStrict.value)),
          reason: 'for canon "$expr"',
        );
        expect(viaStrict.dispose, returnsNormally);
        expect(viaFactory.dispose, returnsNormally);
      }
    });

    test('rejects what the strict door rejects, with the same exception', () {
      // Invalid-despite-canonization is still invalid, and it surfaces as the
      // same exception class carrying the same code -- a consumer switching
      // doors does not have to switch catch clauses.
      for (final expr in invalidVectors) {
        expect(
          () => KeyExpr.autocanonize(expr),
          throwsCanonEinval,
          reason: 'expected Z_EINVAL for invalid "$expr"',
        );
        expect(() => KeyExpr(expr), throwsCanonEinval);
      }
    });

    test('rejects the empty string too', () {
      expect(() => KeyExpr.autocanonize(''), throwsCanonEinval);
    });

    test('invents no "was canonized" signal', () {
      // Canon returns no such flag, so neither does this. The only way to
      // know is to compare the product against the input -- which is exactly
      // canon's own information content, no more and no less.
      final untouched = KeyExpr.autocanonize('a/**/c');
      expect(untouched.value, equals('a/**/c'));
      untouched.dispose();

      final rewritten = KeyExpr.autocanonize('a/**/**/c');
      expect(rewritten.value, isNot(equals('a/**/**/c')));
      expect(rewritten.value, equals('a/**/c'));
      rewritten.dispose();
    });
  });

  // Slice 5 -- fidelity over the CONTRACT's domain, not the ASCII subset the
  // examples happen to use.
  //
  // Structural parity is not sufficient here: a `canonize` that truncated at
  // a NUL, or re-encoded its output, would type-check and pass every shape
  // review while breaking the value contract. Each leg below names what the
  // broken rendering would have produced, so a green is a real negative
  // rather than an assertion that could pass either way.
  //
  // Construction and validation ONLY -- no session operation is performed on
  // any vector in this group. See the non-ASCII leg for why.
  group('KeyExpr canonization fidelity', () {
    test('interior NUL: the canon vectors are identity through all three', () {
      for (final expr in nulCanonVectors) {
        final bytes = utf8.encode(expr);
        expect(KeyExpr.isCanon(expr), isTrue, reason: 'NUL canon "$expr"');

        // Truncation at the NUL would come back as 1 byte here.
        expect(utf8.encode(KeyExpr.canonize(expr)), equals(bytes));

        final ke = KeyExpr.autocanonize(expr);
        expect(utf8.encode(ke.value), equals(bytes));
        ke.dispose();
      }
      expect(utf8.encode(KeyExpr.canonize('a\x00b')), hasLength(3));
      expect(utf8.encode(KeyExpr.canonize('a/\x00/c')), hasLength(5));
    });

    test('interior NUL: the canonizable vectors take the measured rewrite', () {
      nulCanonizableVectors.forEach((input, expected) {
        final expectedBytes = utf8.encode(expected);
        expect(KeyExpr.isCanon(input), isFalse);

        // The NUL survives in position while canon rewrites around it.
        expect(
          utf8.encode(KeyExpr.canonize(input)),
          equals(expectedBytes),
          reason: 'rewrite around the NUL differed for "$input"',
        );

        final ke = KeyExpr.autocanonize(input);
        expect(utf8.encode(ke.value), equals(expectedBytes));
        ke.dispose();
      });
      // The collapse and the reorder, at their measured byte counts.
      expect(utf8.encode(KeyExpr.canonize('a\x00b/**/**/c')), hasLength(8));
      expect(utf8.encode(KeyExpr.canonize('a\x00b/**/*')), hasLength(8));
    });

    test('non-ASCII, at construction level only', () {
      // ⚠️ Deliberately no session operation on any of these. Canon's
      // VALIDATOR accepts non-ASCII -- the domain is UTF-8 by design -- but
      // zenoh 1.8.0's routing layer panics and aborts the process on a
      // multi-byte first chunk. These three services are construction and
      // validation only, which is why they are safe here and why this group
      // adds no delivery leg.
      for (final expr in nonAsciiCanonVectors) {
        expect(KeyExpr.isCanon(expr), isTrue, reason: 'canon "$expr"');
        expect(
          utf8.encode(KeyExpr.canonize(expr)),
          equals(utf8.encode(expr)),
        );
        final ke = KeyExpr.autocanonize(expr);
        expect(utf8.encode(ke.value), equals(utf8.encode(expr)));
        ke.dispose();
      }

      nonAsciiCanonizableVectors.forEach((input, expected) {
        expect(KeyExpr.isCanon(input), isFalse);
        expect(
          utf8.encode(KeyExpr.canonize(input)),
          equals(utf8.encode(expected)),
          reason: '"$input" must canonize to "$expected"',
        );
        final ke = KeyExpr.autocanonize(input);
        expect(utf8.encode(ke.value), equals(utf8.encode(expected)));
        ke.dispose();
      });

      // No multi-byte character was split: the rewritten forms still decode,
      // and their byte counts are the measured ones.
      expect(utf8.encode(KeyExpr.canonize('例/**/**/data')), hasLength(11));
      expect(utf8.encode(KeyExpr.canonize('café/**/*')), hasLength(10));
    });

    test('the empty string behaves per member, measured not generalized', () {
      expect(KeyExpr.isCanon(''), isFalse);
      expect(() => KeyExpr.canonize(''), throwsCanonEinval);
      expect(() => KeyExpr.autocanonize(''), throwsCanonEinval);
    });

    test('the encode boundary: a lone surrogate substitutes before canon', () {
      // `utf8.encode` replaces the lone surrogate with U+FFFD BEFORE canon
      // sees any bytes, so every entry point judges and transforms the
      // substituted form. Identity therefore holds at the BYTE level and not
      // at the `String` level -- this is the one fixture where the two
      // readings differ, and it is measured rather than assumed.
      expect(utf8.encode(loneSurrogate), equals([97, 239, 191, 189, 98]));

      expect(KeyExpr.isCanon(loneSurrogate), isTrue);
      expect(KeyExpr.canonize(loneSurrogate), equals(substitutedSurrogate));
      expect(KeyExpr.canonize(loneSurrogate), isNot(equals(loneSurrogate)));

      final viaFactory = KeyExpr.autocanonize(loneSurrogate);
      expect(viaFactory.value, equals(substitutedSurrogate));
      viaFactory.dispose();

      final viaStrict = KeyExpr(loneSurrogate);
      expect(viaStrict.value, equals(substitutedSurrogate));
      viaStrict.dispose();

      // The substitution is why Z_EPARSE (-2) is unreachable from the Dart
      // `String` surface: canon never receives invalid UTF-8 through it. No
      // test in this file chases -2.
    });

    test('no forbidden transform on any new path', () {
      // The strict door is the control: it must still REJECT a non-canon
      // expression rather than silently canonize it, NUL or no NUL.
      expect(() => KeyExpr('a\x00b/**/**/c'), throwsCanonEinval);
      expect(() => KeyExpr('a/**/**/c'), throwsCanonEinval);

      // And the canon-form NUL expression still constructs byte-exact through
      // the strict door, so the rejection above is about canon form and not
      // about the NUL.
      final ke = KeyExpr('a\x00b');
      expect(utf8.encode(ke.value), equals([97, 0, 98]));
      ke.dispose();
    });
  });

  // Slice 6 -- the product is an ORDINARY KeyExpr.
  //
  // The factory is only additive if what it returns is indistinguishable from
  // any other handle downstream. These legs drive the product through the
  // wire, the relations triad, clone, dispose and the `String | KeyExpr`
  // union, rather than stopping at `value`.
  //
  // ASCII vectors only: the non-ASCII boundary is construction-level, and no
  // expression from that class may reach a session operation.
  group('KeyExpr.autocanonize -- the product downstream', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      // Network-quiet: a dedicated loopback port with multicast and gossip
      // off, so the delivery assertion is about these two sessions and not
      // about whatever else is on the LAN.
      session1 = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19120"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 500));

      session2 = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19120"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session2.close();
      session1.close();
    });

    test('the canonized expression is what reaches the wire', () async {
      final subscriber = session2.declareSubscriber('zenoh/dart/s4/deliv/**');
      addTearDown(subscriber.close);

      final received = <Sample>[];
      final sub = subscriber.stream.listen(received.add);
      addTearDown(sub.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Canon form of `zenoh/dart/s4/deliv/$*$*` is
      // `zenoh/dart/s4/deliv/*` -- the observer must see the REWRITTEN
      // expression, not the input the publisher typed.
      final ke = KeyExpr.autocanonize(r'zenoh/dart/s4/deliv/$*$*');
      addTearDown(ke.dispose);
      expect(ke.value, equals('zenoh/dart/s4/deliv/*'));

      session1.put(ke, 'canonized');

      await waitUntil(
        () => received.isNotEmpty,
        description: 'the sample published through an autocanonize product',
      );

      expect(received, hasLength(1));
      expect(
        utf8.encode(received.first.keyExpr),
        equals(utf8.encode('zenoh/dart/s4/deliv/*')),
      );
      expect(received.first.payload, equals('canonized'));
    });

    test('the product answers relations against a strict peer', () {
      final wide = KeyExpr.autocanonize('zenoh/dart/s4/rel/**/**');
      final narrow = KeyExpr('zenoh/dart/s4/rel/leaf');
      final strictPeer = KeyExpr('zenoh/dart/s4/rel/**');
      addTearDown(strictPeer.dispose);
      addTearDown(narrow.dispose);
      addTearDown(wide.dispose);

      expect(wide.value, equals('zenoh/dart/s4/rel/**'));
      expect(wide.includes(narrow), isTrue);
      expect(wide.intersects(narrow), isTrue);
      expect(wide.equals(strictPeer), isTrue);
      expect(narrow.includes(wide), isFalse);
    });

    test('the product clones with an independent lifetime', () {
      final product = KeyExpr.autocanonize('zenoh/dart/s4/clone/**/**');
      final copy = product.clone();
      addTearDown(copy.dispose);

      product.dispose();

      expect(
        utf8.encode(copy.value),
        equals(utf8.encode('zenoh/dart/s4/clone/**')),
      );
    });

    test('dispose is the local release, and is idempotent', () {
      final product = KeyExpr.autocanonize('zenoh/dart/s4/disp/**/**')
        ..dispose();
      expect(product.dispose, returnsNormally);
      expect(() => product.value, throwsStateError);
    });

    test('the product is accepted by the union, and is not consumed', () {
      // `put` takes the `String | KeyExpr` union and LOANS a KeyExpr rather
      // than consuming it, so the handle is still the caller's afterwards.
      final product = KeyExpr.autocanonize('zenoh/dart/s4/union/**/**');
      addTearDown(product.dispose);

      expect(() => session1.put(product, 'first'), returnsNormally);

      expect(
        utf8.encode(product.value),
        equals(utf8.encode('zenoh/dart/s4/union/**')),
      );
      expect(() => session1.put(product, 'second'), returnsNormally);
    });
  });
}
