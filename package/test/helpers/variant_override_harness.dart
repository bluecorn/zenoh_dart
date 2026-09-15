// Subprocess harness for the fix-round's S-7 / S-9 riders.
//
// The library loader reads ZENOH_DART_VARIANT from the environment, and the
// environment can only be set for a CHILD process — hence a harness rather
// than an in-process test.
//
// Prints exactly one line:
//   LOADED=<path>   the loader resolved a library
//   THREW=<message> the loader refused
import 'dart:io';

import 'package:zenoh_dart/src/native_lib.dart';

void main() {
  try {
    ensureInitialized();
    stdout.writeln('LOADED=$resolvedLibraryPath');
  } on Object catch (e) {
    stdout.writeln('THREW=$e');
  }
}
