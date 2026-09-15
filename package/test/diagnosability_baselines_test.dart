// Seed [D1] slice 18 — the unit closes on re-measured baselines, retired
// instruments, and a re-run blast-radius query.
//
// ⛔⛔ THE DURABLE ARTIFACT OF THIS SLICE IS THE QUERY BELOW, NOT A TABLE. The
// plan carried a worked table of pins; that table was the OUTPUT of one run at
// one commit and was stale the moment the edit set changed. What the next unit
// needs is the instrument, so it lives here as code that runs.
//
// ⛔ FOUR WAYS A PIN MOVES, AND ONLY THE FIRST IS WHAT AN IDENTIFIER GREP
// FINDS. This is the whole reason the derived query exists:
//
//   1. a LITERAL changed        — an identifier sweep finds it
//   2. a COUNT changed          — `expect(exports, 34)` names nothing
//   3. a SCAN WINDOW shifted    — `substring(start, start + 2200)` silently
//                                 stops covering what it was written to cover
//   4. a WALKED TREE gained or lost a member — a new file joins a corpus some
//                                 cell asserts a property over
//
// This unit's hardest red was class 2: a cell asserting `exports == 34`, in a
// group about CLAUDE.md, naming none of the mechanism's identifiers. Invisible
// to an identifier sweep, invisible to reading the diff.
//
// ⚠️ DECLARED RESIDUAL: pass 1 is only as wide as its method-name list.
// Widening from `readAsStringSync` alone to all four reading forms moved the
// pinned-file count 21 → 27 when the plan measured it. A reading form not in
// that list is invisible again.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// PASS 1, THE PRIMARY INSTRUMENT — every test that reads a file, and what it
/// reads.
///
/// "For each source file this unit edits, find every test that reads it, and
/// check whether any pinned literal, count, scan window, or walked-tree
/// membership moved."
///
/// The shell form, kept beside the Dart one because the shell form is what a
/// reader will reach for:
/// ```sh
/// find package/test -name '*_test.dart' | xargs awk \
///   '/readAsStringSync|readAsLinesSync|readAsBytesSync|listSync/ \
///    {sub(/^.*\/package\/test\//,"",FILENAME); print FILENAME":"FNR": "$0}'
/// ```
Map<String, List<int>> pinnedReadSites() {
  final sites = <String, List<int>>{};
  final pattern = RegExp(
    'readAsStringSync|readAsLinesSync|readAsBytesSync|listSync',
  );
  for (final entity in Directory('test').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('_test.dart')) continue;
    final lines = const LineSplitter().convert(entity.readAsStringSync());
    for (var i = 0; i < lines.length; i++) {
      if (pattern.hasMatch(lines[i])) {
        sites.putIfAbsent(entity.path, () => <int>[]).add(i + 1);
      }
    }
  }
  return sites;
}

/// The effective public member set of a door, after `show`/`hide` resolution.
///
/// ⚠️ THE FILE-LEVEL COUNT IS BLIND, which is why this exists. `awk '/^export
/// /'` counts FILES; a member added to, removed from, or hidden in an
/// already-exported file moves nothing it can see. This is the member-level
/// instrument the seed's baseline table said was owed beside it.
///
/// The instrument is an `rg`-class top-level-declaration scan per exported
/// file with the export clauses applied — named here rather than left as
/// "the census", because a number without its instrument is a number nobody
/// can reproduce.
///
/// ⛔ IT PARSES A DIRECTIVE, NOT A LINE. See [exportDirectives].
Set<String> publicMembers(String door) => _membersFromDirectives(
  exportDirectives(
    const LineSplitter().convert(File(door).readAsStringSync()),
  ),
);

/// The census's clause-application step, over already-accumulated
/// [directives].
///
/// ⭐ SHARED WITH THE RECORDED CONTROLS in the slice-1 group below, so that
/// the ONLY variable between the instrument and the readings it is contrasted
/// with is where a directive is judged to end. A control that carried its own
/// copy of this scan could differ from the instrument for a second reason,
/// and the contrast would stop meaning what it is written to mean.
Set<String> _membersFromDirectives(Iterable<String> directives) {
  final declaration = RegExp(
    r'^(?:abstract\s+|final\s+|base\s+|sealed\s+|interface\s+|mixin\s+)*'
    r'(?:class|enum|extension type|extension|typedef|mixin)\s+(\w+)',
  );
  final topLevelFn = RegExp(r'^(?:[\w<>,?\s]+\s+)(\w+)\s*\(');
  final members = <String>{};
  for (final directive in directives) {
    final path = RegExp("export '([^']+)'").firstMatch(directive)?.group(1);
    if (path == null) continue;
    final hidden = RegExp('hide ([^;]+)')
        .firstMatch(directive)
        ?.group(1)
        ?.split(',')
        .map((s) => s.trim())
        .toSet();
    final shown = RegExp('show ([^;]+)')
        .firstMatch(directive)
        ?.group(1)
        ?.split(',')
        .map((s) => s.trim())
        .toSet();

    final file = File('lib/$path');
    if (!file.existsSync()) continue;
    for (final src in const LineSplitter().convert(file.readAsStringSync())) {
      if (src.startsWith(' ') || src.startsWith('/') || src.isEmpty) continue;
      final name =
          declaration.firstMatch(src)?.group(1) ??
          topLevelFn.firstMatch(src)?.group(1);
      if (name == null || name.startsWith('_')) continue;
      if (shown != null && !shown.contains(name)) continue;
      if (hidden != null && hidden.contains(name)) continue;
      members.add(name);
    }
  }
  return members;
}

/// The `export` directives of a door, each accumulated to its terminating
/// `;`.
///
/// ⛔ A DIRECTIVE IS NOT A LINE, AND THE REPAIR IS NOT "JOIN THE NEXT LINE".
/// [publicMembers] used to apply the `show`/`hide` regexes to one line at a
/// time, and the failure was BIDIRECTIONAL: a clause wholly on the
/// continuation line was never seen, so the door read as though nothing had
/// been fenced; a clause opening on the export line and continuing was cut at
/// the line end, so the door read as though a name had been fenced that was
/// not. Joining only the NEXT line reads a two-line wrap correctly and a
/// three-line wrap wrongly — a repair that passes its own fixtures.
/// Accumulating to the `;` closes both directions at every wrap depth.
///
/// ⚠️ IT STAYS A TEXT SCAN. It deliberately does not follow a non-`src/`
/// re-export such as `export 'zenoh.dart';`: resolving that would move this
/// instrument onto the resolved census's own assumption, and the two are kept
/// apart precisely so a cross-check between them means something.
List<String> exportDirectives(List<String> doorLines) {
  final directives = <String>[];
  for (var i = 0; i < doorLines.length; i++) {
    if (!doorLines[i].startsWith('export ')) continue;
    final buffer = StringBuffer(doorLines[i].trimRight());
    while (!doorLines[i].contains(';') && i + 1 < doorLines.length) {
      i++;
      buffer.write(' ${doorLines[i].trim()}');
    }
    directives.add(buffer.toString());
  }
  return directives;
}

/// `zd_`-prefixed dynamic symbols defined by [variant]'s native.
Set<String> zdSymbols(String variant) {
  final result = Process.runSync('nm', [
    '-D',
    '--defined-only',
    'native/linux/x86_64/$variant/libzenoh_dart.so',
  ]);
  expect(result.exitCode, 0, reason: 'nm failed: ${result.stderr}');
  return (result.stdout as String)
      .split('\n')
      .map((l) => l.trim().split(RegExp(r'\s+')))
      .where((p) => p.length >= 3 && p[2].startsWith('zd_'))
      .map((p) => p[2])
      .toSet();
}

int awkCount(List<String> paths, RegExp pattern) {
  var total = 0;
  for (final path in paths) {
    for (final m in pattern.allMatches(File(path).readAsStringSync())) {
      if (m.start >= 0) total++;
    }
  }
  return total;
}

List<String> libDartFiles() =>
    Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.path)
        .toList();

// --- Seed [API] slice 1 — the census must parse a DIRECTIVE, not a line. ---
//
// ⛔ THE DEFECT WAS BIDIRECTIONAL, WHICH IS WHY BOTH WRAP SHAPES ARE
// FIXTURED. `publicMembers` parsed `export … show …` ONE LINE AT A TIME.
// Measured on the unrepaired helper over the fixtures below, whose target
// `lib/src/recv_result.dart` declares four public names:
//
//   show wholly on the continuation line   correct 2, read 4 — over-report
//   show opening on line 1 and continuing  correct 2, read 1 — under-report
//   hide wholly on the continuation line   correct 2, read 4 — hid nothing
//   hide opening on line 1 and continuing  correct 2, read 3 — hid only the
//                                                              first name
//
// ⭐ The two directions tell OPPOSITE stories — "nothing was fenced" and "a
// name was fenced that was not" — so a repair verified against one of them
// can leave the other standing.

/// The head of every fixture directive, naming a REAL library under
/// `package/lib`.
///
/// ⚠️ THE DOOR MAY LIVE IN A TEMP DIRECTORY; ITS EXPORT PATH MAY NOT.
/// [publicMembers] reads the door at whatever path it is handed, then
/// resolves each exported path as `File('lib/<path>')` — relative to the
/// process CWD, which is `package/`. A fixture target written under `lib/`
/// would ship and would be analysed by the strict gate, so an existing
/// library is used instead.
const _fixtureTarget = "export 'src/recv_result.dart'";

/// The two names every clause fixture below names.
const _clauseNames = {'RecvData', 'RecvEmpty'};

/// No clause at all — the fixture that DERIVES the target's full member set.
const _bareDoor = '$_fixtureTarget;\n';

/// The unwrapped forms, which the repair must leave reading identically.
const _showOneLine = '$_fixtureTarget show RecvData, RecvEmpty;\n';
const _hideOneLine = '$_fixtureTarget hide RecvData, RecvEmpty;\n';

/// The clause wholly on the continuation line — the shape a formatter emits.
const _showTrailing = '$_fixtureTarget\n    show RecvData, RecvEmpty;\n';
const _hideTrailing = '$_fixtureTarget\n    hide RecvData, RecvEmpty;\n';

/// The clause opening on line 1 and continuing — the shape a hand wrap emits.
const _showOpening = '$_fixtureTarget show RecvData,\n    RecvEmpty;\n';
const _hideOpening = '$_fixtureTarget hide RecvData,\n    RecvEmpty;\n';

/// Three lines, which is where "join only the next line" stops working.
const _showThreeLine =
    '$_fixtureTarget\n    show RecvData,\n        RecvEmpty;\n';
const _hideThreeLine =
    '$_fixtureTarget\n    hide RecvData,\n        RecvEmpty;\n';

/// Writes [body] as a fixture door named [name] under [dir], returning its
/// path.
String _writeFixtureDoor(Directory dir, String name, String body) {
  final file = File('${dir.path}/$name.dart')..writeAsStringSync(body);
  return file.path;
}

/// The PRE-REPAIR reading — every door line parsed on its own.
///
/// Kept as a recorded control rather than described in a comment, because the
/// failure was bidirectional and a repair verified against one direction can
/// leave the other standing. This function's answer must NOT move when
/// [publicMembers] is repaired; it is the frozen "before".
Set<String> _lineByLineMembers(String door) => _membersFromDirectives(
  const LineSplitter()
      .convert(File(door).readAsStringSync())
      .where((l) => l.startsWith('export ')),
);

/// The reading a repair that joins only the NEXT line would give.
///
/// ⭐ It is right on every two-line fixture in this group and wrong on the
/// three-line one, which is what makes "accumulate to the `;`" falsifiable
/// rather than merely asserted.
Set<String> _joinNextLineMembers(String door) {
  final lines = const LineSplitter().convert(File(door).readAsStringSync());
  final directives = <String>[];
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('export ')) continue;
    final joinable = !lines[i].contains(';') && i + 1 < lines.length;
    directives.add(
      joinable ? '${lines[i]} ${lines[i + 1].trim()}' : lines[i],
    );
  }
  return _membersFromDirectives(directives);
}

void main() {
  group('[D1] S18 — the close', () {
    test('the Dart surface is counted at MEMBER level, with the instrument '
        'named', () {
      final stable = publicMembers('lib/zenoh.dart');
      // The two this unit added, and they are named rather than counted:
      // asserting only a total would let an addition and a removal cancel.
      expect(stable, contains('LogRecord'));
      expect(stable, contains('LogSeverity'));
      expect(stable, contains('ZenohException'));
      expect(stable, contains('Zenoh'));
      // ⛔ And the two @internal receive-path helpers are HIDDEN at the door,
      // so slice 13 widened no public surface.
      expect(stable, isNot(contains('undecodableRc')));
      expect(stable, isNot(contains('undecodableError')));
    });

    test('a member added or removed without a plan entry fails the cell', () {
      // The census is a gate, not a readout: an unexpected public member
      // fails HERE, naming itself, rather than landing silently between units.
      final stable = publicMembers('lib/zenoh.dart');
      const addedByThisUnit = {'LogRecord', 'LogSeverity'};
      const removedByThisUnit = <String>{};
      for (final name in addedByThisUnit) {
        expect(stable, contains(name), reason: '$name should be public');
      }
      for (final name in removedByThisUnit) {
        expect(stable, isNot(contains(name)));
      }
      // ⛔ RETIRED AT SEED [API] SLICE 2, NOT REPAIRED. This cell used to
      // read the door's TEXT for `hide undecodableError, undecodableRc`, as
      // a negative control proving the census resolves clauses at all. The
      // door now allow-lists, so the two helpers are excluded by OMISSION
      // FROM A SHOW CLAUSE and no such text exists to pin.
      //
      // ⚠️ AND IT WAS NOT RE-POINTED AT THE `show` TEXT, deliberately. The
      // cell directly above already asserts their absence THROUGH
      // `publicMembers` — which is the property, where the text was only a
      // proxy for it — so a `contains('show ZenohException')` here would
      // re-create a text pin that the census already covers, and would go
      // red on a reformat that changes nothing.
    });

    test('the export MEMBERSHIP delta is asserted, not the count', () {
      // ⛔ THE COUNT WAS 216 ON BOTH SIDES OF [D1] AND HID TWO CHANGES.
      // One reader was removed and one log bind added, so a bare count is
      // exactly the instrument that could not see that unit. The membership
      // assertions below are the answer to that, and they are why this cell
      // still means something after the count moved.
      for (final variant in const ['unstable', 'stable']) {
        final symbols = zdSymbols(variant);
        expect(
          symbols,
          isNot(contains('zd_last_error_message')),
          reason: '$variant still exports the deleted reader',
        );
        expect(
          symbols,
          contains('zd_init_log_with_callback'),
          reason:
              '$variant does not export the log bind — it is guard depth '
              '0 in canon and must be present on BOTH variants',
        );
      }
      // ⚠️ 216 -> 218 ON THE UNSTABLE SIDE at [SHM] shared-memory-lifetime,
      // and the DELTA IS NAMED so the number stays an instrument rather than
      // becoming a rubber stamp that gets bumped whenever it goes red:
      // `zd_shm_provider_alloc_async` and `zd_shm_async_take`, the async
      // allocation seam. Both sit behind the SHM/unstable guard, which is why
      // the stable side does NOT move.
      //
      // ⭐ THIS CELL CAUGHT A REAL OMISSION, and that is worth recording
      // rather than quietly repairing. The slice that added those two symbols
      // recorded the new counts in its commit body and its plan entry, and
      // did NOT re-derive the fence that asserts them -- so the export delta
      // went unrecorded HERE, where the check lives. A change that adds
      // symbols invalidates every instrument calibrated on their absence, and
      // this is one.
      //
      // ⛔ If this goes red again, find the delta and NAME it before changing
      // the number. A symbol added without an entry is exactly what this cell
      // exists to catch.
      expect(
        zdSymbols('unstable'),
        containsAll(<String>[
          'zd_shm_provider_alloc_async',
          'zd_shm_async_take',
        ]),
        reason: 'the async allocation seam must be on the unstable native',
      );
      for (final gated in const [
        'zd_shm_provider_alloc_async',
        'zd_shm_async_take',
      ]) {
        expect(
          zdSymbols('stable'),
          isNot(contains(gated)),
          reason: '$gated is SHM-guarded and must be absent from stable',
        );
      }
      // 218 -> 222 at [SHM] slice 12, and the four are NAMED: the deferred
      // provider drop needs `zd_shm_provider_defer_drop`,
      // `zd_shm_provider_undefer_drop`, `zd_shm_async_box_release` and the
      // deferring finalizer entry `zd_fin_shm_provider_deferred`. All four sit
      // behind the SHM/unstable guard, so stable does not move.
      expect(
        zdSymbols('unstable'),
        containsAll(<String>[
          'zd_shm_provider_defer_drop',
          'zd_shm_provider_undefer_drop',
          'zd_shm_async_box_release',
          'zd_fin_shm_provider_deferred',
        ]),
        reason: 'the deferred-drop seam must be on the unstable native',
      );
      // 222 -> 221 at [SHM] slice 14: `zd_shm_provider_available` REMOVED,
      // on the measurement that it returned a constant 0 at every lifecycle
      // point. ⭐ Note the direction -- this census has only ever gone UP
      // before, and a removal is the delta a bare count is least likely to be
      // questioned about.
      expect(
        zdSymbols('unstable'),
        isNot(contains('zd_shm_provider_available')),
        reason: 'the removed entry is still exported',
      );
      // 221 -> 216 unstable and 184 -> 179 stable at [API] slice 8, and the
      // FIVE ARE NAMED, per this cell's own protocol: `zd_bytes_to_string`,
      // `zd_bytes_copy_from_str`, `zd_config_loan`, `zd_query_keyexpr` and
      // `zd_whatami_to_view_string`. All five had ZERO code references across
      // package/lib (excluding the generated bindings), package/test,
      // package/example, scripts/ and src/ -- the tree the project's liveness
      // rule ranges over, named here with its number because the dead set
      // moves with the tree and nobody had ever said which tree it was.
      //
      // ⭐ NOTE THE DIRECTION, AGAIN. This is the second removal this cell has
      // seen and removals are what a bare count is least likely to be
      // questioned about. All five sit OUTSIDE both #if regions in the
      // header, which is why both variants move by the same five rather than
      // by different counts -- and that symmetry is itself a check: a delta
      // that moved one variant only would mean a guarded symbol was touched.
      //
      // The per-symbol derivation and disposition live in
      // dead_export_test.dart.
      expect(zdSymbols('unstable'), hasLength(216));
      expect(zdSymbols('stable'), hasLength(179));
    });

    test('PASS 1 is re-run at the close over the final edit set', () {
      final sites = pinnedReadSites();
      // The instrument must SEE something, or its emptiness would read as
      // "no pins to check".
      expect(
        sites.keys,
        hasLength(greaterThan(30)),
        reason:
            'the derived query found ${sites.length} pinned files, which '
            'is fewer than this corpus has — the reading-form list has '
            'probably drifted',
      );
      // And the file carrying this unit's hardest red is still in it: the
      // export-count pin lives in a group about CLAUDE.md and names none of
      // the mechanism's identifiers, so only this query finds it.
      expect(
        sites.keys.any((k) => k.endsWith('finalizer_ownership_test.dart')),
        isTrue,
      );
      expect(
        File('test/finalizer_ownership_test.dart').readAsStringSync(),
        contains('expect(exports, 36'),
        reason:
            'the count pin was re-pointed to 36 with its delta stated; a '
            'reversion here means the census and the pin disagree',
      );
    });

    test('PASS 2 finds no stale reference to the deleted mechanism', () {
      // Every surviving match must be a deliberately historical comment or a
      // cell asserting the absence — never live code.
      const identifiers = [
        'zd_last_error_buf',
        'zd_last_error_len',
        '_zd_clear_last_error',
        'zd_last_error_message',
      ];
      final live = <String>[];
      for (final path in [
        ...libDartFiles(),
        '../src/zenoh_dart.c',
        '../src/zenoh_dart.h',
      ]) {
        for (final line in const LineSplitter().convert(
          File(path).readAsStringSync(),
        )) {
          final code = line.trimLeft();
          if (code.startsWith('//') || code.startsWith('///')) continue;
          for (final id in identifiers) {
            if (code.contains(id)) live.add('$path: $line');
          }
        }
      }
      expect(
        live,
        isEmpty,
        reason: 'the deleted mechanism survives in LIVE CODE: $live',
      );
    });

    test(
      'the retired instrument is recorded as retired, with its object gone',
      () {
        // ⛔ THE CAPTURE/CLEAR COUNTER IS RETIRED AS A COMPARABLE NUMBER. It
        // used to count capture-and-clear sites against a DURABLE THREAD-LOCAL
        // BUFFER; that buffer and the clear discipline are deleted, so the old
        // 15 has no successor. The pattern still matches 8 things — five config
        // wrappers, the SHM provider constructor, the open worker, and the
        // definition — but they are calls into CALLER-SUPPLIED storage, which
        // is a different object.
        //
        // ⚠️ 7 -> 9 at unit [SHM] shared-memory-lifetime slice 7, and the fence
        // did its job twice: the widening went red here and was updated
        // deliberately rather than absorbed. The new SITE is
        // zd_shm_provider_new, which canon answers with one code for three
        // rejection classes.
        //
        // ⛔ THE NINTH IS PROSE, NOT A CALL, and saying so is the point. This
        // pattern is a RAW TEXT MATCH over the whole file, so the sentence in
        // that entry's comment naming the helper — the one that records where
        // the `stable` out-length property actually lives — counts too. A
        // reader who takes 9 for "nine call sites" would be wrong by one, which
        // is exactly the kind of drift the retirement note above is about.
        //
        // ⚠️ Widening the pattern to keep the number alive would have destroyed
        // it: a counter that survives the deletion of what it counted is
        // measuring something nobody chose.
        final shim = File('../src/zenoh_dart.c').readAsStringSync();
        final captures = RegExp('_zd_capture_last_error')
            .allMatches(shim)
            .length;
        expect(
          captures,
          9,
          reason:
              '5 config wrappers + the SHM provider constructor + the open '
              'worker + the definition + one prose reference',
        );
        expect(
          shim,
          isNot(contains('_zd_clear_last_error')),
          reason: 'the clear discipline went with the buffer it guarded',
        );
      },
    );

    // --- Edge cases ---

    test(
      'members hidden or shown by export clauses are visible to the census',
      () {
        // A fenced member becoming public must not be invisible: the census
        // resolves clauses, so it would report the newly-public member.
        //
        // ⛔ THREE TEXT PINS RETIRED AT SEED [API] SLICE 2. They read the door
        // for `hide keyExprString, withLoanedKeyExpr`, `hide
        // encodingWireChannels` and `hide QueryChannel`. The door now
        // allow-lists: those names are excluded by OMISSION FROM A SHOW
        // CLAUSE, so there is no clause text to pin, and the assertions below
        // — which go through `publicMembers` — are what actually carried the
        // property. Re-pointing them at `show` text would re-create a text pin
        // the census already covers.
        final members = publicMembers('lib/zenoh.dart');
        for (final hidden in const [
          'keyExprString',
          'withLoanedKeyExpr',
          'encodingWireChannels',
          'QueryChannel',
        ]) {
          expect(
            members,
            isNot(contains(hidden)),
            reason:
                '$hidden is hidden at the door but the census reports it, '
                'so the census cannot see a hide removal either',
          );
        }
      },
    );

    test('the baselines are re-measured, each with its instrument', () {
      final lib = libDartFiles();
      // ⚠️ EVERY NUMBER HERE MOVED OR WAS RE-DERIVED, and each carries why.
      // ⚠️ ITS SIBLING IS `enrichment_surface_test.dart`'s plain-pattern
      // count, which measures the SAME quantity with a different instrument
      // (that one counts substring OCCURRENCES; this one counts awk LINES).
      // ⛔ They went out of step TWICE in one unit, each time because one was
      // updated and the other was not. If you change this number, change that
      // one -- and vice versa.
      //
      // ⚠️ 105 -> 106 at [SHM] shared-memory-lifetime, and the path is NOT a
      // single step. Named in full, because a net +1 hides a conversion:
      //
      //   105  at [D1]'s close
      //   104  slice 8 CONVERTED ShmProvider._create's throw from the plain
      //        form to the enriched one, so one site left this census as it
      //        entered the fence's
      //   106  slice 10 added two plain throws on the async start-failure
      //        path: the shim's own rejection codes, neither of which has
      //        canon detail to enrich from
      //
      // ⛔⛔ THIS CELL WAS RED FROM SLICE 8 UNTIL SLICE 10 AND NOBODY SAW IT,
      // and that is the finding rather than the number. TWO censuses of this
      // same quantity exist -- this one, and `enrichment_surface_test.dart`'s
      // plain-pattern count. Slice 8 updated THAT one and not this one,
      // because its risk scope ran the file it had edited and not the file
      // that counts the same thing somewhere else.
      //
      // ⚠️ And they are NOT the same instrument: this is an awk LINE count,
      // that is a substring OCCURRENCE count. They agree at 106 today only
      // because no line in `lib` currently carries two `ZenohException(`. They
      // are free to diverge the moment one does, so ⛔ do not "reconcile" them
      // by assuming a mismatch is an error -- check which question you are
      // asking first.
      expect(
        awkCount(lib, RegExp(r'ZenohException\(')),
        // 106 -> 107 at slice 11: close() now ANSWERS an outstanding async
        // request with a plain exception naming that the provider was closed
        // with it in flight. There is no canon detail to enrich from -- the
        // condition is this binding's own -- so the plain form is correct here.
        107,
        reason:
            'the plain form. 105 -> 104 (slice 8 converted one site to '
            'the enriched form) -> 106 (slice 10 added two start-failure '
            'throws). The FENCED (enriched) surface is counted separately, '
            'in enrichment_surface_test.dart — census and fence answer '
            'different questions',
      );
      // ⚠️ 4 -> 5 at [SHM] slice 8, and it is the OTHER HALF of the plain
      // census's 105 -> 104 above: the SAME site, converted rather than
      // added. ⭐ A conversion is the one delta shape that moves two censuses
      // at once in opposite directions, and a reader who saw only this number
      // rise would go looking for a plain throw that was never removed.
      //
      // The site is `ShmProvider._create`. Canon answers all three
      // provider-rejection classes with the same -1, so without its text the
      // one signal a caller gets points away from the cause. The fence in
      // `enrichment_surface_test.dart` is where that widening is DECLARED;
      // this cell only counts.
      expect(
        awkCount(lib, RegExp(r'ZenohException\.enriched\(')),
        5,
        reason:
            '4 call sites + the declaration. 4 -> 5 at [SHM] slice 8: '
            'ShmProvider._create converted from the plain form, which is why '
            'the plain census fell by one in the same commit',
      );
      expect(
        awkCount(lib, RegExp('addError')),
        12,
        reason:
            '2 -> 12, NOT the 2 -> 6 the plan predicted. The plan counted '
            'SEAMS (4); its own uniformity rule requires slots x parsers — '
            'sample 2 + query 2 + reply 3 x TWO independent parsers '
            '(session.dart and querier.dart both parse the same post) = 10 '
            'new',
      );
      // 5 -> 6 at [SHM] slice 10: the async allocator's result handler
      // completes its Future with an error when the shim reports a status the
      // decode seam cannot map. ⚠️ Named rather than bumped -- an added
      // completeError is an added FAILURE PATH, which is exactly the kind of
      // change this census exists to make visible.
      expect(
        awkCount(lib, RegExp('completeError')),
        7,
        reason:
            '5 -> 6 (the async allocation result handler) -> 7 (close() '
            'answering an outstanding request rather than abandoning it). '
            'Each is an added FAILURE PATH, which is what this census makes '
            'visible.',
      );
      expect(
        awkCount(const ['../src/zenoh_dart.c'], RegExp('return -1;')),
        32,
        reason:
            '31 -> 32, and the new one is JUSTIFIED IN PLACE rather than '
            'left bare: an out-of-domain severity really is an invalid '
            'argument, which is what canon Z_EINVAL names, unlike the '
            'allocation failure the shim refuses to spell -1',
      );
      expect(
        awkCount(const [
          '../src/zenoh_dart.h',
        ], RegExp('^FFI_PLUGIN_EXPORT', multiLine: true)),
        // ⚠️ 216 -> 218 at [SHM] shared-memory-lifetime, and the delta is
        // NAMED: `zd_shm_provider_alloc_async` and `zd_shm_async_take`, the
        // async allocation seam, both behind the SHM/unstable guard.
        //
        // ⛔ THIS IS A HEADER-DECLARATION COUNT AND IS BLIND TO THE GUARD --
        // it reads the same for BOTH variants, which is why the membership
        // cell above uses `nm` on the built native instead. The two are kept
        // deliberately: this one cross-checks the linker, and a disagreement
        // between them is the signal, not a defect.
        216,
        reason:
            '216 -> 218 (the two async allocation entries) -> 222 (the '
            'four the deferred provider drop needs) -> 221 '
            '(zd_shm_provider_available removed) -> 216 at [API], the '
            'dead-export prune, and the five are NAMED: zd_bytes_to_string, '
            'zd_bytes_copy_from_str, zd_config_loan, zd_query_keyexpr and '
            'zd_whatami_to_view_string. All five sat OUTSIDE both #if '
            'regions, so the linker cell above moves by the same five on '
            'BOTH variants -- and this cell agreeing with it at 216 is the '
            'cross-check working, not a coincidence. [D1] left this at net '
            'zero over a CHANGED set (-1 reader, +1 log bind)',
      );
    });
  });

  group('[API] S1 — the door census survives a wrapped directive', () {
    late Directory dir;
    late Set<String> full;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('api_s1_door_');
      // ⭐ THE FULL SET IS DERIVED, NOT WRITTEN DOWN. A no-clause fixture
      // gives it, so a declaration added to `lib/src/recv_result.dart` later
      // cannot rot these fixtures silently into asserting a stale number.
      full = publicMembers(_writeFixtureDoor(dir, 'bare', _bareDoor));
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test(
      'a show clause split across lines is honoured, in BOTH wrap shapes',
      () {
        final trailing = publicMembers(
          _writeFixtureDoor(dir, 'show_trailing', _showTrailing),
        );
        final opening = publicMembers(
          _writeFixtureDoor(dir, 'show_opening', _showOpening),
        );
        expect(
          trailing,
          unorderedEquals(_clauseNames),
          reason:
              'the show clause is wholly on the continuation line. BEFORE '
              'the repair this OVER-reported, admitting every one of the '
              '${full.length} declarations in the target, so the door read as '
              'though nothing had been fenced at all',
        );
        expect(
          opening,
          unorderedEquals(_clauseNames),
          reason:
              'the show clause opens on line 1 and continues. BEFORE the '
              'repair this UNDER-reported, dropping the continued name and '
              'reading 1 of ${_clauseNames.length}, so the door read as though '
              'a name had been fenced that was not',
        );
        for (final unshown in full.difference(_clauseNames)) {
          expect(trailing, isNot(contains(unshown)));
          expect(opening, isNot(contains(unshown)));
        }
      },
    );

    test(
      'a hide clause split across lines is honoured, in BOTH wrap shapes',
      () {
        final expected = full.difference(_clauseNames);
        final trailing = publicMembers(
          _writeFixtureDoor(dir, 'hide_trailing', _hideTrailing),
        );
        final opening = publicMembers(
          _writeFixtureDoor(dir, 'hide_opening', _hideOpening),
        );
        expect(
          trailing,
          unorderedEquals(expected),
          reason:
              'the hide clause is wholly on the continuation line. BEFORE '
              'the repair this hid NOTHING AT ALL — it read all '
              '${full.length} declarations',
        );
        expect(
          opening,
          unorderedEquals(expected),
          reason:
              'the hide clause opens on line 1 and continues. BEFORE the '
              'repair this hid only the name on its first line, admitting the '
              'continued one and reading ${full.length - 1}',
        );
        for (final name in _clauseNames) {
          expect(trailing, isNot(contains(name)), reason: '$name is hidden');
          expect(opening, isNot(contains(name)), reason: '$name is hidden');
        }
      },
    );

    test('the unwrapped forms still read identically', () {
      // The repair changed the parser's REACH, not its ANSWER: a directive
      // that never needed accumulating must read exactly as it always did.
      final showFlat = publicMembers(
        _writeFixtureDoor(dir, 'show_one', _showOneLine),
      );
      final hideFlat = publicMembers(
        _writeFixtureDoor(dir, 'hide_one', _hideOneLine),
      );
      for (final wrapped in const [_showTrailing, _showOpening]) {
        expect(
          publicMembers(_writeFixtureDoor(dir, 's${wrapped.length}', wrapped)),
          unorderedEquals(showFlat),
        );
      }
      for (final wrapped in const [_hideTrailing, _hideOpening]) {
        expect(
          publicMembers(_writeFixtureDoor(dir, 'h${wrapped.length}', wrapped)),
          unorderedEquals(hideFlat),
        );
      }
      // And the flat readings are themselves right, so the equality above is
      // not two wrong answers agreeing.
      expect(showFlat, unorderedEquals(_clauseNames));
      expect(hideFlat, unorderedEquals(full.difference(_clauseNames)));
    });

    // --- Edge cases ---

    test('the pre-repair parser was wrong in BOTH directions — a recorded '
        'control', () {
      final trailingRead = _lineByLineMembers(
        _writeFixtureDoor(dir, 'ctl_show_trailing', _showTrailing),
      );
      final openingRead = _lineByLineMembers(
        _writeFixtureDoor(dir, 'ctl_show_opening', _showOpening),
      );
      expect(
        trailingRead,
        unorderedEquals(full),
        reason:
            'OVER-REPORT: parsed line by line, the continuation-line '
            'shape saw no clause on the export line and admitted every one '
            'of the ${full.length} declarations in the target — it read '
            '${trailingRead.length}',
      );
      expect(
        openingRead.length,
        lessThan(_clauseNames.length),
        reason:
            'UNDER-REPORT: the opening-on-line-1 shape read '
            '${openingRead.length} of the ${_clauseNames.length} shown names',
      );
      expect(
        openingRead,
        unorderedEquals(const {'RecvData'}),
        reason:
            'the measured pre-repair reading: the name on the first line '
            'survives, the continued one is dropped',
      );
      // The hide half of the same control, and it fails in both directions
      // too — which is the point: closing one direction closes nothing.
      expect(
        _lineByLineMembers(
          _writeFixtureDoor(dir, 'ctl_hide_trailing', _hideTrailing),
        ),
        unorderedEquals(full),
        reason:
            'the continuation-line hide hid NOTHING, reading '
            '${full.length}',
      );
      expect(
        _lineByLineMembers(
          _writeFixtureDoor(dir, 'ctl_hide_opening', _hideOpening),
        ),
        unorderedEquals(full.difference(const {'RecvData'})),
        reason:
            'the opening-on-line-1 hide hid only the name on its first '
            'line, admitting the continued one and reading '
            '${full.length - 1}',
      );
    });

    test('a directive with no clause is unaffected', () {
      for (final name in const [
        'RecvData',
        'RecvDisconnected',
        'RecvEmpty',
        'RecvResult',
      ]) {
        expect(
          full,
          contains(name),
          reason:
              '$name is a public top-level declaration of the fixture '
              'target and the directive fences nothing, so the census owes '
              'it',
        );
      }
      expect(
        full.where((n) => n.startsWith('_')),
        isEmpty,
        reason: 'a private declaration is not part of any export namespace',
      );
    });

    test('a three-line wrap is honoured, where joining only the next line is '
        'not', () {
      final showDoor = _writeFixtureDoor(dir, 'show_three', _showThreeLine);
      final hideDoor = _writeFixtureDoor(dir, 'hide_three', _hideThreeLine);
      expect(publicMembers(showDoor), unorderedEquals(_clauseNames));
      expect(
        publicMembers(hideDoor),
        unorderedEquals(full.difference(_clauseNames)),
      );
      // ⭐ THE DISCRIMINATOR, RUN RATHER THAN ASSERTED. A repair that joins
      // only the NEXT line reads BOTH two-line fixtures in this group
      // correctly — see the two arms at the bottom — and this one wrongly.
      // That is why the repair accumulates to the terminating `;` instead.
      expect(
        _joinNextLineMembers(showDoor),
        unorderedEquals(const {'RecvData'}),
        reason: 'join-only-the-next-line drops the name on the third line',
      );
      expect(
        _joinNextLineMembers(hideDoor),
        unorderedEquals(full.difference(const {'RecvData'})),
        reason:
            'join-only-the-next-line hides only the name on the second '
            'line',
      );
      expect(
        _joinNextLineMembers(
          _writeFixtureDoor(dir, 'jn_show_trailing', _showTrailing),
        ),
        unorderedEquals(_clauseNames),
        reason:
            'the wrong repair is right here, which is what makes it a '
            'plausible one rather than an obviously wrong one',
      );
      expect(
        _joinNextLineMembers(
          _writeFixtureDoor(dir, 'jn_show_opening', _showOpening),
        ),
        unorderedEquals(_clauseNames),
      );
    });

    test('the census stays a TEXT SCAN and does not follow a re-export', () {
      // ⛔ DELIBERATE, AND GREEN BOTH BEFORE AND AFTER THE REPAIR — a guard
      // on a limit, in the same family as the recorded control above rather
      // than a cell the repair turned green. Teaching the scan to resolve
      // `export 'zenoh.dart';` would move it onto the RESOLVED census's own
      // assumption, and the two instruments are kept apart precisely so a
      // cross-check between them is worth running.
      final door = _writeFixtureDoor(
        dir,
        'reexport',
        "export 'zenoh.dart';\n",
      );
      final members = publicMembers(door);
      for (final name in const ['Session', 'Zenoh', 'ZenohException']) {
        expect(
          members,
          isNot(contains(name)),
          reason:
              '$name is reached through `lib/zenoh.dart`, which this '
              'fixture re-exports. A census surfacing it here would have '
              'followed the re-export, which is the one thing this repair '
              'must not do',
        );
      }
    });
  });
}
