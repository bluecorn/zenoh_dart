// The example cookbook's inventory, checked against the tree.
//
// `example/README.md` says which of canon's examples this package ships: an
// entry per example, a coverage map with one row per canon example, a summary
// line, and a section of examples deliberately not implemented. Its previous
// guard derived the summary from the map and never looked at a directory — so
// when two examples shipped and the document went on declaring them absent
// (and the pattern they demonstrate an anti-pattern), map and summary still
// agreed with each other and the guard stayed green. It compared the document
// with itself.
//
// Here every expectation is computed from files: canon's examples are
// `extern/zenoh-c/examples/z_*.c`, this package's are `example/z_*.dart`. The
// document is only ever the thing checked. What no directory can say — why an
// example is absent, and whether that is permanent or future — stays the
// document's to state, and is read from it rather than restated here.
//
// Out of reach, stated so it is not assumed covered: prose that is not
// inventory (which variant ships which API, a method's return type), and the
// per-example flag tables.

import 'dart:io';

import 'package:test/test.dart';

/// The `z_*` program names in [dir] carrying [extension], without it.
Set<String> _programs(String dir, String extension) {
  final d = Directory(dir);
  if (!d.existsSync()) {
    fail(
      '$dir does not exist, so there is no tree to check the cookbook against',
    );
  }
  final name = RegExp('^(z_[a-z0-9_]+)${RegExp.escape(extension)}\$');
  return {
    for (final e in d.listSync())
      if (e is File) ?name.firstMatch(e.uri.pathSegments.last)?.group(1),
  };
}

/// The lines of the `## [title]` section of [readme], fenced code excluded.
///
/// Null when the heading is absent.
List<String>? _section(String readme, String title) {
  final lines = readme.split('\n');
  final start = lines.indexOf('## $title');
  if (start < 0) return null;
  final body = <String>[];
  var fenced = false;
  for (final line in lines.skip(start + 1)) {
    if (line.startsWith('```')) {
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    if (line.startsWith('## ')) break;
    body.add(line);
  }
  return body;
}

/// Every example a `### ` heading in [lines] names: the part before ` — `,
/// split at `/`.
Set<String> _headingNames(List<String> lines) {
  final token = RegExp(r'^z_[a-z0-9_]+$');
  return {
    for (final line in lines)
      if (line.startsWith('### '))
        for (final part in line.substring(4).split(' — ').first.split('/'))
          if (token.hasMatch(part.trim())) part.trim(),
  };
}

typedef _Row = ({String canon, String dart, String status});

/// The coverage map's rows: a canon example, its zenoh-dart file, a status.
List<_Row> _rows(List<String> coverage) => [
  for (final line in coverage)
    if (line.startsWith('| `z_') && line.endsWith('|'))
      if (line.split('|').map((c) => c.trim()).toList() case [
        _,
        final canon,
        final dart,
        final status,
        ...,
      ])
        (canon: canon, dart: dart, status: status),
];

/// Every way [readme] disagrees with the [canon] examples and the [shipped]
/// ones. Empty when it agrees.
List<String> coverageProblems(
  String readme, {
  required Set<String> canon,
  required Set<String> shipped,
}) {
  final problems = <String>[];

  // The coverage map: exactly one row per canon example, each saying what the
  // tree holds.
  final coverage = _section(readme, 'Coverage Map');
  if (coverage == null) return ['no "## Coverage Map" section'];
  final rows = _rows(coverage);
  final seen = <String>{};
  for (final row in rows) {
    final stem = row.canon
        .replaceAll('`', '')
        .replaceFirst(RegExp(r'\.c$'), '');
    if (!seen.add(stem)) problems.add('coverage map: $stem has two rows');
    if (!canon.contains(stem)) {
      problems.add('coverage map: $stem has a row but canon has no $stem.c');
      continue;
    }
    final ships = shipped.contains(stem);
    final dart = ships ? '`$stem.dart`' : '--';
    if (row.dart != dart) {
      problems.add(
        'coverage map: $stem reads ${row.dart} in the zenoh-dart column; the '
        'tree says $dart',
      );
    }
    if (ships && !row.status.startsWith('Implemented')) {
      problems.add(
        'coverage map: $stem ships as example/$stem.dart but its status reads '
        '"${row.status}"',
      );
    }
    if (!ships &&
        !(row.status.startsWith('Absent') || row.status.startsWith('Future'))) {
      problems.add(
        'coverage map: $stem does not ship but its status reads '
        '"${row.status}"',
      );
    }
  }
  for (final stem in canon.difference(seen)) {
    problems.add(
      'coverage map: canon has $stem.c and the map has no row for it',
    );
  }

  // The summary: the implemented count is the tree's; the split of what does
  // not ship into permanent and future is the document's own judgement.
  final implemented = canon.intersection(shipped).length;
  int statusCount(String prefix) =>
      rows.where((r) => r.status.startsWith(prefix)).length;
  final summary =
      '**Current:** $implemented implemented, '
      '${statusCount('Absent')} permanently absent, '
      '${statusCount('Future')} future.';
  final summaries = coverage
      .where((l) => l.startsWith('**Current:**'))
      .toList();
  if (summaries.length != 1 || summaries.single != summary) {
    problems.add(
      'coverage summary: reads ${summaries.isEmpty ? 'nothing' : summaries.join(' / ')}; '
      'the tree says $summary',
    );
  }

  // The entries: every shipped example has one, and none documents an example
  // that does not ship.
  final examples = _section(readme, 'Examples');
  if (examples == null) return [...problems, 'no "## Examples" section'];
  final documented = _headingNames(examples);
  for (final stem in shipped.difference(documented)) {
    problems.add('entries: example/$stem.dart ships and no entry names it');
  }
  for (final stem in documented.difference(shipped)) {
    problems.add('entries: an entry names $stem, which does not ship');
  }

  // The absent examples: none of them ships.
  final absent = _section(readme, 'Absent Examples');
  if (absent != null) {
    for (final stem in _headingNames(absent).intersection(shipped)) {
      problems.add(
        'absent examples: $stem is declared not implemented, and '
        'example/$stem.dart ships',
      );
    }
  }
  return problems;
}

void main() {
  group('the example cookbook agrees with the tree', () {
    test('the tree is read, not assumed', () {
      // An empty or unread directory would make every check below vacuous.
      expect(
        _programs('../extern/zenoh-c/examples', '.c').length,
        greaterThan(20),
      );
      expect(_programs('example', '.dart').length, greaterThan(20));
      final rows = _rows(
        _section(
              File('example/README.md').readAsStringSync(),
              'Coverage Map',
            ) ??
            const [],
      );
      expect(
        rows.length,
        greaterThan(20),
        reason: 'the coverage map did not parse',
      );
    });

    test('its inventory is the examples canon has and this package ships', () {
      final problems = coverageProblems(
        File('example/README.md').readAsStringSync(),
        canon: _programs('../extern/zenoh-c/examples', '.c'),
        shipped: _programs('example', '.dart'),
      );
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    group('CONTROL', () {
      const agreeing = '''
## Absent Examples

### z_c — Not Here

## Examples

### z_a / z_b — Both Here

```
### z_fenced — a heading inside a code fence names nothing
```

## Coverage Map

| zenoh-c Example | zenoh-dart | Status |
|---|---|---|
| `z_a.c` | `z_a.dart` | Implemented |
| `z_b.c` | `z_b.dart` | Implemented |
| `z_c.c` | -- | Absent (a reason) |

**Current:** 2 implemented, 1 permanently absent, 0 future.
''';
      const canon = {'z_a', 'z_b', 'z_c'};

      test('a document that agrees with its tree reads no problem', () {
        expect(
          coverageProblems(agreeing, canon: canon, shipped: {'z_a', 'z_b'}),
          isEmpty,
        );
      });

      test('an example that ships while the document still declares it absent '
          'is seen at every place the document says so', () {
        // The shape that shipped in the candidate. The document's summary and
        // map still agree with EACH OTHER, so the previous guard, which
        // compared those two, passed it.
        final problems = coverageProblems(
          agreeing,
          canon: canon,
          shipped: {'z_a', 'z_b', 'z_c'},
        );
        expect(
          problems,
          containsAll([
            contains('coverage map: z_c reads --'),
            contains('coverage map: z_c ships'),
            contains('coverage summary'),
            contains('entries: example/z_c.dart ships'),
            contains('absent examples: z_c'),
          ]),
          reason: problems.join('\n'),
        );
      });

      test('an entry or a row for an example that does not ship is seen', () {
        final problems = coverageProblems(
          agreeing,
          canon: canon,
          shipped: {'z_a'},
        );
        expect(
          problems,
          containsAll([
            contains('coverage map: z_b reads `z_b.dart`'),
            contains('coverage map: z_b does not ship'),
            contains('coverage summary'),
            contains('entries: an entry names z_b'),
          ]),
          reason: problems.join('\n'),
        );
      });

      test('a canon example with no row, and a row canon lacks, are seen', () {
        final problems = coverageProblems(
          agreeing,
          canon: {'z_a', 'z_b', 'z_d'},
          shipped: {'z_a', 'z_b'},
        );
        expect(
          problems,
          containsAll([
            contains('canon has z_d.c and the map has no row'),
            contains('z_c has a row but canon has no z_c.c'),
          ]),
          reason: problems.join('\n'),
        );
      });
    });
  });
}
