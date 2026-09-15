// Seed [API] slice 8 — the dead-export prune, derived over a named tree and
// dispositioned per symbol.
//
// ⛔ THE DERIVATION IS THE ARTIFACT, NOT THE LIST. A prune that starts from an
// inherited candidate list can only ever confirm that list. This file starts
// from every FFI_PLUGIN_EXPORT declaration in the header and re-derives the
// dead set, so the next unit disagrees with an instrument rather than with a
// table someone typed.
//
// ⚠️ THE LIVENESS TREE IS NAMED WITH ITS NUMBER, because the set moves with
// the tree and nobody had ever said which tree the project's rule ranges over.
// It is `package/lib` (excluding the generated bindings), `package/test`,
// `package/example`, `scripts/`, and `src/zenoh_dart.{c,h}` — SEVEN roots as
// the census script's own globs define them. `development/` is EXCLUDED from
// liveness: nothing under it is compiled, analysed, or run by any gate, and
// every file there is pinned to the HEAD it measured. A tracked caller there
// is not discarded, though — it is admitted one step later, at the
// DISPOSITION, as evidence toward a KEEP.
import 'dart:io';

import 'package:test/test.dart';

import 'helpers/changelog_section.dart';

/// The symbols this slice removes.
const prunedSymbols = <String>[
  'zd_bytes_copy_from_str',
  'zd_bytes_to_string',
  'zd_config_loan',
  'zd_query_keyexpr',
  'zd_whatami_to_view_string',
];

/// The symbols with no Dart caller that are KEPT, each on a stated ground.
const retainedDeadSymbols = <String>[
  'zd_open_session',
  'zd_session_sizeof',
];

/// Every `zd_` symbol DECLARED in the shim header.
List<String> declaredSymbols() {
  final header = File('../src/zenoh_dart.h').readAsStringSync();
  final out = <String>[];
  for (final line in header.split('\n')) {
    if (!line.startsWith('FFI_PLUGIN_EXPORT')) continue;
    final m = RegExp(r'\*?\b(zd_[A-Za-z0-9_]*)\s*\(').firstMatch(line);
    if (m != null) out.add(m.group(1)!);
  }
  return (out.toSet().toList())..sort();
}

/// The files the liveness rule ranges over.
List<File> livenessTree() {
  final files = <File>[];
  for (final root in const [
    'lib',
    'test',
    'example',
    '../scripts',
  ]) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final e in dir.listSync(recursive: true)) {
      if (e is! File) continue;
      final p = e.path;
      if (p.endsWith('src/bindings.dart')) continue;
      if (p.endsWith('dead_export_test.dart')) continue;
      if (p.endsWith('.dart') ||
          p.endsWith('.sh') ||
          p.endsWith('.c') ||
          p.endsWith('.h') ||
          p.endsWith('.py')) {
        files.add(e);
      }
    }
  }
  files
    ..add(File('../src/zenoh_dart.c'))
    ..add(File('../src/zenoh_dart.h'));
  return files;
}

/// Whether [line] references [symbol] in CODE rather than in a comment.
///
/// ⛔ ANCHORED. A naive scan for `zd_query_payload` returns five hits of which
/// one is `zd_query_payload_clone` — a different symbol.
bool codeReferences(String line, String symbol) {
  final trimmed = line.trimLeft();
  if (trimmed.startsWith('//') ||
      trimmed.startsWith('/*') ||
      trimmed.startsWith('*')) {
    return false;
  }
  final codePart = line.split('//').first;
  return RegExp('\\b$symbol\\b').hasMatch(codePart);
}

/// Code references to [symbol] across the liveness tree, excluding the
/// symbol's own declaration in the header and definition in the `.c`.
int codeReferenceCount(String symbol, List<File> tree) {
  var n = 0;
  final declaration = RegExp('^FFI_PLUGIN_EXPORT.*\\b$symbol\\s*\\(');
  for (final f in tree) {
    if (!f.existsSync()) continue;
    for (final line in f.readAsStringSync().split('\n')) {
      if (declaration.hasMatch(line)) continue;
      if (codeReferences(line, symbol)) n++;
    }
  }
  return n;
}

/// `zd_`-prefixed dynamic symbols defined by [variant]'s shipped native.
Set<String> shippedSymbols(String variant) {
  final r = Process.runSync('nm', [
    '-D',
    '--defined-only',
    'native/linux/x86_64/$variant/libzenoh_dart.so',
  ]);
  expect(r.exitCode, 0, reason: 'nm failed: ${r.stderr}');
  return (r.stdout as String)
      .split('\n')
      .map((l) => l.trim().split(RegExp(r'\s+')))
      .where((p) => p.length >= 3 && p[2].startsWith('zd_'))
      .map((p) => p[2])
      .toSet();
}

/// [text] with every dated-correction parenthetical removed.
///
/// ⛔ THIS PROJECT PRESERVES RETRACTED TEXT — a correction quotes the claim it
/// strikes, and `Session.declarePullQueryable` ships one in the generated
/// reference today. So a bare `isNot(contains(<claim>))` cannot tell STILL
/// ASSERTED from QUOTED AS STRUCK, and answers "still there" on a correctly
/// corrected file, permanently. Assert on the operative text instead, and
/// check the marker separately so the strip cannot silently become a no-op.
String operative(String text) =>
    text.replaceAll(RegExp(r'\(Corrected:[\s\S]*?\)'), ' ');

void main() {
  group('[API] the dead-export prune', () {
    late List<String> declared;
    late List<File> tree;

    setUpAll(() {
      declared = declaredSymbols();
      tree = livenessTree();
    });

    test('the derivation runs over every declared symbol, not an inherited '
        'candidate list', () {
      // The population is the HEADER's, so a symbol nobody thought to put on
      // a candidate list is still examined.
      expect(
        declared,
        hasLength(216),
        reason:
            'the declared population moved. It was 221 at the fork point '
            'and this slice removes five; find the delta and NAME it before '
            'changing this number',
      );
      // ⭐ AND THE TREE IS NAMED WITH ITS NUMBER, which is what the seed asks
      // for and what nobody had stated: the set moves with the tree.
      expect(
        tree.map((f) => f.path).where((p) => p.startsWith('lib/')),
        isNotEmpty,
      );
      expect(tree.length, greaterThan(100));
    });

    test('the surviving dead set is exactly the two documented KEEPs', () {
      final dead = <String>[
        for (final s in declared)
          if (codeReferenceCount(s, tree) == 0) s,
      ];
      expect(
        dead,
        unorderedEquals(retainedDeadSymbols),
        reason:
            'the dead set is not the two KEEPs. Every symbol the '
            'derivation surfaces needs a disposition — prune, or KEEP with '
            'its ground — and an unexpected one has neither',
      );
      // ⛔ AND EACH KEEP CARRIES ITS GROUND ADJACENT TO ITS DECLARATION. A
      // kept dead symbol whose reason lives only in a PR body is one nobody
      // can act on later.
      final header = File('../src/zenoh_dart.h').readAsStringSync();
      expect(header, contains('RETAINED alongside'));
      expect(
        header.toLowerCase(),
        contains('caller-allocated slot'),
        reason:
            'the retention ground for the synchronous session pair is not '
            'stated in the header. (Case-insensitive: the pre-existing '
            'RETAINED block writes CALLER-allocated and the new one writes '
            'CALLER-ALLOCATED, and neither casing is the point)',
      );
    });

    test('each pruned symbol is absent from every layer', () {
      // Following the absence-pin shape at parameters_fidelity_test.dart.
      final bindings = File('lib/src/bindings.dart').readAsStringSync();
      final header = File('../src/zenoh_dart.h').readAsStringSync();
      final impl = File('../src/zenoh_dart.c').readAsStringSync();
      for (final s in prunedSymbols) {
        expect(bindings.contains(s), isFalse, reason: '$s is still bound');
        expect(header.contains(s), isFalse, reason: '$s is still declared');
        expect(impl.contains(s), isFalse, reason: '$s is still defined');
      }
      // ⛔ THE SCAN MATCHES A REACHING SHAPE, NOT THE BARE NAME, and that is
      // a sharpening rather than a loosening. Two shapes can actually reach a
      // shim symbol from Dart: a member access on the bindings object, and a
      // lookup by string literal. A bare `contains` answers something else --
      // it also fires on PROSE, and this corpus is required to write that
      // prose: the export-pin cell in diagnosability_baselines_test.dart must
      // NAME these five beside the new count, because its own protocol says
      // "find the delta and NAME it before changing the number". Under a bare
      // scan, obeying that protocol fails this cell, and the lesson a reader
      // takes is to stop naming deltas.
      //
      // ⭐ AND IT NEEDS NO HAND-MAINTAINED EXCLUSION LIST, which is the same
      // ground the finalizer-family cell below rests on: a list rots, and the
      // shape does not.
      // ⛔ REACHING MEANS *WOULD BREAK*, AND THERE ARE EXACTLY TWO SHAPES.
      // A member access on the bindings object fails to COMPILE once the
      // bindings are regenerated; a symbolic lookup by name fails at RUNTIME.
      // Nothing else reaches a shim symbol from Dart.
      //
      // ⛔ AN EARLIER FORM OF THIS COUNTED ANY QUOTED OCCURRENCE AS A LOOKUP,
      // AND IT WENT RED ON THIS UNIT'S OWN BREAKING INVENTORY -- a cell that
      // is REQUIRED to name the five removed symbols in the CHANGELOG check.
      // That is the time-scoped absence assertion: the question to ask of one
      // is not "is this true now" but "does this unit, or anything it obliges
      // someone to do next, create an instance of what I am asserting does
      // not exist?" It did, three slices later, in the same file.
      String? reachingShape(String line, String symbol) {
        final code = line.trimLeft().startsWith('//')
            ? ''
            : line.split('//').first;
        if (RegExp('\\.\\s*$symbol\\b').hasMatch(code)) {
          return 'member access';
        }
        if (RegExp("(lookup|_entry)\\s*(<[^>]*>)?\\s*\\(\\s*['\"]$symbol['\"]")
            .hasMatch(code)) {
          return 'symbolic lookup';
        }
        return null;
      }

      final offenders = <String>[];
      var memberAccessControl = 0;
      var lookupControl = 0;
      for (final dir in [Directory('lib'), Directory('test')]) {
        for (final e in dir.listSync(recursive: true)) {
          if (e is! File || !e.path.endsWith('.dart')) continue;
          if (e.path.endsWith('src/bindings.dart')) continue;
          if (e.path.endsWith('dead_export_test.dart')) continue;
          for (final line in e.readAsStringSync().split('\n')) {
            // ⭐ ONE POSITIVE CONTROL PER SHAPE, in the same pass over the
            // same corpus. Without them an empty offender list is the scan's
            // blindness and the symbols' absence, indistinguishable.
            if (reachingShape(line, 'zd_query_sizeof') == 'member access') {
              memberAccessControl++;
            }
            if (reachingShape(line, 'zd_fin_bytes') == 'symbolic lookup') {
              lookupControl++;
            }
            for (final s in prunedSymbols) {
              final shape = reachingShape(line, s);
              if (shape != null) offenders.add('${e.path}: $s ($shape)');
            }
          }
        }
      }
      expect(
        memberAccessControl,
        greaterThan(0),
        reason:
            'the scan cannot see `bindings.zd_query_sizeof()`, which IS '
            'called in finalizer_harness.dart -- so it is blind to a member '
            'access and the empty result below would mean nothing',
      );
      expect(
        lookupControl,
        greaterThan(0),
        reason:
            "the scan cannot see `_entry('zd_fin_bytes')` in "
            'finalizers.dart -- so it is blind to a symbolic lookup, which is '
            'the shape the finalizer family is reached by',
      );
      expect(
        offenders,
        isEmpty,
        reason:
            'a removed symbol is still REACHED from Dart, which would not '
            'compile against the regenerated bindings',
      );
    });

    test('the shipped natives moved, and the delta is NAMED', () {
      // ⛔ THE PROTOCOL THE SIBLING CELL STATES, OBEYED RATHER THAN SATISFIED:
      // find the delta and name it before changing the number. 221 -> 216 on
      // unstable and 184 -> 179 on stable, and the five are these, all of
      // them outside both #if regions in the header (SHM+unstable at the
      // shm block, unstable at the advanced block), which is why both
      // variants move by the SAME five rather than by different counts.
      final unstable = shippedSymbols('unstable');
      final stable = shippedSymbols('stable');
      expect(unstable, hasLength(216));
      expect(stable, hasLength(179));
      for (final s in prunedSymbols) {
        expect(unstable, isNot(contains(s)), reason: '$s still shipped');
        expect(stable, isNot(contains(s)), reason: '$s still shipped');
      }
      // The two KEEPs are still exported, which is the whole point of keeping
      // them: an embedder links against the shared object.
      for (final s in retainedDeadSymbols) {
        expect(unstable, contains(s));
        expect(stable, contains(s));
      }
    });

    test('the false comments about zd_query_sizeof are corrected in BOTH '
        'places', () {
      // The claim "zd_query_sizeof has no callers" is false, and it was
      // written in TWO files. The second sits about nine hundred lines above
      // the call that falsifies it, in the same file.
      final impl = File('../src/zenoh_dart.c').readAsStringSync();
      final harness = File('test/helpers/finalizer_harness.dart')
          .readAsStringSync();
      for (final entry in {
        'zenoh_dart.c': impl,
        'finalizer_harness': harness,
      }.entries) {
        expect(
          entry.value,
          contains('Corrected:'),
          reason:
              '${entry.key} carries no correction marker, so the strip '
              'below removes nothing and the assertions after it are vacuous',
        );
        final text = operative(entry.value);
        expect(
          text,
          isNot(contains('has no callers')),
          reason:
              '${entry.key} still ASSERTS that zd_query_sizeof has no '
              'callers (a struck quotation inside the correction is fine)',
        );
        expect(
          text,
          isNot(contains('no Dart callers')),
          reason:
              '${entry.key} still ASSERTS that zd_query_sizeof has no '
              'Dart callers',
        );
      }
      // And the caller that falsifies it is real, in the same file as the
      // second claim.
      expect(harness, contains('bindings.zd_query_sizeof()'));
    });

    test('zd_session_sizeof header doc states the ground that retains it', () {
      final header = File('../src/zenoh_dart.h').readAsStringSync();
      final at = header.indexOf('size_t zd_session_sizeof(void);');
      expect(at, greaterThan(0));
      // ⛔ THE WINDOW IS SIZED FROM THE BLOCK, NOT GUESSED. A fixed-width
      // window slides past the text the moment the repair lengthens the
      // block -- which is exactly how a sibling cell in this unit went green
      // without seeing the sentence it was about.
      final blockStart = header.lastIndexOf(
        '/// Returns the size of '
        'z_owned_session_t',
        at,
      );
      expect(blockStart, greaterThan(0));
      final doc = operative(header.substring(blockStart, at));
      expect(
        header.substring(blockStart, at),
        contains('Corrected:'),
        reason: 'no correction marker, so the strip is a no-op',
      );
      expect(
        doc,
        isNot(contains('Used by Dart to allocate')),
        reason:
            'the OPERATIVE doc still states a purpose Dart no longer '
            'serves, in the present tense',
      );
      expect(
        doc.toLowerCase(),
        contains('caller-allocated slot'),
        reason:
            'the retention ground is not stated where the symbol is '
            'declared, so a later prune finds it dead again with no reason '
            'beside it',
      );
    });

    test('the CHANGELOG names each removed symbol', () {
      final changelog = File('../CHANGELOG.md').readAsStringSync();
      // The section that announced this unit, found above the last release
      // before it (0.19.0). A release renames `## Unreleased`, so the cell
      // cannot find it by that name — see helpers/changelog_section.dart.
      final announced = changelogSectionAnnouncing(
        changelog,
        prunedSymbols.first,
        anchor: '0.19.0',
      );
      expect(
        announced,
        isNotNull,
        reason: 'no section above 0.19.0 announces this unit',
      );
      for (final s in prunedSymbols) {
        expect(
          announced,
          contains(s),
          reason:
              '$s was removed from the shared object and the section '
              'announcing this unit does not name it',
        );
      }
      expect(announced, contains('embedder'));
    });

    // --- Edge cases ---

    test(
      'the symbol pattern is anchored, so a longer sibling is not matched',
      () {
        // MEASURED: a naive scan for zd_query_payload returns five hits of
        // which one is zd_query_payload_clone -- a different symbol. Without
        // the word boundary the derivation would read a removed symbol as live
        // because a longer one shares its prefix.
        const line = '  final n = bindings.zd_query_payload_clone(q);';
        expect(codeReferences(line, 'zd_query_payload_clone'), isTrue);
        expect(
          codeReferences(line, 'zd_query_payload'),
          isFalse,
          reason: 'the pattern is unanchored and matches a longer sibling',
        );
      },
    );

    test('the finalizer-callback family is not excluded by hand', () {
      // Their liveness rides on string literals such as _entry('zd_fin_bytes')
      // which a SOURCE-TEXT scan finds on a code line by the ordinary rule.
      // A hand-maintained carve-out rots; an instrument that reads source
      // needs none, and this cell is what says so.
      final family = declared.where((s) => s.startsWith('zd_fin_')).toList();
      expect(family, isNotEmpty);
      for (final s in family) {
        expect(
          codeReferenceCount(s, tree),
          greaterThan(0),
          reason:
              '$s reads as dead, which would mean the derivation cannot '
              'see a symbol whose only reference is a string literal',
        );
      }
    });

    test('the example README no longer describes a removed accessor', () {
      // ⚠️ ALREADY FALSE BEFORE THIS SLICE: it listed four "retained"
      // accessors, and zd_query_parameters was removed at an earlier seed.
      // The prune makes it more false. This file is inside the publish
      // boundary, so it is this unit's.
      // ⚠️ THE PROPERTY IS NOT "THE NAME IS ABSENT". A passage that says a
      // symbol WAS REMOVED has to name it, and that account is worth more
      // than silence -- it is why the accessor shape was wrong. What must be
      // gone is the claim that these are RETAINED and exist.
      final readme = File('example/README.md').readAsStringSync();
      expect(
        readme,
        isNot(contains('barrier-justified but currently unreachable')),
        reason: 'the passage still presents the removed accessors as retained',
      );
      for (final gone in const ['zd_query_parameters', 'zd_query_keyexpr']) {
        final at = readme.indexOf(gone);
        if (at < 0) continue;
        final around = readme.substring(
          at - 260 < 0 ? 0 : at - 260,
          at + 260 > readme.length ? readme.length : at + 260,
        );
        expect(
          around,
          contains('removed'),
          reason:
              '$gone is named in the README without the passage saying it '
              'was removed, so a reader still takes it for an existing symbol',
        );
      }
      expect(
        readme,
        contains('zd_query_payload'),
        reason:
            'the passage should still name the accessors that DO exist; '
            'if it names none, it was deleted rather than corrected',
      );
    });

    // ⛔ RETIRED 2026-09-10: the cell "a stale variant cannot pass this file
    // silently", which asserted that each shipped native's modification
    // time was later than the header's.
    //
    // The mtime was a PROXY for "this object was built from this header",
    // and it discriminates in neither direction: `touch` on a stale object
    // turns it green, and a checkout that rewrites the header turns a
    // current object red. The second happened. With the merge 6a3a82c on
    // `main`, the header read 23:18:17 against natives built at 18:45:38 and
    // 18:45:54 from byte-identical content — `git diff cbc340d..6a3a82c`
    // over the header, the .c and bindings.dart is empty — and the cell went
    // red, its reason text sending the reader to rebuild both preset pairs to
    // no effect. A git operation, not a stale build.
    //
    // WHAT STILL MEASURES THE PROPERTY, BY CONTENT, IN THE CELLS ABOVE: the
    // header declares 216, and each variant's linker table carries its
    // expected count with the five pruned names absent and the two KEEPs
    // present.
    //
    // ⛔ WHAT NOTHING IN THIS FILE MEASURES — neither those cells nor the one
    // retired here: a SIGNATURE change under an unchanged name. nm reads
    // names, the header scan reads names, and an mtime reads neither. The
    // failure does not crash: a six-parameter call through a ten-parameter
    // declaration leaves the surplus arguments in registers the callee never
    // reads. So a stale native whose names did not move passes every cell
    // above. Stamping a header content hash into both builds would see it;
    // that route was weighed when this cell was retired, and not taken. The
    // retirement is the [MTIME] row in §13 of
    // development/reviews/parity-roadmap-reshape-20260714.md.
  });
}
