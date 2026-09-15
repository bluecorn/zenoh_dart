// Reading one unit's announcement out of the root CHANGELOG, in a way a
// release does not break.
//
// Several cells pin a product fact through the CHANGELOG: a removal must be
// announced, with its recovery, in the notes of the release that ships it.
// They used to take the `## Unreleased` section by name. A release renames
// that heading, or leaves an empty one above the new version — either way the
// section they read vanished or went empty, and every one of them went red at
// the release's first stage.
//
// "The topmost section" and "the section the pubspec version names" both
// survive that edit and both go red again at the NEXT release, when a newer
// section lands on top. So the anchor here is a heading that already exists
// and never moves: the last release published before the unit.

import 'package:test/test.dart';

/// The CHANGELOG section that announced [entry]: of the sections above the
/// `## [anchor]` heading, the one CLOSEST to that heading which contains
/// [entry].
///
/// [anchor] is the last release published before the change — for example
/// `'0.19.0'`. Releases add sections at the top, so the section closest to
/// the anchor that names the entry is the one that first announced it, and a
/// later release that mentions the same name again does not move it.
///
/// Returns that section from its `## ` heading up to (not including) the
/// newline before the next `## ` heading, or null when no section above the
/// anchor contains [entry]. Fails when the anchor heading itself is missing:
/// a search bounded by a heading that is not there is not bounded.
String? changelogSectionAnnouncing(
  String changelog,
  String entry, {
  required String anchor,
}) {
  final starts = <int>[
    if (changelog.startsWith('## ')) 0,
    for (final m in RegExp('\n## ').allMatches(changelog)) m.start + 1,
  ];
  String? announcing;
  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1] - 1 : changelog.length;
    final section = changelog.substring(starts[i], end);
    final heading = section.split('\n').first;
    if (heading == '## $anchor' || heading.startsWith('## $anchor ')) {
      return announcing;
    }
    if (section.contains(entry)) announcing = section;
  }
  fail(
    'the CHANGELOG has no `## $anchor` heading, so there is no fixed point '
    'to find the announcing section above',
  );
}
