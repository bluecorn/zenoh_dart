// `changelogSectionAnnouncing`, driven over the edits a release makes to the
// real CHANGELOG.
//
// Four cells take a unit's announcement out of the root CHANGELOG through
// that helper. This file does not re-assert what they pin. It asserts that the
// section they are handed is still the ANNOUNCING one after each
// release-shaped edit, and that the helper still comes back empty-handed when
// the announcement is really gone.
//
// The shapes are built on top of whatever the CHANGELOG is when this runs, so
// the file means the same thing before a release (an `## Unreleased` heading
// to rename) and after one (nothing to rename; the other shapes still apply).
import 'dart:io';

import 'package:test/test.dart';

import 'helpers/changelog_section.dart';

/// The entry each CHANGELOG-reading cell finds its section by.
const _entries = <String, String>{
  'api_surface_test.dart (both CHANGELOG cells)': 'completeOpenFromPost',
  'blockfirst_stable_guard_test.dart':
      '- **`CongestionControl.blockFirst` is now REFUSED',
  'dead_export_test.dart': 'zd_bytes_copy_from_str',
};

/// The last release published before those units.
const _anchor = '0.19.0';

const _release = '## 1.0.0-rc.1 — 2026-09-13';
const _laterEntry = "### Fixed\n\n- **A later unit's entry.**\n\n";

/// [changelog] with [block] inserted above its first `## ` heading.
String _onTop(String changelog, String block) {
  final i = changelog.startsWith('## ') ? 0 : changelog.indexOf('\n## ') + 1;
  return changelog.substring(0, i) + block + changelog.substring(i);
}

/// A section without its heading line, which a rename changes.
String _body(String section) => section.substring(section.indexOf('\n'));

void main() {
  final real = File('../CHANGELOG.md').readAsStringSync();
  final unreleased = RegExp(r'^## Unreleased$', multiLine: true);
  final released = real.replaceFirst(unreleased, _release);
  const anchorLine = '\n## $_anchor\n';

  final shapes = <String, String>{
    'an empty Unreleased heading left above the release': _onTop(
      released,
      '## Unreleased\n\n',
    ),
    'a later unit accrues under a new Unreleased heading': _onTop(
      released,
      '## Unreleased\n\n$_laterEntry',
    ),
    'a later release lands on top': _onTop(
      released,
      '## 9.9.9 — later\n\n$_laterEntry',
    ),
    'a section is inserted just above the anchor': released.replaceFirst(
      anchorLine,
      '\n## 0.20.0 — reconciled\n\n- A reconciled entry.\n$anchorLine',
    ),
  };

  group('changelogSectionAnnouncing over release-shaped edits', () {
    test('every shape is an edit, and the anchor is present', () {
      // ⛔ A shape that changed nothing would pass for the wrong reason.
      expect(real, contains(anchorLine));
      for (final MapEntry(key: name, value: shape) in shapes.entries) {
        expect(
          shape,
          isNot(equals(released)),
          reason: '"$name" edited nothing',
        );
      }
      if (unreleased.hasMatch(real)) {
        expect(
          released,
          isNot(equals(real)),
          reason: 'the rename edited nothing',
        );
      }
    });

    for (final MapEntry(key: cell, value: entry) in _entries.entries) {
      test('$cell: the announcing section survives every shape', () {
        final original = changelogSectionAnnouncing(
          real,
          entry,
          anchor: _anchor,
        );
        expect(
          original,
          isNotNull,
          reason: 'the CHANGELOG does not announce "$entry" above $_anchor',
        );
        final all = {'the Unreleased heading renamed': released, ...shapes};
        for (final MapEntry(key: name, value: shape) in all.entries) {
          final got = changelogSectionAnnouncing(shape, entry, anchor: _anchor);
          expect(got, isNotNull, reason: 'after "$name" no section was found');
          expect(
            _body(got!),
            equals(_body(original!)),
            reason: 'after "$name" the helper returned a different section',
          );
        }
      });

      test(
        '$cell: a later release naming the entry again does not move it',
        () {
          final original = changelogSectionAnnouncing(
            real,
            entry,
            anchor: _anchor,
          )!;
          final got = changelogSectionAnnouncing(
            _onTop(
              released,
              '## 9.9.9 — later\n\n- Mentions $entry again.\n\n',
            ),
            entry,
            anchor: _anchor,
          );
          expect(_body(got!), equals(_body(original)));
        },
      );

      test('$cell: CONTROL — an announcement that is gone is not found', () {
        expect(
          changelogSectionAnnouncing(
            released.replaceAll(entry, ''),
            entry,
            anchor: _anchor,
          ),
          isNull,
          reason: 'the entry was deleted and a section was still returned',
        );
        expect(
          changelogSectionAnnouncing(
            released
                .replaceAll(entry, '')
                .replaceFirst(anchorLine, '$anchorLine\n$entry\n'),
            entry,
            anchor: _anchor,
          ),
          isNull,
          reason:
              'the entry sits only BELOW the anchor, in a release that '
              'predates the change, and a section was still returned',
        );
      });
    }

    test(
      'CONTROL — a missing anchor fails rather than searching everything',
      () {
        expect(
          () => changelogSectionAnnouncing(
            real.replaceFirst(anchorLine, '\n'),
            _entries.values.first,
            anchor: _anchor,
          ),
          throwsA(isA<TestFailure>()),
        );
      },
    );
  });
}
