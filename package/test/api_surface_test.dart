// Seed [API] — the API-surface trim. Each public door ALLOW-LISTS what it
// re-exports, and the name set a door resolves to is pinned NAME BY NAME.
//
// ⛔ WHY A COUNT IS NEVER THE ASSERTION HERE. A door's `^export` line count
// answers "how many FILES", not "how many NAMES": a member added to, removed
// from, or fenced in an already-exported file moves nothing it can see, and
// an addition and a removal landing in the same unit cancel in a total.
// Every surface claim below is therefore a membership claim in BOTH
// directions — every expected name present, and nothing present that is not
// expected.
//
// ⭐ TWO INSTRUMENTS, KEPT APART ON PURPOSE.
//
//   * the RESOLVED namespace — `scripts/instruments/export_surface.dart`,
//     run in a subprocess. It asks the ANALYZER what
//     the library exports, so it follows re-export chains and resolves
//     `show`/`hide` exactly as a consumer's compiler does.
//   * the TEXT SCAN — `publicMembers`, a top-level-declaration regex per
//     exported file with the door's clauses applied.
//
// Neither calls the other and they are not folded behind a shared helper.
// The whole value of running both is that they differ in ASSUMPTION: the
// text scan is blind to a declaration its regexes do not match (a record
// return type puts `(` at the start of the line, so `encodingWireChannels`
// is invisible to it), while the resolved census is blind to nothing but
// costs an analyzer run. Their agreement means something only while they
// stay separate.
//
// ⭐ THIS FILE IS EXTENDED BY THE LATER SLICES OF THIS UNIT — one group per
// door-level claim, shared apparatus at the top.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:test/test.dart';
// The LINKER, reached from Dart. One cell below asks the loaded native
// whether a `zd_fin_*` entry point exists, which is a different question in a
// different tool from any scan of the Dart source — and `nativeLibrary` is
// where the finalizer family is resolved from in the first place.
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/zenoh_unstable.dart' show ZenohFeatures;

// ⚠️ `exportDirectives` is the DIRECTIVE SPLITTER, not a census. Reusing it
// here does not breach the "the two censuses share no code" constraint that
// the agreement cell below rests on: that constraint is about
// `publicMembers` and the resolved instrument, and this splitter is neither.
// Reusing it is what makes the wrapped directive be read by the project's
// own repaired parser rather than by a second copy that could differ.
import 'diagnosability_baselines_test.dart'
    show exportDirectives, publicMembers;
import 'helpers/changelog_section.dart';

// ⚖️ MOVED OUT OF `development/` 2026-09-12 (roadmap R8). Ruling 9 certifies
// the candidate by running this suite in the PUBLIC repository, which has no
// `development/` tree — so an instrument this cell cannot run without would
// have made the cell uncertifiable there. `scripts/` is carried by the release
// assembly; `package/` is not an option, because the instrument imports
// `package:analyzer`, a dev dependency, and must stay outside the publish
// boundary (the README beside it says so).
const _exportSurface = '../scripts/instruments/export_surface.dart';

/// The RESOLVED export namespace of [door] — what the analyzer says a
/// consumer of the library can actually name.
///
/// ⚠️ `--packages` is required and is what keeps the instrument out of the
/// publish boundary: it imports `package:analyzer`, a transitive dev
/// dependency, so it borrows the package's own resolution. See the README
/// beside it.
Set<String> resolvedExportNamespace(String door) {
  final result = Process.runSync(
    Platform.resolvedExecutable,
    ['run', '--packages=.dart_tool/package_config.json', _exportSurface, door],
  );
  expect(
    result.exitCode,
    0,
    reason:
        'export_surface.dart failed on $door — a partial resolution '
        'would silently UNDER-report, so this is fatal rather than '
        'tolerated:\n${result.stdout}\n${result.stderr}',
  );
  return const LineSplitter()
      .convert(result.stdout as String)
      .where((l) => l.contains(','))
      .map((l) => l.split(',')[1])
      .toSet();
}

/// The 45 names `lib/zenoh.dart` resolved to at the fork point, measured with
/// both instruments before the allow-list conversion.
///
/// ⛔ THIS IS THE HISTORICAL SET AND IT DOES NOT MOVE. What the door is
/// expected to hand out TODAY is [stableDoorNames], derived below by removing
/// [sessionOpenHelpers] from it. The two are kept apart so the delta is
/// SUBTRACTED rather than transcribed: a second hand-written list of 42 could
/// drop a fourth name and no cell here would notice.
const stableDoorNamesAtFork = <String>{
  'ChannelKind',
  'Config',
  'CongestionControl',
  'ConsolidationMode',
  'Encoding',
  'EntityGlobalId',
  'Hello',
  'KeyExpr',
  'LivelinessToken',
  'Locality',
  'LogRecord',
  'LogSeverity',
  'Priority',
  'Publisher',
  'PullQueryable',
  'PullReplies',
  'PullSubscriber',
  'Querier',
  'Query',
  'QueryTarget',
  'Queryable',
  'RecvData',
  'RecvDisconnected',
  'RecvEmpty',
  'RecvResult',
  'Reply',
  'ReplyError',
  'ReplyKeyExpr',
  'Sample',
  'SampleChannel',
  'SampleKind',
  'Session',
  'Subscriber',
  'Timestamp',
  'WhatAmI',
  'ZBytes',
  'ZBytesWriter',
  'ZDeserializer',
  'ZSerializer',
  'Zenoh',
  'ZenohException',
  'ZenohId',
  // ⚠️ The three session-open helpers, public by accident of a bare
  // `export`. They leave in the fourth slice of this unit, and they are
  // subtracted below rather than deleted here, so this set stays a record of
  // what the door handed out before this unit touched it.
  'completeOpenFromPost',
  'openFailureMessage',
  'openStartFailureMessage',
};

/// The three session-open helpers this unit's fourth slice un-exports.
///
/// They were public by accident of a bare `export 'src/session.dart';` — none
/// was ever decided on. Each carries `@visibleForTesting` and now `@internal`
/// beside it, and naming one from a consumer is a COMPILE ERROR
/// (`undefined_function`), not a warning: a `show` clause fences a top-level
/// name outright where an annotation only complains about it.
const sessionOpenHelpers = <String>{
  'completeOpenFromPost',
  'openFailureMessage',
  'openStartFailureMessage',
};

/// What `lib/zenoh.dart` is expected to hand out as this unit now stands — 42.
///
/// ⭐ DERIVED, NOT LISTED. Every cell that asks what the stable door exports
/// reads this, and the unstable door's expectation is built on it too, so the
/// three removals reach both doors from one subtraction.
final Set<String> stableDoorNames = stableDoorNamesAtFork.difference(
  sessionOpenHelpers,
);

/// The names the stable door used to fence with a `hide` clause, and now
/// excludes by omitting them from a `show` clause.
const stableDoorExcluded = <String>[
  'encodingWireChannels',
  'keyExprString',
  'QueryChannel',
  'requireCongestionControlSupported',
  'undecodableError',
  'undecodableRc',
  'withLoanedKeyExpr',
];

/// The 20 names `lib/zenoh_unstable.dart` adds on top of the stable door.
///
/// Derived from the per-file resolved census of the 11 libraries under
/// `lib/src/unstable/` — 22 declarations across them, less `requireShm` and
/// `requireUnstable`, which the one `show` clause the door already carried
/// was excluding before this unit began.
///
/// ⚠️ ENUMERATED, NOT COUNTED, and the door's expected surface is BUILT from
/// this set plus [stableDoorNames] rather than listed a second time. So when
/// this unit's fourth slice takes three names off the stable door, this door
/// follows with nothing in this list to edit.
///
/// ⛔ ONE CELL BELOW STILL WRITES THE TOTAL DOWN, deliberately — the sum is
/// what says this enumeration matches the measurement it came from, and a
/// derived sum cannot say that about itself. That cell is the single place
/// the fourth and fifth slices re-point, and it names them.
const unstableOnlyNames = <String>{
  'AdvancedPublisher',
  'AdvancedPublisherCacheOptions',
  'AdvancedPublisherOptions',
  'AdvancedSession',
  'AdvancedSubscriber',
  'AdvancedSubscriberOptions',
  'AllocAlignment',
  'AllocError',
  'AllocErrorKind',
  'AllocOk',
  'AllocResult',
  'DetectPublishersOptions',
  'HeartbeatMode',
  'LayoutError',
  'LayoutErrorKind',
  'MissEvent',
  'ShmBytes',
  'ShmMutBuffer',
  'ShmProvider',
  'ZenohFeatures',
};

/// The two names `src/unstable/features.dart` declares beside `ZenohFeatures`
/// and the door has never handed out.
///
/// ⭐ THEY ARE THE ONE PLACE THIS DOOR WAS ALREADY ALLOW-LISTING. Everything
/// else on it was bare, so these two are the only names whose exclusion the
/// conversion had to carry across unchanged rather than newly decide.
const unstableDoorExcluded = <String>['requireShm', 'requireUnstable'];

/// The outcome of analysing a throwaway consumer probe.
typedef AnalyzeResult = ({int exitCode, String output});

/// Analyses [body] from a CONSUMER's position — outside this package's tree.
///
/// ⭐ This is the shape `last_error_binding_test.dart:517-560` already uses,
/// kept file-private here rather than lifted into `test/helpers/`. The lift
/// would move its `.dart_tool/package_config.json` read out of a
/// `*_test.dart` file, and `pinnedReadSites()` filters on exactly that
/// suffix — so extracting it would silently shrink the instrument that keeps
/// this corpus's read sites honest. Every consumer of this harness has its
/// cells in this one file, so file-private IS shared here.
///
/// [segment] places the probe under a path segment of that name. It is not
/// cosmetic: MEASURED, a probe under a directory called `test` is treated as
/// TEST CODE, where `@visibleForTesting` says nothing and `@internal` still
/// warns. That difference is the whole reason the weaker annotation is not
/// enough on its own.
///
/// ⛔ RESOLUTION IS ASSERTED BEFORE ANY DIAGNOSTIC IS READ. `dart analyze`
/// exits 0 / 2 / 3 for clean / warnings / errors — MEASURED — and a probe
/// whose `package_config.json` never arrived reports `uri_does_not_exist` at
/// exit 3, the SAME exit code a correctly un-exported function produces.
/// The exit code cannot tell those apart, so a harness that read it alone
/// would report a fence as having fired when the probe never resolved at all.
///
/// [withoutPackageConfig] omits the resolution file, so the guard below can be
/// DRIVEN rather than asserted. It exists for one cell and nothing else uses
/// it: a guard nobody has watched fire is a guard nobody knows works.
AnalyzeResult analyzeConsumerProbe(
  String body, {
  String? segment,
  bool withoutPackageConfig = false,
}) {
  final packageRoot = Directory.current.absolute.path;
  final dir = Directory.systemTemp.createTempSync('zd_api_surface_');
  try {
    final config = jsonDecode(
      File('.dart_tool/package_config.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    for (final entry in config['packages'] as List<dynamic>) {
      final package = entry as Map<String, dynamic>;
      if (package['name'] == 'zenoh_dart') {
        package['rootUri'] = Uri.file('$packageRoot/').toString();
      }
    }
    if (!withoutPackageConfig) {
      Directory('${dir.path}/.dart_tool').createSync();
      File('${dir.path}/.dart_tool/package_config.json')
          .writeAsStringSync(jsonEncode(config));
    }
    final probeDir = segment == null ? dir.path : '${dir.path}/$segment';
    if (segment != null) Directory(probeDir).createSync();
    File('$probeDir/probe.dart').writeAsStringSync(body);

    final result = Process.runSync(
      Platform.resolvedExecutable,
      ['analyze', dir.path],
    );
    final output = '${result.stdout}${result.stderr}';
    // ⛔ An instrument that cannot run is not an instrument that found
    // nothing. Without this, a probe that never resolved reads as a fence.
    expect(
      output,
      isNot(contains('uri_does_not_exist')),
      reason:
          'the consumer probe never resolved this package, so every '
          'diagnostic below is about a missing import rather than about a '
          'fence:\n$output',
    );
    return (exitCode: result.exitCode, output: output);
  } finally {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// A consumer probe naming the three session-open helpers through the door.
///
/// ⚠️ EVERY CALL IS TYPE-CORRECT AS THE PACKAGE STOOD BEFORE THIS SLICE. That
/// is deliberate: a wrong-arity call would draw its own errors, and those
/// would be indistinguishable in the output from the fence this cell is
/// about. With the calls correct, the ONLY thing that can change between the
/// two states is whether the names resolve.
const namesTheSessionHelpers = '''
import 'dart:async';

import 'package:zenoh_dart/zenoh.dart';

String a() => openFailureMessage(1, callerSuppliedConfig: true);
String b() => openStartFailureMessage(12);
void c(Completer<Session> completer) =>
    completeOpenFromPost(<Object>[], completer, callerSuppliedConfig: true);
''';

/// A consumer probe reaching MEMBERS of two shown classes.
///
/// ⚠️ Both constructors are reachable today and this cell is about that fact,
/// not about whether they draw a diagnostic. `Query`'s gains `@internal` in a
/// later slice of this unit; `Timestamp.fromRaw` carries no annotation at any
/// point and is the arm that stays diagnostic-free throughout.
const reachesMembersOfShownClasses = '''
import 'dart:typed_data';

import 'package:zenoh_dart/zenoh.dart';

Query q() => Query(handle: 42, keyExpr: 'x', parameters: '');
Timestamp t() => Timestamp.fromRaw(Uint8List(24));
''';

/// A consumer probe naming four of the ten pull-surface test instruments.
///
/// ⚠️ EVERY REFERENCE IS TYPE-CORRECT. The probe takes each receiver as a
/// PARAMETER rather than constructing one: none of the three classes has a
/// consumer-reachable constructor, and a construction error would land in the
/// same output as the diagnostics these cells are about, indistinguishable
/// from them. With the calls correct, the only thing that can change between
/// the before and after states is what the analyzer says about the ACCESS.
const namesThePullTestInstruments = '''
import 'package:zenoh_dart/zenoh.dart';

int a(PullSubscriber s) => s.teeAddressForTesting;
int b(PullSubscriber s) => s.handlerAddressForTesting;
int c(PullReplies r) => r.teeAddressForTesting;
int d(PullQueryable q) => q.handlerAddressForTesting;
''';

/// The member names [namesThePullTestInstruments] reaches, for cells that ask
/// what the analyzer said about each one.
const pullInstrumentsNamedByTheProbe = <String>[
  'teeAddressForTesting',
  'handlerAddressForTesting',
];

/// One `…ForTesting` getter, with the annotations sitting directly above it.
typedef PullTestInstrument = ({
  String file,
  String type,
  String name,
  List<String> annotations,
});

/// The three pull-surface libraries declaring the ten test instruments.
const pullInstrumentFiles = <String>[
  'lib/src/pull_replies.dart',
  'lib/src/pull_subscriber.dart',
  'lib/src/pull_queryable.dart',
];

/// Every `…ForTesting` getter across [pullInstrumentFiles], with its declared
/// return type and its annotation block.
///
/// ⭐ IT READS THE DECLARATIONS, IT DOES NOT COUNT THE ANNOTATIONS. A scan
/// for `@internal` would report ten happily while some eleventh instrument
/// sat unannotated beside them; walking UP from each declaration is what lets
/// a cell say the population is covered rather than that ten things exist.
/// The `type` field is read from the declaration for the same reason: which
/// getters hand out a raw address is a property of the source, not a list
/// transcribed into the test.
List<PullTestInstrument> pullTestInstruments() {
  final declaration = RegExp(r'^  (\w+) get (\w+ForTesting)\b');
  final found = <PullTestInstrument>[];
  for (final path in pullInstrumentFiles) {
    final lines = File(path).readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final match = declaration.firstMatch(lines[i]);
      if (match == null) continue;
      final annotations = <String>[];
      for (var j = i - 1; j >= 0 && lines[j].trimLeft().startsWith('@'); j--) {
        annotations.add(lines[j].trim());
      }
      found.add((
        file: path.split('/').last,
        type: match.group(1)!,
        name: match.group(2)!,
        annotations: annotations,
      ));
    }
  }
  return found;
}

/// The source lines above [declaration] in [path], nearest first.
///
/// ⛔ IT ASSERTS THAT THE DECLARATION WAS FOUND. `indexOf` answers -1 for a
/// declaration that has been renamed, and a reader walking up from -1 sees an
/// empty block — which every caller below would report as "the dartdoc says
/// nothing" rather than as "the site this cell names is gone".
///
/// The two readers that follow differ only in what they keep, so the walk
/// itself lives here once.
Iterable<String> linesAbove(String path, String declaration) sync* {
  final source = File(path).readAsStringSync();
  final at = source.indexOf(declaration);
  expect(
    at,
    greaterThanOrEqualTo(0),
    reason: '$declaration not found in $path',
  );
  final lines = source.substring(0, at).split('\n');
  for (var i = lines.length - 2; i >= 0; i--) {
    yield lines[i];
  }
}

/// The dartdoc block immediately above [declaration] in [path], flattened.
///
/// ⚠️ Lowercased by default, so needles must be lowercase too. Annotation
/// lines and blank lines are skipped, which is what lets this keep working
/// after a slice adds `@internal` above an existing `@visibleForTesting`.
///
/// ⭐ FILE-SCOPE BECAUSE TWO GROUPS READ IT. It was group-private when the
/// documentation-correction group introduced it, and the crash-escape group
/// below reads the same shape. A second copy would be a second thing to keep
/// right, and the two would drift the first time one was fixed.
///
/// [lowercase] `false` keeps the original case. One cell needs that: telling
/// a MEMBER reference (`[reply]`) from a TYPE reference (`[Queryable]`)
/// inside a dartdoc is a case distinction, and lowercasing destroys it. The
/// default is unchanged, so every caller that existed before reads exactly
/// what it read before.
String dartdocAbove(
  String path,
  String declaration, {
  bool lowercase = true,
}) {
  final doc = <String>[];
  for (final raw in linesAbove(path, declaration)) {
    final line = raw.trimLeft();
    if (line.startsWith('///')) {
      doc.insert(0, line.substring(3).trim());
    } else if (line.startsWith('@') || line.isEmpty) {
      continue;
    } else {
      break;
    }
  }
  final flat = doc
      .join(' ')
      .replaceAll('*', '')
      .replaceAll(RegExp(r'\s+'), ' ');
  return lowercase ? flat.toLowerCase() : flat;
}

/// [doc] with every dated-correction parenthetical removed.
///
/// ⛔ THIS PROJECT DELIBERATELY PRESERVES RETRACTED TEXT — see
/// `Session.declarePullQueryable`, whose shipped dartdoc quotes its own
/// struck claim and is in the generated reference today. The consequence
/// nobody prices: a bare `isNot(contains(<claim>))` cannot tell STILL
/// ASSERTED from QUOTED AS STRUCK, and answers "still there" on a
/// correctly corrected document, permanently.
///
/// So the operative text is what gets asserted on, and the presence of a
/// correction marker is checked separately — otherwise this strip could
/// silently become a no-op and the cell would pass by removing nothing.
String operative(String doc) =>
    doc.replaceAll(RegExp(r'\(corrected:[^)]*\)'), ' ');

/// The annotation lines sitting directly above [declaration] in [path].
///
/// ⭐ IT WALKS UP FROM THE DECLARATION rather than scanning the file for
/// `@internal`. A file-wide scan answers "does this file contain the
/// annotation", which is true whenever any other member carries it — so a
/// cell built on one passes while the site it names carries nothing. Same
/// reason [pullTestInstruments] walks up rather than counting.
List<String> annotationsAbove(String path, String declaration) {
  final found = <String>[];
  for (final raw in linesAbove(path, declaration)) {
    final line = raw.trim();
    if (line.startsWith('@')) {
      found.add(line);
    } else if (line.isEmpty) {
      continue;
    } else {
      break;
    }
  }
  return found;
}

/// A consumer probe naming all three of the crash escapes.
///
/// ⚠️ EVERY CALL IS TYPE-CORRECT. Two of the three take a `Pointer<Void>`,
/// which the probe takes as a PARAMETER rather than fabricating: a wrong-type
/// argument would land its own error in the same output as the diagnostic
/// these cells are about, indistinguishable from it. With the calls correct,
/// the only thing that can change between the before and after states is what
/// the analyzer says about naming the constructor.
///
/// It imports the unstable door alone. That door re-exports `zenoh.dart` in
/// full, so one import reaches all three names.
const namesTheThreeCrashEscapes = '''
import 'dart:ffi';

import 'package:zenoh_dart/zenoh_unstable.dart';

Query q() => Query(handle: 42, keyExpr: 'x', parameters: '');
ZBytes b(Pointer<Void> p) => ZBytes.fromNative(p);
ShmMutBuffer s(Pointer<Void> p) => ShmMutBuffer.fromNative(p);
''';

void main() {
  group('[API] the stable door allow-lists, and its surface does not move', () {
    late Set<String> resolved;

    setUpAll(() {
      // One analyzer run for the whole group: the instrument costs seconds,
      // and three cells read the same answer.
      resolved = resolvedExportNamespace('lib/zenoh.dart');
    });

    test('every export directive on the stable door carries a show clause', () {
      final directives = exportDirectives(
        const LineSplitter().convert(File('lib/zenoh.dart').readAsStringSync()),
      );
      expect(
        directives,
        hasLength(36),
        reason:
            'the door lost or gained a directive; the surface cells '
            'below say whether the NAME set moved with it',
      );
      for (final directive in directives) {
        expect(
          directive,
          contains(' show '),
          reason:
              'deny-listing survives here: $directive. A file exported '
              'bare hands out every public declaration it will EVER carry, '
              'so a helper added to it later becomes public with nobody '
              'deciding that',
        );
        expect(
          directive,
          isNot(contains(' hide ')),
          reason:
              'a hide clause survives here: $directive. Allow-listing '
              'and deny-listing on one door means the reader cannot tell '
              'which discipline the next directive follows',
        );
      }
    });

    test('the exported name set is unchanged by the conversion', () {
      // ⚠️ ASSERTED NAME BY NAME, IN BOTH DIRECTIONS, never counted — an
      // addition and a removal cancel in a total and this conversion is
      // exactly the shape of change that could carry both.
      for (final name in stableDoorNames) {
        expect(
          resolved,
          contains(name),
          reason:
              '$name left the stable door. The conversion to show '
              'clauses must move NO name; removals are the fourth slice',
        );
      }
      expect(
        resolved.difference(stableDoorNames),
        isEmpty,
        reason:
            'the conversion ADDED public surface, which a count could '
            'not have told apart from a faithful conversion',
      );
    });

    test('the export LINE count is untouched', () {
      final exports = File('lib/zenoh.dart')
          .readAsLinesSync()
          .where((l) => l.startsWith('export'))
          .length;
      expect(
        exports,
        36,
        reason:
            'a show clause fences a directive, it does not add one — and '
            'a wrapped directive contributes ONE line starting with export',
      );
      // The same number is pinned in four other places. A door change that
      // moved it would go red there too, so this cell asserts the pins
      // still SAY 36 rather than leaving the agreement to a later run.
      const pins = {
        'test/finalizer_ownership_test.dart': 'expect(exports, 36',
        'test/log_sink_test.dart': 'expect(exports, hasLength(36))',
        'test/blockfirst_stable_guard_test.dart':
            'expect(exports, hasLength(36))',
        'test/diagnosability_baselines_test.dart':
            "contains('expect(exports, "
            "36'",
      };
      pins.forEach((path, pin) {
        expect(
          File(path).readAsStringSync(),
          contains(pin),
          reason:
              '$path no longer pins the export count at 36, so the door '
              'and its pins disagree',
        );
      });
    });

    test('the two instruments agree, and they share no code', () {
      final scanned = publicMembers('lib/zenoh.dart');
      expect(
        scanned,
        unorderedEquals(resolved),
        reason:
            'the text scan and the resolved namespace disagree. One of '
            'them is wrong about this door, and which one is not decidable '
            'from either alone',
      );
      expect(scanned, unorderedEquals(stableDoorNames));
      // ⛔ AND THEY MUST STAY APART. Two instruments that share an
      // implementation agree by construction, which is not evidence.
      expect(
        File(_exportSurface).readAsStringSync(),
        isNot(contains('publicMembers')),
        reason:
            'the resolved instrument reaches for the text scan, so its '
            'agreement with it is no longer independent',
      );
      final scan = File('test/diagnosability_baselines_test.dart')
          .readAsStringSync();
      expect(
        scan,
        isNot(contains('export_surface')),
        reason:
            'the text scan reaches for the resolved instrument, so its '
            'agreement with it is no longer independent',
      );
    });

    // --- Edge cases ---

    test('the seven previously-hidden names are still absent', () {
      // They are excluded by OMISSION FROM A SHOW CLAUSE now, not by a hide
      // clause — a different mechanism reaching the same surface, which is
      // the one thing this slice had to get right.
      for (final name in stableDoorExcluded) {
        expect(
          resolved,
          isNot(contains(name)),
          reason:
              '$name became public surface when the door stopped hiding '
              'it, which is the exact regression the conversion risks',
        );
      }
      final scanned = publicMembers('lib/zenoh.dart');
      for (final name in stableDoorExcluded) {
        expect(scanned, isNot(contains(name)), reason: '$name, by text scan');
      }
    });

    test('a wrapped directive is present, so the census meets a real door', () {
      // ⛔ THE 80-COLUMN LINT DOES NOT FORCE THIS WRAP, AND AN IMPLEMENTER
      // WHO CHECKS WILL FIND IT DOES NOT. Measured: an 85-column
      // `export … show …;` draws nothing while an 82-column ordinary line
      // draws `lines_longer_than_80_chars` in the same run — the rule
      // exempts the directive. THIS CELL is what mandates the wrap, so that
      // the directive parser repaired in the first slice of this unit is
      // exercised by a real door and not only by its own fixtures.
      //
      // ⭐ THE DIRECTIVE IS CHOSEN BECAUSE NOTHING LATER SHORTENS IT.
      // `src/recv_result.dart` is untouched by every later slice of this
      // unit. The longest directive on the door is `src/session.dart`, and
      // wrapping that one instead would have made this cell go red three
      // slices from now: it loses three names in the fourth slice and comes
      // back well under the wrap.
      final lines = File('lib/zenoh.dart').readAsLinesSync();
      final wrappedHeads = [
        for (final line in lines)
          if (line.startsWith('export ') && !line.contains(';')) line,
      ];
      expect(
        wrappedHeads,
        contains("export 'src/recv_result.dart'"),
        reason:
            'the recv_result directive is no longer wrapped, so no real '
            'door exercises multi-line directive parsing',
      );
      // And it is READ correctly when wrapped: the parser must recover the
      // whole clause, not the head line.
      expect(
        exportDirectives(lines),
        contains(
          "export 'src/recv_result.dart' "
          'show RecvData, RecvDisconnected, RecvEmpty, RecvResult;',
        ),
      );
    });
  });

  group(
    '[API] the unstable door allow-lists, and its surface does not move',
    () {
      late Set<String> resolved;
      late List<String> directives;

      setUpAll(() {
        // One analyzer run for the whole group, and one read of the door: the
        // resolved instrument costs seconds and four cells want the same two
        // answers.
        resolved = resolvedExportNamespace('lib/zenoh_unstable.dart');
        directives = exportDirectives(
          const LineSplitter().convert(
            File('lib/zenoh_unstable.dart').readAsStringSync(),
          ),
        );
      });

      test('every export of a src path carries a show clause', () {
        expect(
          directives,
          hasLength(12),
          reason:
              'the door lost or gained a directive; the surface cells '
              'below say whether the NAME set moved with it',
        );
        final leaves = [
          for (final directive in directives)
            if (directive.contains("'src/unstable/")) directive,
        ];
        expect(
          leaves,
          hasLength(11),
          reason:
              'the leaf directives are what this cell ranges over, so a '
              'miscount here would let one of them go unchecked while the '
              'loop below still passed',
        );
        for (final directive in leaves) {
          expect(
            directive,
            contains(' show '),
            reason:
                'deny-listing survives here: $directive. A file exported '
                'bare hands out every public declaration it will EVER carry, '
                'so a helper added to it later becomes public with nobody '
                'deciding that',
          );
          expect(
            directive,
            isNot(contains(' hide ')),
            reason:
                'a hide clause survives here: $directive. Allow-listing '
                'and deny-listing on one door means the reader cannot tell '
                'which discipline the next directive follows',
          );
        }
      });

      test('the self-referential re-export stays bare, and the exemption is '
          'named', () {
        // ⭐ THE GROUND, STATED — this cell is not "one directive happens to
        // have no clause". `export 'zenoh.dart';` is the one directive on
        // this door that is deliberately NOT allow-listed, because it
        // INHERITS the stable door's own `show`: every name it can hand out
        // was already decided there, one reviewable line at a time. Repeating
        // that list here would create a SECOND PLACE TO FORGET, and the two
        // copies would diverge the first time the stable door changed —
        // which it does inside this very unit. The other 11 directives name a
        // leaf library that allow-lists nothing itself, so for those the
        // decision has nowhere else to live and the clause is mandatory.
        //
        // ⚠️ The size of the inherited list is deliberately not written down
        // here; a later slice of this unit moves it.
        final selfReferential = [
          for (final directive in directives)
            if (directive.contains("'zenoh.dart'")) directive,
        ];
        expect(
          selfReferential,
          equals(["export 'zenoh.dart';"]),
          reason:
              'the re-export of the stable door gained a clause, or was '
              'written more than once. Either way the inheritance above stops '
              'being the single decision it is exempt for being',
        );
        // Paired with a PRESENCE assertion, because the exemption is only
        // defensible while the bare directive is doing the work it is exempt
        // for doing. Delete the line and the cell above still passes.
        expect(
          resolved,
          containsAll(stableDoorNames),
          reason:
              'the unstable door stopped being a strict superset of the '
              'stable one, so the bare re-export is no longer inheriting the '
              "stable door's decisions",
        );
      });

      test('the exported name set is unchanged by the conversion', () {
        // ⚠️ ASSERTED NAME BY NAME, IN BOTH DIRECTIONS, never counted — an
        // addition and a removal cancel in a total and this conversion is
        // exactly the shape of change that could carry both.
        final expected = {...stableDoorNames, ...unstableOnlyNames};
        // ⛔ THE ONE WRITTEN-DOWN TOTAL ON THIS DOOR. It is here because the two
        // enumerated sets are a TRANSCRIPTION of a measurement, and a sum built
        // out of them cannot tell you the transcription was faithful.
        // ⚠️ RE-POINTED 65 -> 62 BY THIS UNIT'S FOURTH SLICE, which un-exports
        // completeOpenFromPost, openFailureMessage and openStartFailureMessage
        // from the stable door that this one re-exports whole. The delta is
        // NAMED so the number stays an instrument rather than a figure that
        // gets bumped whenever it goes red. (The comment this replaces said the
        // FIFTH slice would do it; the fourth does both halves, because the
        // door change and the annotation are one indivisible edit.)
        expect(
          expected,
          hasLength(62),
          reason:
              'the two enumerated sets no longer sum to the door as it was '
              'measured, so the expectation the loop below checks against is '
              'itself the thing that moved',
        );
        for (final name in expected) {
          expect(
            resolved,
            contains(name),
            reason:
                '$name left the unstable door. The conversion to show '
                'clauses must move NO name; removals are the fourth and fifth '
                'slices',
          );
        }
        expect(
          resolved.difference(expected),
          isEmpty,
          reason:
              'the conversion ADDED public surface, which a count could '
              'not have told apart from a faithful conversion',
        );
      });

      test('the export LINE count is untouched', () {
        final exports = File('lib/zenoh_unstable.dart')
            .readAsLinesSync()
            .where((l) => l.startsWith('export'))
            .length;
        expect(
          exports,
          12,
          reason:
              'a show clause fences a directive, it does not add one — and '
              'a wrapped directive contributes ONE line starting with export, '
              'because a continuation line is indented',
        );
        // ⚠️ UNLIKE THE STABLE DOOR, THIS NUMBER IS PINNED NOWHERE ELSE. Two
        // other files read this door's TEXT and neither counts its lines —
        // they assert two strings stay absent from it. Both are checked
        // below, so a comment written here cannot break them from a distance.
        const readers = {
          'test/shm_alloc_strategy_test.dart': 'strategy',
          'test/resolved_library_path_test.dart': 'native_lib.dart',
        };
        final door = File('lib/zenoh_unstable.dart').readAsStringSync();
        readers.forEach((path, forbidden) {
          expect(
            File(path).readAsStringSync(),
            contains("isNot(contains('$forbidden'))"),
            reason:
                '$path no longer forbids that string, so this cell is '
                'guarding a contract that has moved',
          );
          expect(
            door,
            isNot(contains(forbidden)),
            reason:
                'the door now contains a string $path asserts is absent '
                'from it. A show list or a comment added here is enough to '
                'do this',
          );
        });
      });

      // --- Edge cases ---

      test('the two names already excluded stay excluded', () {
        // They were excluded before this unit began, by the door's one
        // pre-existing `show` clause. The conversion had to carry that across
        // unchanged while giving the other ten directives the same treatment.
        final scanned = publicMembers('lib/zenoh_unstable.dart');
        // Paired with a PRESENCE assertion: every claim below would pass
        // trivially if the features directive had vanished outright.
        expect(resolved, contains('ZenohFeatures'));
        expect(scanned, contains('ZenohFeatures'));
        for (final name in unstableDoorExcluded) {
          expect(
            resolved,
            isNot(contains(name)),
            reason:
                '$name became public surface. It is the unstable-tier '
                'gate the src/ files call before touching a native that may '
                'not carry the feature, not something a consumer names',
          );
          expect(scanned, isNot(contains(name)), reason: '$name, by text scan');
        }
      });

      test('the arithmetic closes against the stable door', () {
        // ⛔ WHAT THIS CELL IS FOR. The two doors are measured independently,
        // and nothing so far says their two readings are consistent with each
        // other. If this door's total held while a name moved between the
        // INHERITED half and the UNSTABLE-ONLY half, both name-by-name cells
        // would still pass. What closes that is the two halves summing to the
        // door EXACTLY, with no name in both — which is what says no name
        // reaches this door by a path neither list records.
        //
        // ⚠️ Written as a relation between the three sets, not as three
        // figures: the inherited half loses names inside this unit and the
        // relation has to survive that.
        expect(
          resolved.difference(stableDoorNames),
          unorderedEquals(unstableOnlyNames),
          reason:
              'the names this door adds on top of the stable one are no '
              'longer the enumerated 20',
        );
        expect(
          stableDoorNames.intersection(unstableOnlyNames),
          isEmpty,
          reason:
              'a name is listed in both halves, so their totals would sum '
              'to more than the door and the arithmetic below would be an '
              'accident',
        );
        expect(
          stableDoorNames.length + unstableOnlyNames.length,
          resolved.length,
          reason:
              '${stableDoorNames.length} + ${unstableOnlyNames.length} no '
              'longer equals ${resolved.length}',
        );
      });
    },
  );

  group('[API] the three session-open helpers leave the public API', () {
    test('a consumer can no longer name the three functions', () {
      // ⭐ THE PRE-STATE IS MEASURED, NOT ASSUMED. Before this slice the same
      // probe RESOLVED all three and drew
      // invalid_use_of_visible_for_testing_member from a consumer's lib/ --
      // never an undefined-name error. So this cell records a TRANSITION
      // rather than a state that might always have held.
      final result = analyzeConsumerProbe(namesTheSessionHelpers);
      for (final name in sessionOpenHelpers) {
        expect(
          result.output,
          contains(name),
          reason:
              'the analyzer says nothing about $name at all, so this '
              'cell is not measuring what it thinks:\n${result.output}',
        );
      }
      expect(
        result.output,
        contains('undefined_function'),
        reason:
            'the helpers still resolve from a consumer, so the show '
            'clause is not fencing them:\n${result.output}',
      );
      // ⛔ AND THE FENCE IS THE show CLAUSE, NOT THE ANNOTATION. If the
      // annotation were doing the work these would be warnings and the names
      // would still resolve. A name that is not shown does not exist.
      expect(
        result.output,
        isNot(contains('invalid_use_of_visible_for_testing_member')),
        reason:
            'the helpers are reported as visible-for-testing members, '
            'which means they still RESOLVE -- a warning is not a '
            'fence:\n${result.output}',
      );
    });

    test('the show conversion fences top-level names only, and the limit is '
        'measured rather than argued', () {
      // ⛔ THE ASSERTION IS *RESOLVES*, NOT *DRAWS NOTHING*. A later slice of
      // this unit annotates Query's constructor @internal, at which point the
      // Query arm draws invalid_use_of_internal_member. RESOLUTION is the
      // property this criterion is about: `show Query;` cannot fence a MEMBER
      // of Query, and an annotation is a warning rather than a fence.
      // Timestamp.fromRaw is carried alongside as the arm that stays
      // unannotated through the whole unit, so the property is still
      // witnessed diagnostic-free after that slice lands.
      final result = analyzeConsumerProbe(reachesMembersOfShownClasses);
      for (final undefined in const [
        'undefined_function',
        'undefined_class',
        'undefined_method',
        'undefined_identifier',
      ]) {
        expect(
          result.output,
          isNot(contains(undefined)),
          reason:
              'a member of a SHOWN class stopped resolving, which a show '
              'clause cannot do -- so this cell is measuring something other '
              'than the limit it is about:\n${result.output}',
        );
      }
      // The arm that stays annotation-free for the rest of the unit.
      expect(
        result.output,
        isNot(contains('timestamp.dart')),
        reason:
            'Timestamp.fromRaw drew a diagnostic. It carries neither '
            "annotation and is this cell's diagnostic-free witness; if it "
            'stops being one the property has to be re-established '
            'elsewhere:\n${result.output}',
      );
    });

    test('the exported name set moves by exactly three, and the three are '
        'named', () {
      final stable = resolvedExportNamespace('lib/zenoh.dart');
      final unstable = resolvedExportNamespace('lib/zenoh_unstable.dart');
      expect(stable, hasLength(42));
      expect(unstable, hasLength(62));
      // ⛔ NAMED, NOT COUNTED. A count of 42 is equally consistent with three
      // removed and with two removed plus one added.
      for (final name in sessionOpenHelpers) {
        expect(stable, isNot(contains(name)));
        expect(unstable, isNot(contains(name)));
      }
      expect(stableDoorNamesAtFork.difference(stable), sessionOpenHelpers);
      expect(stable, stableDoorNames);
    });

    test('the export LINE pins do not move', () {
      int exportLines(String door) =>
          File(door)
              .readAsLinesSync()
              .where((l) => l.startsWith('export'))
              .length;
      // ⚠️ A LINE COUNT THAT DOES NOT MOVE IS NOT EVIDENCE THAT NOTHING
      // CHANGED. Three names left this package's public API in this slice and
      // both counts below are unchanged, because a show clause is edited in
      // place. The NAME delta in the cell above is the surface measurement;
      // these two only confirm the four export-count pins stay green.
      expect(exportLines('lib/zenoh.dart'), 36);
      expect(exportLines('lib/zenoh_unstable.dart'), 12);
    });

    test('the package own tests are unaffected, and the ground is stated', () {
      // The three helpers have in-package callers and none of them breaks.
      // That is not luck: every one reaches the function through the LEAF
      // LIBRARY rather than through the door whose clause fences it.
      const callers = [
        'test/exception_code_name_test.dart',
        'test/session_open_offload_test.dart',
        'test/session_test.dart',
      ];
      for (final caller in callers) {
        final source = File(caller).readAsStringSync();
        expect(
          source.contains('openFailureMessage') ||
              source.contains('openStartFailureMessage') ||
              source.contains('completeOpenFromPost'),
          isTrue,
          reason:
              '$caller no longer calls any of the three, so it is not '
              'the control this cell takes it for',
        );
        expect(
          source,
          contains("import 'package:zenoh_dart/src/session.dart'"),
          reason:
              '$caller calls a session-open helper without importing the '
              'leaf library directly, so the show clause DOES reach it',
        );
      }
    });

    test('the CHANGELOG names each un-export with its recovery', () {
      final changelog = File('../CHANGELOG.md').readAsStringSync();
      // The section that announced this unit, found above the last release
      // before it (0.19.0). A release renames `## Unreleased`, so the cell
      // cannot find it by that name — see helpers/changelog_section.dart.
      final announced = changelogSectionAnnouncing(
        changelog,
        sessionOpenHelpers.first,
        anchor: '0.19.0',
      );
      expect(
        announced,
        isNotNull,
        reason: 'no section above 0.19.0 announces this unit',
      );
      for (final name in sessionOpenHelpers) {
        expect(
          announced,
          contains(name),
          reason:
              '$name left the public API and the section announcing this '
              'unit does not name it. A SILENT STOP is invisible to a reader '
              'searching for throws, which is exactly why the recipe requires '
              'it named',
        );
      }
      expect(
        announced,
        contains('ZenohException'),
        reason:
            'an entry naming what was removed without naming what to '
            'reach for instead leaves the reader where it found them',
      );
    });

    test('the annotation is admissible only because the door changed', () {
      // ⭐ DRIVEN, NOT RECORDED. With @internal on the three and the doors
      // untouched, strict analyze read EXIT 2 and SIX
      // invalid_export_of_internal_element warnings -- three functions across
      // BOTH doors, the unstable one reached through `export 'zenoh.dart';`.
      // That is why the door edit and the annotation are one indivisible
      // change: the analyzer refuses the intermediate state outright.
      final result = Process.runSync(
        Platform.resolvedExecutable,
        ['analyze', '--fatal-infos', '--fatal-warnings', '.'],
      );
      expect(
        result.exitCode,
        0,
        reason:
            'strict analyze is not clean, so show and @internal have '
            'stopped agreeing:\n${result.stdout}\n${result.stderr}',
      );
      // And the annotation really is present, ADDED beside the weaker one
      // rather than swapped for it: the first says WHY the member is public,
      // the second says only that it is not public API.
      final source = File('lib/src/session.dart').readAsStringSync();
      for (final name in sessionOpenHelpers) {
        final at = source.indexOf(
          RegExp('^\\w[^\\n]*\\b$name\\(', multiLine: true),
        );
        expect(at, greaterThan(0), reason: '$name is not declared any more');
        final preamble = source.substring(at - 40, at);
        expect(preamble, contains('@internal'));
        expect(preamble, contains('@visibleForTesting'));
      }
    });

    test('the consumer harness fails loudly when it cannot run', () {
      // ⛔ EXIT CODE 3 CANNOT DISCRIMINATE -- measured. A probe that never
      // resolved reports uri_does_not_exist at exit 3, and a correctly
      // un-exported function reports undefined_function at exit 3 too. A
      // harness reading the exit code alone would therefore report a fence as
      // having fired when the import never landed. This cell drives the blind
      // setup and pins that the two are indistinguishable by exit code.
      final dir = Directory.systemTemp.createTempSync('zd_api_broken_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      File('${dir.path}/probe.dart').writeAsStringSync(namesTheSessionHelpers);
      final result = Process.runSync(
        Platform.resolvedExecutable,
        ['analyze', dir.path],
      );
      final output = '${result.stdout}${result.stderr}';
      expect(
        output,
        contains('uri_does_not_exist'),
        reason:
            'a probe with no package_config must fail to resolve; if it '
            'resolves, this cell is not exercising the blind case',
      );
      expect(
        result.exitCode,
        3,
        reason:
            'the unresolvable probe exits 3, the SAME code a correctly '
            'un-exported name produces -- which is the whole reason the '
            'harness asserts resolution instead of reading this number',
      );
      // ⭐ AND THE HARNESS'S OWN GUARD IS DRIVEN, not asserted. Given the
      // same blind setup it must FAIL carrying the subprocess output, never
      // return a clean finding. Without this the guard is a line of code
      // nobody has watched fire.
      expect(
        () => analyzeConsumerProbe(
          namesTheSessionHelpers,
          withoutPackageConfig: true,
        ),
        throwsA(
          isA<TestFailure>().having(
            (f) => f.message,
            'message',
            allOf(
              contains('never resolved this package'),
              contains('uri_does_not_exist'),
            ),
          ),
        ),
      );
    });

    test('the source-text proxy agrees, and is labelled a proxy', () {
      // ⚠️ A PROXY, NOT A SUBSTITUTE for the consumer cell above. It reads
      // what the door SAYS; only an analyzer outside this package can say
      // what a consumer can REACH. It earns its place by failing on a
      // different day: a broken subprocess harness leaves this one standing.
      final directives = exportDirectives(
        File('lib/zenoh.dart').readAsLinesSync(),
      );
      final sessionDirective = directives.singleWhere(
        (d) => d.contains("'src/session.dart'"),
      );
      expect(sessionDirective, contains('show Session;'));
      for (final name in sessionOpenHelpers) {
        expect(sessionDirective, isNot(contains(name)));
      }
    });
  });

  group('[API] the ten pull-surface test instruments are marked internal', () {
    // ⛔ ONE strict-analyze run for the whole group. It costs ~10 s and two
    // cells below need it; a per-cell run would pay that twice for the same
    // measurement.
    late ProcessResult strict;
    setUpAll(() {
      strict = Process.runSync(
        Platform.resolvedExecutable,
        ['analyze', '--fatal-infos', '--fatal-warnings', '.'],
      );
    });

    test('a consumer test directory is now warned, where it was silent', () {
      // ⭐ THE TRANSITION IS WHAT THIS CELL IS ABOUT, and the before-state was
      // MEASURED rather than assumed. Before this slice the SAME probe under
      // a directory called `test` drew NOTHING AT ALL -- exit 0, "No issues
      // found!" -- because `@visibleForTesting` is by construction silent in
      // test code, and that was the only annotation these ten carried. A
      // consumer probing an FFI binding writes in `test/` first, so the
      // weaker annotation left exactly the reader most likely to reach a raw
      // native address entirely unwarned.
      final inTestDir = analyzeConsumerProbe(
        namesThePullTestInstruments,
        segment: 'test',
      );
      for (final member in pullInstrumentsNamedByTheProbe) {
        expect(
          inTestDir.output,
          contains(member),
          reason:
              'the analyzer says nothing about $member from a consumer '
              "test directory, so the slice's whole point is "
              'unmeasured:\n${inTestDir.output}',
        );
      }
      expect(
        inTestDir.output,
        contains('invalid_use_of_internal_member'),
        reason:
            'a consumer test directory is still silent about these ten, '
            'which is the state this slice exists to end:\n'
            '${inTestDir.output}',
      );
      // ⛔ AND THE WEAKER ANNOTATION IS STILL SILENT HERE. That is not a
      // defect being tolerated: it is the GROUND for adding the second
      // annotation rather than relying on the first. If this ever starts
      // firing, the reason this slice exists has gone away and the cell
      // should be re-argued rather than relaxed.
      expect(
        inTestDir.output,
        isNot(contains('invalid_use_of_visible_for_testing_member')),
        reason:
            'visibleForTesting now fires in a consumer test directory '
            'too, so the measured asymmetry this slice rests on no longer '
            'holds:\n${inTestDir.output}',
      );
      // The CONTRAST arm, at the probe root: outside test code the weaker
      // annotation was already speaking, before this slice and after it. So
      // the position is what moved, not the package.
      final atRoot = analyzeConsumerProbe(namesThePullTestInstruments);
      expect(atRoot.output, contains('invalid_use_of_internal_member'));
      expect(
        atRoot.output,
        contains('invalid_use_of_visible_for_testing_member'),
        reason:
            'the root-position arm draws no visibleForTesting '
            'diagnostic, so it is not the contrast this cell takes it '
            'for:\n${atRoot.output}',
      );
    });

    test('the weaker annotation is added to, not replaced', () {
      // ⛔ ADD, NOT SWAP, and the two say different things. `@visibleForTesting`
      // states WHY the member is public -- true of all ten and the reason
      // they exist at all. `@internal` states only that it is not public API.
      // Dropping the first would lose the justification and keep only the
      // prohibition, which is lossy rather than wrong.
      //
      // ⚠️ AND THE PRICE IS KNOWN, NOT DISCOVERED: `dart doc` emits no page
      // for an `@internal` member and no entry for it on its class page,
      // while a `@visibleForTesting`-only member gets both. So the "states
      // why the member is public" half stays true OF THE SOURCE and stops
      // being true OF THE PUBLISHED DOCS. For a test instrument handing out a
      // raw native address that is the desired outcome -- nobody browsing the
      // published API should meet `teeAddressForTesting` -- and this cell
      // records that the slice adopted it knowing which half survives where.
      final instruments = pullTestInstruments();
      expect(
        instruments,
        hasLength(10),
        reason:
            'the population is the ten members this slice annotates; a '
            'different number means a getter was added or renamed and the '
            'enumerated cells below no longer cover the file',
      );
      for (final member in instruments) {
        expect(
          member.annotations,
          contains('@visibleForTesting'),
          reason:
              '${member.file} ${member.name} lost @visibleForTesting -- '
              'the ground for the member being public went with it',
        );
        expect(
          member.annotations,
          contains('@internal'),
          reason:
              '${member.file} ${member.name} is not marked @internal, so '
              "a consumer's test directory is still unwarned about it",
        );
      }
    });

    test('the consumer own lib directory draws two diagnostics per member', () {
      // The two annotations COMPOSE rather than one masking the other: at a
      // position where both apply, both are reported. Measured before this
      // slice, this position drew invalid_use_of_visible_for_testing_member
      // ALONE, so the internal one is the addition.
      final result = analyzeConsumerProbe(
        namesThePullTestInstruments,
        segment: 'lib',
      );
      final lines = const LineSplitter().convert(result.output);
      for (final member in pullInstrumentsNamedByTheProbe) {
        final about = lines.where((l) => l.contains(member)).toList();
        for (final code in const [
          'invalid_use_of_visible_for_testing_member',
          'invalid_use_of_internal_member',
        ]) {
          expect(
            about.where((l) => l.contains(code)),
            isNotEmpty,
            reason:
                'no $code reported against $member, so the two '
                'annotations are not both reaching it:\n${result.output}',
          );
        }
      }
    });

    test('the six raw-address getters are enumerated by name', () {
      // ⚠️ GREEN AT RED BY DESIGN, and DRIVEN rather than merely asserted.
      // Which getters hand out an address is a property of the source that
      // the annotation does not move, so a cell that could only pass after
      // the edit would not be measuring it. Driven by renaming
      // `pull_replies.dart`'s `teeAddressForTesting` in place: this cell went
      // red naming the rename, and was restored by sha256.
      //
      // ⛔ NAMED, NOT COUNTED. Six is equally consistent with the wrong six.
      // These hand out a RAW NATIVE ADDRESS as an `int` -- three classes with
      // two getters each -- which is the sharpest reason a consumer must not
      // meet them: the value is only meaningful to a leak instrument counting
      // distinct blocks, and is a dangling pointer to anyone else.
      final addressGetters = pullTestInstruments()
          .where((m) => m.type == 'int')
          .map((m) => '${m.file} ${m.name}')
          .toSet();
      expect(
        addressGetters,
        unorderedEquals(const [
          'pull_replies.dart teeAddressForTesting',
          'pull_replies.dart handlerAddressForTesting',
          'pull_subscriber.dart teeAddressForTesting',
          'pull_subscriber.dart handlerAddressForTesting',
          'pull_queryable.dart teeAddressForTesting',
          'pull_queryable.dart handlerAddressForTesting',
        ]),
      );
    });

    test('the four flag getters are annotated on the same ground', () {
      // ⚠️ GREEN AT RED BY DESIGN, and driven the same way: renaming
      // `pull_queryable.dart`'s `stashHeldForTesting` in place turned this
      // cell red, and it was restored by sha256.
      //
      // ⭐ THE POPULATION IS THE THIRTEEN, NOT THE SIX. These four hand out no
      // address -- they report drive-loop state a cell cannot infer -- and
      // they are annotated for the same reason regardless: a consumer has no
      // business reading them, whatever they carry. Marking only the
      // dangerous six would leave the other four looking like a decision that
      // was made, when it would only be one that was skipped.
      final flagGetters = pullTestInstruments()
          .where((m) => m.type == 'bool')
          .map((m) => '${m.file} ${m.name}')
          .toSet();
      expect(
        flagGetters,
        unorderedEquals(const [
          'pull_subscriber.dart pullInFlightForTesting',
          'pull_subscriber.dart stashHeldForTesting',
          'pull_queryable.dart pullInFlightForTesting',
          'pull_queryable.dart stashHeldForTesting',
        ]),
      );
      // 6 + 4 here, plus the three top-level session-open helpers the fourth
      // slice annotated, is the whole population the seed ruled -- thirteen,
      // and nothing wider.
      expect(flagGetters.length + 6 + sessionOpenHelpers.length, 13);
    });

    test('the in-package readers of the ten are unaffected, and the ground '
        'is stated', () {
      // Both annotations are silent WITHIN the declaring package, so every
      // in-package reader keeps working untouched. That is a property of the
      // annotations rather than luck, and this cell names the readers so a
      // future edit cannot quietly leave the claim with nothing behind it.
      //
      // ⚠️ GREEN AT RED BY DESIGN -- a regression guard's whole content is
      // that the state after equals the state before, so it must be green in
      // both. Both halves were DRIVEN: renaming a getter in `lib/` turned the
      // strict-analyze half red with `undefined_getter` against
      // `ffi_ownership_test.dart`, and pointing one entry below at a file
      // naming none of the ten turned the reader half red.
      const inPackageReaders = [
        'test/bounded_stream_test.dart',
        'test/bounded_stream_query_test.dart',
        'test/bounded_stream_retention_test.dart',
        'test/bounded_stream_kinds_test.dart',
        'test/fifo_close_deadlock_test.dart',
        'test/ffi_ownership_test.dart',
        // ⚠️ Not a test: the package's own library reads these getters too,
        // so the silence has to hold inside `lib/` as well as inside `test/`.
        'lib/src/demand_gated_stream.dart',
      ];
      final names = pullTestInstruments().map((m) => m.name).toSet();
      for (final reader in inPackageReaders) {
        final source = File(reader).readAsStringSync();
        expect(
          names.any(source.contains),
          isTrue,
          reason:
              '$reader names none of the ten getters, so it is not the '
              'control this cell takes it for',
        );
      }
      expect(
        strict.exitCode,
        0,
        reason:
            'strict analyze over the package is not clean, so the '
            'annotations are NOT silent in-package:\n'
            '${strict.stdout}${strict.stderr}',
      );
    });

    test('no member-level annotation trips the export rule', () {
      // ⚠️ MEMBER-LEVEL IS DIFFERENT IN KIND FROM TOP-LEVEL, and the fourth
      // slice measured the contrary case: `@internal` on a top-level function
      // behind a door that still exports it read EXIT 2 with SIX
      // invalid_export_of_internal_element warnings. Ten members annotated
      // here draw none, because the rule reaches top-level elements only --
      // which is why this slice needed no door change and no CHANGELOG entry.
      // An annotation removes no name from any namespace.
      final output = '${strict.stdout}${strict.stderr}';
      expect(
        output,
        isNot(contains('invalid_export_of_internal_element')),
        reason:
            'a member-level @internal reached the export rule after all, '
            'so this slice does need a door change:\n$output',
      );
      // ⛔ PAIRED WITH A PRESENCE ASSERTION, because an absence is vacuous on
      // its own: with the annotation gone, or with the three classes no
      // longer exported, the rule would have nothing to reach and the cell
      // above would pass for the wrong reason.
      expect(
        pullTestInstruments().where((m) => m.annotations.contains('@internal')),
        hasLength(10),
      );
      final stable = resolvedExportNamespace('lib/zenoh.dart');
      expect(
        stable,
        containsAll(const ['PullSubscriber', 'PullReplies', 'PullQueryable']),
        reason:
            'the three declaring classes are not on the stable door, so '
            'the export rule had nothing to reach and the absence above says '
            'nothing',
      );
    });
  });

  group('[API] the false statements in shipped documentation are corrected', () {
    test('the timestamp constructor no longer claims package privacy', () {
      // MEASURED FALSE: Timestamp.fromRaw(Uint8List(24)) from a consumer's
      // lib/, from its test/ and from a bare probe draws NO diagnostic at any
      // position. It carries neither annotation. A dartdoc that claims a
      // fence which is not there is the defect this slice exists for.
      final doc = dartdocAbove('lib/src/timestamp.dart', 'Timestamp.fromRaw(');
      expect(
        doc,
        contains('corrected:'),
        reason:
            'no correction marker, so the strip below removes nothing '
            'and the assertion after it would be vacuous',
      );
      expect(
        operative(doc),
        isNot(contains('reachable only within the package')),
        reason:
            'the OPERATIVE text still claims package privacy it does not '
            'have (a struck quotation inside the correction is fine and is '
            "this project's convention)",
      );
      final result = analyzeConsumerProbe('''
import 'dart:typed_data';

import 'package:zenoh_dart/zenoh.dart';

Timestamp t() => Timestamp.fromRaw(Uint8List(24));
''');
      expect(
        result.exitCode,
        0,
        reason:
            'the constructor now draws a diagnostic, so whatever the '
            'dartdoc says about reachability has to be re-measured rather '
            'than kept:\n${result.output}',
      );
    });

    test('the corrected text states what is actually true', () {
      // ⛔ THE FALSE CLAIM IS REPLACED BY A FACT, NOT DELETED. A dartdoc that
      // simply drops the sentence leaves a reader with no account of where a
      // Timestamp is supposed to come from, which is the true half of what
      // the sentence was carrying.
      final doc = dartdocAbove('lib/src/timestamp.dart', 'Timestamp.fromRaw(');
      expect(doc, contains('newtimestamp'));
      expect(doc, contains('received sample'));
      expect(
        doc,
        anyOf(contains('not intended'), contains('is not the intended')),
        reason:
            'the dartdoc no longer says direct construction is '
            'unintended, which was the true half of the sentence',
      );
      expect(
        doc,
        anyOf(contains('nothing prevents'), contains('nothing stops')),
        reason:
            'the replacement must say what IS true — that the constructor '
            'is reachable and unfenced — rather than merely stop saying the '
            'false thing',
      );
    });

    test('the session helper dartdoc names the fence that now exists', () {
      // At the fork this read "intentionally not exported", and that was
      // FALSE: the function was among the stable door's 45 names. The fourth
      // slice of this unit made it true. So the repair here is not a
      // correction of falsity but a change of KIND — name the MECHANISM that
      // excludes it, because "intentionally" describes a wish and `show`
      // describes a fence.
      final doc = dartdocAbove(
        'lib/src/session.dart',
        'String openFailureMessage(',
      );
      expect(
        doc,
        contains('show'),
        reason:
            'the dartdoc does not name the show clause, so a reader is '
            'told the exclusion is an intention rather than a mechanism',
      );
      expect(
        doc,
        contains('corrected:'),
        reason: 'no correction marker, so the strip below is a no-op',
      );
      expect(
        operative(doc),
        isNot(contains('intentionally not exported')),
        reason:
            'the wish survived the mechanism landing in the OPERATIVE '
            'text, not merely as a struck quotation',
      );
      // ⛔ AND THE FOUR PROSE PINS ON THIS EXACT BLOCK STAY GREEN. They are
      // asserted by diagnosis_route_docs_test.dart, which reads the same
      // block through the same helper shape; repeating them here is what
      // makes an accidental truncation of this dartdoc fail in the file that
      // edited it, rather than only in a file that did not.
      for (final needle in const [
        'zenoh.initlog',
        'zenoh.initlogwithsink',
        'forecloses',
        'stateerror',
      ]) {
        expect(
          doc,
          contains(needle),
          reason:
              'editing this dartdoc dropped "$needle", which a separate '
              'file pins and which this slice must not move',
        );
      }
    });

    test('the advanced-publisher finalizer comment drops its false only', () {
      // ⛔ THE "ONLY" IS FALSE. AdvancedPublisher.declare is a PUBLIC FACTORY
      // at advanced_publisher.dart:131, on a class the unstable door exports
      // (`show AdvancedPublisher`), and it calls zd_advanced_publisher_sizeof
      // with no gate. The last clause is true: declareAdvancedPublisher does
      // call requireUnstable() first.
      // ⛔ THE BLOCK IS EXTRACTED, NOT WINDOWED. This cell first read
      // `source.substring(at - 900, at)`, and the repair it checks made the
      // block longer than 900 characters -- so the window slid PAST the
      // sentence and the cell went green without ever seeing it. That is the
      // scan-window class this corpus already records, caught here only
      // because two sibling cells failed and this one did not.
      final block = dartdocAbove(
        'lib/src/finalizers.dart',
        'final NativeFinalizer advancedPublisherFinalizer',
      );
      expect(
        block,
        contains('corrected:'),
        reason: 'no correction marker, so the strip below is a no-op',
      );
      expect(
        operative(block),
        isNot(contains('reachable only through')),
        reason:
            'the OPERATIVE text still claims a single route to the '
            'constructor',
      );
      expect(
        block,
        contains('advancedpublisher.declare'),
        reason:
            'the second route is not named, so a reader has no way to '
            'find the thing that falsifies the old claim',
      );
      // ⛔ AND THE REPAIR IS NARROWER THAN THE OBVIOUS ONE. Saying what
      // happens when that factory runs on a stable native would be a claim
      // about NativeFinalizer resolution of an absent symbol that nobody has
      // measured. This slice asserts nothing about it, and this assertion is
      // what keeps a later editor from helpfully adding it.
      for (final overreach in const [
        'throws on a stable native',
        'fails on a stable native',
        'crashes on a stable native',
      ]) {
        expect(operative(block), isNot(contains(overreach)));
      }
      // The true half survives.
      expect(block, contains('requireunstable'));
    });

    test('the sweep criterion is falsity, and the cell counts its own '
        'population', () {
      // ⛔ THE "called internally by X" FAMILY IS TRUE AND MERELY INCOMPLETE,
      // and widening a repair from false to incomplete is what the seed's
      // scope rules out. The number is COUNTED here rather than pinned from
      // prose: a figure written into a cell from a document is the defect
      // this project's discipline exists for.
      final selfDescribing = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('src/bindings.dart')) continue;
        const marker = 'This is called internally by';
        if (entity.readAsStringSync().contains(marker)) {
          selfDescribing.add(entity.path);
        }
      }
      expect(
        selfDescribing,
        hasLength(9),
        reason:
            'the self-describing-constructor population moved; it was 9 '
            'files at the fork point, and this slice leaves every one of '
            'them alone. Found: ${selfDescribing..sort()}',
      );
    });

    test('no cell pinned the prose this slice moves', () {
      // The check the seed mandates BEFORE any dartdoc string is moved: this
      // project pins prose in cells, so a documentation-only edit is a code
      // change to whichever cell asserts it.
      const moved = [
        'reachable only within the package',
        'intentionally not exported',
        'reachable only through',
        'Names the positive',
      ];
      for (final phrase in moved) {
        final offenders = <String>[];
        for (final entity in Directory('.').listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('_test.dart')) continue;
          if (entity.path.endsWith('api_surface_test.dart')) continue;
          if (entity.readAsStringSync().contains(phrase)) {
            offenders.add(entity.path);
          }
        }
        expect(
          offenders,
          isEmpty,
          reason:
              'a cell pins "$phrase", so moving it is a code change to '
              'that cell rather than a documentation edit',
        );
      }
    });

    test('a displaced dartdoc fragment no longer sits on the wrong member', () {
      // ⭐ NOT IN THE PLAN. Found by the sweep the seed's item 3 asks for.
      // Four lines describing the shim's "did it start" POSITIVES sat at the
      // end of openFailureMessage's dartdoc — and that function renders
      // canon's NEGATIVE codes on a rejected future. git blame: added by
      // 1c49306e, the same commit that added _openStartFailures; that map was
      // then given its own fuller dartdoc by bc9bd77f, leaving these four
      // stranded on the wrong member.
      final doc = dartdocAbove(
        'lib/src/session.dart',
        'String openFailureMessage(',
      );
      expect(
        doc,
        isNot(contains('names the positive "did it start" codes')),
        reason:
            'the displaced fragment is still on openFailureMessage, '
            'where it is false: those positives are '
            "openStartFailureMessage's",
      );
      // And its content survives where it belongs, so this is a de-duplication
      // rather than a deletion.
      final startCodes = dartdocAbove(
        'lib/src/session.dart',
        'const Map<int, String> '
            '_openStartFailures',
      );
      expect(
        startCodes,
        contains('did it start'),
        reason:
            'the fragment was removed from the wrong member without its '
            'content surviving at the right one',
      );
    });
  });

  group('[API] the three crash escapes carry the documentation they owed', () {
    // ⛔ ONE strict-analyze run for the whole group — ~10 s, and two cells
    // below read it. Same trade the pull-instrument group already makes.
    late ProcessResult strict;
    // ⛔ AND ONE consumer-probe run, for the same reason. Two cells below ask
    // different questions OF THE SAME MEASUREMENT — how many warnings, and
    // whether anything stopped resolving — so running the probe twice would
    // pay an analyzer run to re-derive an answer already in hand, and would
    // let the two cells disagree about a state that is one state.
    late AnalyzeResult consumer;
    setUpAll(() {
      strict = Process.runSync(
        Platform.resolvedExecutable,
        ['analyze', '--fatal-infos', '--fatal-warnings', '.'],
      );
      consumer = analyzeConsumerProbe(namesTheThreeCrashEscapes);
    });

    // The three constructors that take a native handle from whoever calls
    // them and dereference it without validating it. `nativeType` is the
    // canon type the parameter must point at, and the dartdoc has to name it:
    // a reader who is not told what a correct value IS cannot tell a correct
    // one from a wrong one. `type` and `field` name the class and the member
    // the constructor stores that value in, which is what [addressGetters]
    // looks for a public route back to.
    const escapes =
        <
          ({
            String file,
            String declaration,
            String nativeType,
            String type,
            String field,
          })
        >[
          (
            file: 'lib/src/query.dart',
            declaration: 'Query({',
            nativeType: 'z_owned_query_t',
            type: 'Query',
            field: '_handle',
          ),
          (
            file: 'lib/src/bytes.dart',
            declaration: 'ZBytes.fromNative(',
            nativeType: 'z_owned_bytes_t',
            type: 'ZBytes',
            field: '_ptr',
          ),
          (
            file: 'lib/src/unstable/shm_mut_buffer.dart',
            declaration: 'ShmMutBuffer.fromNative(',
            nativeType: 'z_owned_shm_mut_t',
            type: 'ShmMutBuffer',
            field: '_ptr',
          ),
        ];

    /// Whether the class in [file] arms a `NativeFinalizer` — READ OFF THE
    /// SOURCE, never transcribed.
    ///
    /// ⚠️ A PROXY, and labelled one: it is a text scan over the whole file,
    /// so it would answer `true` for an attach on some other class declared
    /// beside the one under test. It is corroborated below by the LINKER,
    /// which assumes something completely different — that a net's native
    /// half has to exist as a resolvable symbol.
    bool armsAFinalizer(String file) =>
        RegExp(r'[Ff]inalizer\.attach\(')
            .hasMatch(File(file).readAsStringSync());

    /// The PUBLIC getters of class [type] in [source] that hand back [field]
    /// — the very value its crash escape takes — READ OFF THE SOURCE.
    ///
    /// ⭐ THIS DECIDES WHETHER "THE LIBRARY NEVER HANDS ONE OUT" MAY BE SAID.
    /// That sentence shipped on two of the three escapes while each class
    /// carried such a getter, and the cells pinning it asserted only that it
    /// was PRESENT — which reports what the text is, not whether it is true.
    /// The question that can tell is: what member would have to not exist for
    /// the sentence to be true, and does it?
    ///
    /// ⚠️ A PROXY, and labelled one: it recognises a getter whose body is
    /// `=> field` or ends `return field;`, optionally through `.cast()` or
    /// `.address`, inside the class's own body. The first cell below drives
    /// every one of those shapes, and the shapes it must NOT reach, on a
    /// synthetic class before its reading of a real one is believed.
    List<String> addressGetters(String source, String type, String field) {
      final start = source.indexOf(RegExp('^class $type\\b', multiLine: true));
      expect(start, greaterThanOrEqualTo(0), reason: 'class $type not found');
      final end = source.indexOf('\n}', start);
      expect(end, greaterThan(start), reason: 'class $type has no end');
      final value = '$field(?:\\.cast(?:<[^>]*>)?\\(\\)|\\.address)?';
      return RegExp(
            r'^  [\w<>?, ]+ get ([a-zA-Z]\w*)\s*'
            '(?:=>\\s*$value\\s*;|\\{[^}]*\\breturn\\s+$value\\s*;\\s*\\})',
            multiLine: true,
          )
          .allMatches(source.substring(start, end))
          .map((m) => m.group(1)!)
          .toList();
    }

    test('each escape names the native value its parameter carries', () {
      // ⛔ RE-POINTED 2026-09-10. This cell required all three dartdocs to
      // say "the library never hands one out", and two of them shipped that
      // sentence FALSE, each beside a public getter returning exactly the
      // value. A presence assertion on prose could not see it: it reports
      // what the text IS, not whether it is TRUE. So the sentence is now
      // ruled by the member that would have to not exist for it to be true
      // — [addressGetters] — and read on the OPERATIVE text, because the
      // struck sentence survives inside a dated correction. The marker is
      // checked separately, so the strip cannot silently become a no-op.
      //
      // ⭐ THE INSTRUMENT IS DRIVEN FIRST, on a synthetic class carrying
      // every shape it claims to reach and four it must not: a getter
      // returning another field, one returning a longer name that starts
      // with the same one, a private getter, and a getter on a NEIGHBOURING
      // class.
      const synthetic = '''
class Probe {
  int get block {
    _check();
    return _field;
  }
  Pointer<Void> get arrow => _field;
  Pointer<Uint8> get cast => _field.cast<Uint8>();
  int get address => _field.address;
  int get elsewhere {
    return _other;
  }
  int get longer => _fieldTwo;
  int get _private => _field;
}
class Neighbour {
  int get outside => _field;
}
''';
      expect(
        addressGetters(synthetic, 'Probe', '_field'),
        ['block', 'arrow', 'cast', 'address'],
        reason:
            'the scan misses a shape that hands the value back, or reaches '
            'something it must not, so what it says about the three escapes '
            'below means nothing',
      );

      for (final escape in escapes) {
        final doc = dartdocAbove(escape.file, escape.declaration);
        expect(
          doc,
          contains(escape.nativeType),
          reason:
              '${escape.declaration} does not say what its parameter is, '
              'so a reader has no way to know what a correct value even '
              'looks like',
        );

        final getters = addressGetters(
          File(escape.file).readAsStringSync(),
          escape.type,
          escape.field,
        );
        final text = operative(doc);
        if (getters.isEmpty) {
          expect(
            text,
            contains('never hands one out'),
            reason:
                'no public member of ${escape.type} returns the value, and '
                '${escape.declaration} does not say so — which is the fact '
                'that makes every consumer call to it a fabrication rather '
                'than a use',
          );
          continue;
        }
        expect(
          doc,
          contains('(corrected:'),
          reason:
              '${escape.declaration} carries no correction marker, so the '
              'strip removes nothing and the absence below is vacuous',
        );
        expect(
          text,
          isNot(contains('never hands one out')),
          reason:
              '${escape.declaration} still ASSERTS the library never '
              'hands the value out, while ${getters.join(', ')} returns it '
              '(a struck quotation inside the correction is fine):\n$doc',
        );
        for (final getter in getters) {
          final name = getter.toLowerCase();
          expect(
            text,
            anyOf(contains('through `$name`'), contains('through [$name]')),
            reason:
                '${escape.declaration} does not name $getter, the public '
                'member a consumer obtains the value through:\n$doc',
          );
        }
        for (final arm in const ['did not produce', 'second wrapper']) {
          expect(
            text,
            contains(arm),
            reason:
                '${escape.declaration} does not name both ways to get it '
                'wrong: a fabricated value, and a real one obtained through '
                'the getter building a second wrapper. "$arm" is missing:\n'
                '$doc',
          );
        }
      }
    });

    test('each escape states that a wrong value kills the process', () {
      // ⭐ THE THREE NEEDLES ARE THE THREE HALVES OF THE CLAIM, and each one
      // is load-bearing on its own. WHOSE value ("did not produce"), WHY
      // nothing catches it ("without validation") and WHAT happens ("aborts
      // the VM"). A dartdoc carrying only the last reads as an ordinary error
      // condition a caller might handle.
      for (final escape in escapes) {
        final doc = dartdocAbove(escape.file, escape.declaration);
        for (final needle in const [
          'did not produce',
          'without validation',
          'aborts the vm',
        ]) {
          expect(
            doc,
            contains(needle),
            reason:
                '${escape.declaration} does not say "$needle", so the '
                'consequence of a wrong value is under-stated:\n$doc',
          );
        }
      }
    });

    test('each escape states that the crash need not arrive where the '
        'mistake was made, by the mechanism ITS OWN class has', () {
      // ⛔⛔ THE PLAN'S SENTENCE FOR THIS CELL IS FALSE FOR ONE OF THE THREE.
      // It required each dartdoc to name "the finalizer as a delayed arrival
      // point, since the constructor arms it unconditionally". `Query` arms
      // NONE — deliberately, on the ground its own class dartdoc states: on
      // the one-session path `zd_query_drop` POSTS to a Dart port, and a post
      // reached from a finalizer callback is documented undefined behaviour.
      // A cell that transcribed the plan would have pinned that falsehood
      // into the suite AND into shipped documentation, which is the exact
      // defect the preceding slice spent itself repairing.
      //
      // ▶ §2's property still holds for all three — the crash need not
      // arrive where the mistake was made — but the MECHANISM differs, so it
      // is DERIVED here rather than dictated, by two instruments that assume
      // different things.

      // INSTRUMENT 2 — THE LINKER. A `NativeFinalizer` needs a raw entry
      // ADDRESS, which the generated bindings cannot supply, so the net's
      // native half is resolved out of the loaded library BY SYMBOL NAME.
      // There is no `zd_fin_query` to resolve, and no text scan is involved
      // in saying so.
      expect(
        () => nativeLibrary.lookup<NativeFinalizerFunction>('zd_fin_query'),
        throwsArgumentError,
        reason:
            'the native ships a query finalizer after all, so Query may '
            'have gained a net and the per-class mechanism below has to be '
            're-derived rather than kept',
      );
      // ⛔ PAIRED WITH POSITIVE CONTROLS ON THE SAME INSTRUMENT. An absence
      // means nothing unless presence is demonstrable through it: a typo in
      // the symbol name above would throw for the wrong reason and read as
      // proof. `zd_fin_bytes` is unconditional in both shipped variants;
      // `zd_fin_shm_mut` is one of the three `#ifdef`-guarded entries and is
      // absent from the stable native, so it is asked for only where the
      // feature is present.
      expect(
        () => nativeLibrary.lookup<NativeFinalizerFunction>('zd_fin_bytes'),
        returnsNormally,
      );
      if (ZenohFeatures.hasSharedMemory) {
        expect(
          () => nativeLibrary.lookup<NativeFinalizerFunction>('zd_fin_shm_mut'),
          returnsNormally,
        );
      }

      // INSTRUMENT 1 — the source scan, and the two agree on the split.
      expect(
        escapes.where((e) => armsAFinalizer(e.file)).map((e) => e.declaration),
        ['ZBytes.fromNative(', 'ShmMutBuffer.fromNative('],
        reason:
            'the source scan no longer splits the three the way the '
            'linker does, so the per-class mechanism below is not derived '
            'from anything',
      );

      for (final escape in escapes) {
        final doc = dartdocAbove(escape.file, escape.declaration);
        expect(
          doc,
          contains('need not arrive where the mistake was made'),
          reason:
              '${escape.declaration} does not warn that the abort can '
              'land far from the call that caused it:\n$doc',
        );
        if (armsAFinalizer(escape.file)) {
          for (final needle in const [
            'this constructor arms',
            'unconditionally',
            'collected',
          ]) {
            expect(
              doc,
              contains(needle),
              reason:
                  '${escape.declaration} arms a net unconditionally, so '
                  'collection IS a second arrival point and the dartdoc has '
                  'to say so — "$needle" is missing:\n$doc',
            );
          }
        } else {
          expect(
            doc,
            contains('arms none'),
            reason:
                '${escape.declaration} arms no finalizer, and the '
                'dartdoc does not say so — which leaves a reader to assume '
                'the collection-time arrival point the other two have:\n$doc',
          );
          expect(
            doc,
            isNot(contains('this constructor arms')),
            reason:
                'the dartdoc claims this constructor arms a finalizer. '
                'It does not, and that claim is precisely the plan clause '
                'this cell exists to keep out of the shipped reference:\n'
                '$doc',
          );
          // ⭐ AND THE ARRIVAL POINTS IT NAMES MUST EXIST. The brief for this
          // slice named `replyDelete`; the member is `replyDel`. A dartdoc
          // is the one place a wrong member name is invisible — nothing
          // compiles it — so the references are RESOLVED here. Read with the
          // original case kept, because that is what tells a member
          // reference from a type reference.
          final raw = dartdocAbove(
            escape.file,
            escape.declaration,
            lowercase: false,
          );
          final source = File(escape.file).readAsStringSync();
          final refs = RegExp(r'\[([a-z]\w*)\]')
              .allMatches(raw)
              .map((m) => m.group(1)!)
              .toSet();
          expect(
            refs,
            isNotEmpty,
            reason:
                'the dartdoc names no arrival point at all, so the '
                'delayed-arrival warning above has nothing to point at',
          );
          // ⚠️ A GETTER IS A MEMBER TOO, and the list names one:
          // [payloadZBytes] dereferences the handle through
          // `zd_query_payload_clone` on its first read. The method-only form
          // of this pattern could not see a getter, so it would have failed a
          // correct dartdoc, and taught its author to drop the name. The
          // brief's wrong `replyDelete` stays as the NEGATIVE control: a
          // pattern that resolves it resolves anything.
          RegExp member(String name) => RegExp(
            '^  [\\w<>?, ]+ (?:$name\\(|get $name\\b)',
            multiLine: true,
          );
          expect(
            member('replyDelete').hasMatch(source),
            isFalse,
            reason:
                'the member pattern resolves a name ${escape.file} does '
                'not declare, so every resolution below is vacuous',
          );
          for (final ref in refs) {
            expect(
              member(ref).hasMatch(source),
              isTrue,
              reason:
                  '[$ref] is named as an arrival point but no such '
                  'member is declared in ${escape.file}',
            );
          }
        }
      }
    });

    test('the documentation does not claim to be a fence', () {
      // ⛔ THE CLASSES ARE REACHABLE BY DECISION. The annotation this slice
      // adds is a WARNING — the constructors still resolve from a consumer,
      // and the cell below drives that rather than assuming it. A dartdoc
      // claiming otherwise would be a false statement in shipped
      // documentation, the same defect the preceding slice repaired, landing
      // in the same unit that repaired it.
      //
      // The correction-strip is applied for the reason [operative] gives:
      // this project preserves struck text, so a dated correction QUOTING one
      // of these claims must not read as one still being made.
      //
      // ⭐ DRIVEN, because this cell was GREEN BEFORE THE DARTDOCS EXISTED —
      // three one-line comments cannot claim a fence, so it passed on
      // emptiness. `Query`'s block was temporarily reworded to "the
      // constructor is unreachable from another package"; the cell failed,
      // naming the claim, and the block was restored. That is also the
      // realistic defect shape: the perturbed text still carried "a warning,
      // not a fence" two sentences later, so the doc contradicted itself and
      // only the needle caught it.
      for (final escape in escapes) {
        final doc = operative(dartdocAbove(escape.file, escape.declaration));
        for (final claim in const [
          'unreachable',
          'inaccessible',
          'is private',
          'cannot be constructed',
          'cannot be called',
          'not reachable',
        ]) {
          expect(
            doc,
            isNot(contains(claim)),
            reason:
                '${escape.declaration} claims "$claim". It is not: the '
                'name resolves from a consumer today and this slice does not '
                'close it:\n$doc',
          );
        }
      }
    });

    test('all three escapes gain @internal, and the ground is stated', () {
      // ⚖️ ALL THREE, settled at the plan gate against the plan's own
      // narrower ruling, which had spared `Query`. The ground: all three are
      // self-describing in their own dartdoc; `Query` and `ShmMutBuffer` have
      // exactly one constructor each (counted below, not asserted); and there
      // is no legitimate consumer construction of any of them.
      for (final escape in escapes) {
        expect(
          annotationsAbove(escape.file, escape.declaration),
          contains('@internal'),
          reason:
              '${escape.declaration} carries no @internal, so it stays in '
              'the generated reference and a consumer naming it is told '
              'nothing',
        );
      }
    });

    test('the three annotations fence a consumer without breaking either '
        'door', () {
      expect(
        'invalid_use_of_internal_member'.allMatches(consumer.output).length,
        3,
        reason:
            'the consumer is not warned once per escape, so at least one '
            'of the three annotations is not reaching a consumer:\n'
            '${consumer.output}',
      );
      // ⛔ AND NEITHER DOOR MOVES. A member-level annotation does not reach
      // the export rule — the fourth slice measured the contrary case at top
      // level, where `@internal` on a function a door still exports read exit
      // 2 with six invalid_export_of_internal_element warnings. A constructor
      // is a member, so this slice needs no door change and no CHANGELOG
      // entry: an annotation removes no name from any namespace.
      final output = '${strict.stdout}${strict.stderr}';
      expect(
        output,
        isNot(contains('invalid_export_of_internal_element')),
        reason:
            'a constructor-level @internal reached the export rule after '
            'all, so this slice does need a door change:\n$output',
      );
      // ⛔ PAIRED WITH A PRESENCE ASSERTION, because the absence is vacuous
      // on its own: with the three classes no longer exported, the rule
      // would have nothing to reach and the cell above would pass for the
      // wrong reason.
      expect(
        resolvedExportNamespace('lib/zenoh.dart'),
        containsAll(const ['Query', 'ZBytes']),
        reason:
            'two of the three declaring classes left the stable door, so '
            'the export rule had nothing to reach and the absence above says '
            'nothing',
      );
      expect(
        resolvedExportNamespace('lib/zenoh_unstable.dart'),
        contains('ShmMutBuffer'),
        reason:
            'the third declaring class left the unstable door, same '
            'consequence',
      );
    });

    test('the residual is a WARNING, not a fence, and the cell says which', () {
      // ⭐ THIS IS WHAT THE SLICE DID NOT DO, pinned so nobody reads the
      // annotation as a closure. §2's crash class stays REACHABLE by
      // decision: every arm of the probe still resolves. The precedent is
      // the fourth slice's second cell, which asserts the `Query(handle:)`
      // arm RESOLVES rather than that it draws nothing — written that way
      // precisely so it survives this slice.
      expect(
        consumer.exitCode,
        2,
        reason:
            'exit 3 is an ERROR, which would mean a name stopped '
            'resolving — a fence, not the warning this slice landed. Exit 0 '
            'would mean no annotation reached the consumer at all:\n'
            '${consumer.output}',
      );
      expect(
        consumer.output,
        isNot(contains('undefined_')),
        reason:
            'a name no longer resolves from a consumer, so the escape '
            'was closed rather than warned about — which is a change of kind '
            'this slice was not authorised to make:\n${consumer.output}',
      );
    });

    test('the construction surfaces are COUNTED by the cell, not asserted', () {
      // ⛔ RE-COUNTED HERE BECAUSE THE FIGURE IN THE PLAN WAS WRONG. The plan
      // recorded `ZBytes` as "15 public + 1 private" — 16 — and marked it
      // verified. It is 15 declarations of which one, `ZBytes._`, is private:
      // 14 public. A number carried in prose is exactly the thing this
      // project counts rather than quotes.
      int declarationsOf(String file, String type) => RegExp(
        '^  (?:const |factory )?$type(?:\\.\\w+)?\\(',
        multiLine: true,
      ).allMatches(File(file).readAsStringSync()).length;
      int privateOf(String file, String type) => RegExp(
        '^  (?:const |factory )?$type\\._',
        multiLine: true,
      ).allMatches(File(file).readAsStringSync()).length;

      expect(declarationsOf('lib/src/query.dart', 'Query'), 1);
      expect(privateOf('lib/src/query.dart', 'Query'), 0);
      expect(
        declarationsOf(
          'lib/src/unstable/shm_mut_buffer.dart',
          'ShmMutBuffer',
        ),
        1,
      );
      expect(
        privateOf('lib/src/unstable/shm_mut_buffer.dart', 'ShmMutBuffer'),
        0,
      );
      // ⭐ WHICH IS WHY REMOVAL WAS NEVER THE REMEDY FOR THE FIRST TWO. A
      // class with one constructor cannot lose it and stay constructible, so
      // for `Query` and `ShmMutBuffer` the only moves available were to
      // document and to warn. `ZBytes` is the contrary case and it is
      // counted, not assumed.
      expect(declarationsOf('lib/src/bytes.dart', 'ZBytes'), 15);
      expect(privateOf('lib/src/bytes.dart', 'ZBytes'), 1);
    });

    test('the annotation takes all three out of the generated reference, and '
        'that is intended', () {
      // ⭐ MEASURED ON THE REAL PACKAGE, not on a synthetic: after the two
      // preceding slices, `fvm dart doc` gives the ten annotated pull
      // instruments 0 pages and 0 occurrences, against positive controls
      // `fromRaw` (1 page, 9 occurrences), `fromNative` (2 pages, 13) and
      // `payloadBytes` (3 pages, 22). An `@internal` member gets no page, no
      // entry in its class's Constructors section, and no rendering of its
      // dartdoc anywhere in the output.
      //
      // ⚠️ SO THE DOCUMENTATION THIS SLICE WRITES WILL NOT APPEAR IN THE
      // PUBLISHED REFERENCE, and that is intended rather than overlooked. It
      // is the point of annotating AND documenting: the annotation takes the
      // escape out of the shop window, and the dartdoc informs whoever gets
      // behind the counter anyway — in the source and in IDE hover, which is
      // where a consumer who has already typed the name is reading. Said
      // here so it is not discovered later and read as a defect.
      //
      // ⛔ `dart doc` IS NOT RUN BY THIS CELL. It costs minutes on this
      // package and the measurement above is CI's on this same tree. What is
      // asserted is the checkable half, and it is a DIFFERENT claim from the
      // two cells above: that both halves of "annotate AND document" sit at
      // the same site. Either alone is a defect — an annotation with no
      // dartdoc hides the escape without explaining it, and a dartdoc with no
      // annotation leaves it in the shop window.
      for (final escape in escapes) {
        expect(
          annotationsAbove(escape.file, escape.declaration),
          contains('@internal'),
        );
        // ⛔ RE-POINTED 2026-09-10, and read on the OPERATIVE text. The first
        // half used to be "never hands one out" for all three — false for
        // two — and its struck form survives inside their dated corrections,
        // so a bare contains() here would be satisfied by the retraction
        // itself. Which half is true is decided by [addressGetters], exactly
        // as in the first cell of this group.
        final obtainable = addressGetters(
          File(escape.file).readAsStringSync(),
          escape.type,
          escape.field,
        ).isNotEmpty;
        final doc = operative(dartdocAbove(escape.file, escape.declaration));
        for (final half in [
          if (obtainable) 'second wrapper' else 'never hands one out',
          'aborts the vm',
          'need not arrive where the mistake was made',
        ]) {
          expect(
            doc,
            contains(half),
            reason:
                '${escape.declaration} is annotated but its dartdoc does '
                'not carry "$half" — so it is out of the reference AND '
                'unexplained, which is strictly worse than before this slice',
          );
        }
      }
    });
  });

  group('[API] the close — the inventory and the breaking sweep', () {
    test('the door census is a gate, not a readout', () {
      // An unexpected public name fails HERE, naming itself, rather than
      // landing silently between units. Following the shape at
      // diagnosability_baselines_test.dart.
      final stable = resolvedExportNamespace('lib/zenoh.dart');
      final unstable = resolvedExportNamespace('lib/zenoh_unstable.dart');
      expect(
        stable.difference(stableDoorNames),
        isEmpty,
        reason: 'the stable door gained a public name nobody decided on',
      );
      expect(
        stableDoorNames.difference(stable),
        isEmpty,
        reason: 'the stable door lost a name this unit did not remove',
      );
      final expectedUnstable = {...stableDoorNames, ...unstableOnlyNames};
      expect(unstable.difference(expectedUnstable), isEmpty);
      expect(expectedUnstable.difference(unstable), isEmpty);
      // What this unit ADDED and REMOVED, recorded rather than implied.
      expect(
        stableDoorNamesAtFork.difference(stable),
        sessionOpenHelpers,
        reason:
            'this unit removed exactly three names from the stable door '
            'and added none',
      );
    });

    test('every population the unit ranges over is stated with its '
        'instrument', () {
      // ⛔ EACH NUMBER IS DERIVED HERE, NOT TRANSCRIBED. A figure written into
      // a cell from a document is the defect this project's discipline exists
      // for -- and one figure in this unit's own plan was marked verified and
      // was wrong.
      final libFiles = <File>[
        for (final e in Directory('lib').listSync(recursive: true))
          if (e is File &&
              e.path.endsWith('.dart') &&
              !e.path.endsWith('src/bindings.dart'))
            e,
      ];
      String all() => libFiles.map((f) => f.readAsStringSync()).join('\n');

      int annotations(String name) =>
          all().split('\n').where((l) => l.trim() == '@$name').length;

      // 13 -- the @visibleForTesting population, unchanged by this unit
      // because it ADDED @internal beside it rather than swapping.
      expect(annotations('visibleForTesting'), 13);
      // ⚠️ AND THE NOUN MATTERS: a grep for the STRING reads more, because
      // prose mentions it. The annotation is a line that is exactly the
      // annotation.
      expect(
        RegExp('@visibleForTesting').allMatches(all()).length,
        greaterThan(13),
        reason:
            'if the string count equals the annotation count, one of the '
            'two instruments has stopped measuring what it was aimed at',
      );
      // 29 -> 42: this unit added 13 (3 top-level + 10 members) at slices 4
      // and 5, then 3 more (the crash escapes) at slice 7.
      expect(annotations('internal'), 45);

      // The doors, by the resolved instrument.
      expect(resolvedExportNamespace('lib/zenoh.dart'), hasLength(42));
      expect(
        resolvedExportNamespace('lib/zenoh_unstable.dart'),
        hasLength(62),
      );
      // Export DIRECTIVES, which did not move and are not the surface.
      int exportLines(String d) =>
          File(d).readAsLinesSync().where((l) => l.startsWith('export')).length;
      expect(exportLines('lib/zenoh.dart'), 36);
      expect(exportLines('lib/zenoh_unstable.dart'), 12);

      // The self-describing-constructor population the false-doc sweep
      // deliberately left alone.
      expect(
        libFiles
            .where(
              (f) =>
                  f.readAsStringSync().contains('This is called internally by'),
            )
            .length,
        9,
      );

      // ZBytes' construction surface, which is why removal was never the
      // remedy for the two single-constructor escapes.
      final bytes = File('lib/src/bytes.dart').readAsStringSync();
      final ctors = RegExp(
        r'^\s{2}(?:const\s+|factory\s+)?ZBytes[._]',
        multiLine: true,
      ).allMatches(bytes).length;
      expect(
        ctors,
        15,
        reason:
            'ZBytes declares 15 constructors of which one (ZBytes._) is '
            'private -- 14 public. The plan recorded this as "15 public + 1 '
            'private", i.e. 16, and marked it verified',
      );
      expect(bytes.contains('ZBytes._('), isTrue);

      // ⛔ AND THE FIGURE 49 IS NOT ADOPTED. It counts "exported members that
      // are internal plumbing", and PLUMBING is a judgement -- no mechanical
      // instrument can produce it, so no re-derivation would reproduce it.
      // Recorded as not adopted rather than chased.
    });

    test('the two censuses are cross-checked over a STATED scope, and they '
        'share no code', () {
      // ⛔ THE SCOPE IS A RULING, NOT AN OVERSIGHT. The text scan does not
      // follow `export 'zenoh.dart';` -- it opens the stable door, finds no
      // declarations in it, and moves on -- so it reads 42 on the unstable
      // door where the resolved instrument reads 62. Teaching it to follow
      // the re-export would move it onto the resolved instrument's own
      // assumption, and "two text scans are one instrument" would become
      // "two resolvers are one instrument".
      //
      // ⭐ NO COVERAGE IS LOST: the 42 the unstable door re-exports are
      // cross-checked AT THE STABLE DOOR, where both instruments read them;
      // the 20 unstable-only names are cross-checked at the unstable door.
      // Every one of the 62 is seen by two instruments; only the attribution
      // differs.
      expect(
        publicMembers('lib/zenoh.dart'),
        unorderedEquals(resolvedExportNamespace('lib/zenoh.dart')),
      );
      expect(
        publicMembers('lib/zenoh_unstable.dart'),
        unorderedEquals(unstableOnlyNames),
      );
    });

    test('the breaking inventory covers every silent stop', () {
      // ⛔ A SILENT STOP IS INVISIBLE TO A SEARCH FOR THROWS. Nothing this
      // unit removed throws; the call simply stops resolving, or the symbol
      // stops being exported from the shared object. That is why each is
      // NAMED rather than summarised.
      final changelog = File('../CHANGELOG.md').readAsStringSync();
      // The section that announced this unit, found above the last release
      // before it (0.19.0) — see helpers/changelog_section.dart.
      final announced = changelogSectionAnnouncing(
        changelog,
        sessionOpenHelpers.first,
        anchor: '0.19.0',
      );
      expect(announced, isNotNull);
      for (final name in sessionOpenHelpers) {
        expect(announced, contains(name));
      }
      for (final s in const [
        'zd_bytes_to_string',
        'zd_bytes_copy_from_str',
        'zd_config_loan',
        'zd_query_keyexpr',
        'zd_whatami_to_view_string',
      ]) {
        expect(announced, contains(s));
      }
      // Each names its recovery, which is the half a bare removal notice
      // leaves out.
      expect(announced, contains('ZenohException'));
      expect(announced, contains('embedder'));
    });

    // --- Edge cases ---

    test('what could not be established is named', () {
      // ⛔ THIS CELL ASSERTS NOTHING ABOUT THE PRODUCT. It exists so the
      // residuals are carried in a file that runs, rather than in a PR body
      // that is read once. Each line below is a thing this unit did NOT
      // settle, and the assertion is only that they are still recorded here.
      const residuals = <String>[
        // The crash class remains REACHABLE, by decision. Annotating the
        // three escapes is a warning, not a fence: every arm still resolves.
        'crash class remains reachable by decision',
        // The figure 49 could not be re-derived: it counts "exported members
        // that are internal plumbing", and plumbing is a judgement.
        'the figure 49 has no instrument',
        // implementation_imports fires only when a consumer enables a lint
        // set; a bare consumer importing src/ directly draws nothing.
        'implementation_imports is opt-in for the consumer',
        // The text-scan census does not follow a non-src/ re-export, so its
        // cross-check scope is stated rather than universal.
        'the text scan does not follow the re-export',
        // AdvancedPublisher.declare on a stable native is MEASURED, twice:
        // development/research/ci-close-record-API-20260910.md §6 and
        // development/reviews/ca2-code-review-API-20260910.md §3. It throws a
        // clean ArgumentError at the lazy lookup of
        // zd_advanced_publisher_sizeof, before either pointer is touched; on
        // unstable the same entry returns 248. What stays unsettled is
        // diagnosability: the message names the undefined symbol, not the
        // variant to select. (This line read "unmeasured" until 2026-09-10.)
        'AdvancedPublisher.declare on stable fails loud, naming no variant',
        // The host's locked-memory ceiling is SHARED and an unrelated
        // workload competes for it, which is a live uncontrolled variable
        // behind the shared-memory reds.
        'the locked-memory ceiling is shared with an unrelated workload',
      ];
      expect(residuals, hasLength(6));
      for (final r in residuals) {
        expect(r, isNotEmpty);
      }
    });
  });
}
