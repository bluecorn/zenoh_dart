// Reads `Zenoh.resolvedLibraryPath` through the PUBLIC door only.
//
// ⛔ THE IMPORT LIST IS THE ASSERTION. This file imports
// `package:zenoh_dart/zenoh.dart` and nothing under `src/`. If the accessor
// were reachable only by reaching into `src/`, this file would not compile —
// which is the criterion the seed states, rather than "the getter exists".
//
// ⛔ AND A CHILD PROCESS, because two of the three modes are about the state
// BEFORE and AFTER a failed initialisation, and a suite process has already
// loaded the library long before any cell runs.
//
// Modes:
//   cold           read it having made no zenoh call at all
//   after-open     open a session, then read it
//   after-failure  force the load to fail, then read it
//
// Prints:
//   PATH=<path|<null>>
//   LOADED         only when a session was actually opened
//   INIT_THREW=<message>
//   PROBE_DONE
import 'dart:io';

import 'package:zenoh_dart/zenoh.dart';

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'cold' : args[0];

  switch (mode) {
    case 'after-open':
      final config = Config()
        ..insertJson5('mode', '"peer"')
        ..insertJson5('scouting/multicast/enabled', 'false')
        ..insertJson5('scouting/gossip/enabled', 'false');
      (await Session.open(config: config)).close();
      stdout.writeln('LOADED');

    case 'after-failure':
      try {
        final config = Config();
        (await Session.open(config: config)).close();
        stdout.writeln('LOADED');
      } on Object catch (e) {
        // One line, first line only: the loader's message is multi-line and
        // the parent matches on a marker, not on the prose.
        stdout.writeln('INIT_THREW=${'$e'.split('\n').first}');
      }

    case 'cold':
      // ⛔ NOTHING ELSE HAPPENS HERE. Reading the accessor is the only zenoh
      // interaction in this process, so a `LOADED` line — or a 13 MB
      // library appearing in the address space — would mean the accessor
      // initialised, which is the defect the design decision avoids.
      break;

    default:
      stdout.writeln('PROBE_UNKNOWN_MODE $mode');
  }

  stdout
    ..writeln('PATH=${Zenoh.resolvedLibraryPath ?? '<null>'}')
    ..writeln('PROBE_DONE');
}
