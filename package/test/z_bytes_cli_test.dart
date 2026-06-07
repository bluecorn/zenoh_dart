import 'dart:io';

import 'package:test/test.dart';

/// The FVM-resolved Dart executable path.
final _dartExe = Platform.resolvedExecutable;

void main() {
  final packageRoot = Directory.current.path;

  group('z_bytes CLI', () {
    test('runs and prints PASS with no FAIL', () async {
      final result = await Process.run(_dartExe, [
        'run',
        'example/z_bytes.dart',
      ], workingDirectory: packageRoot);

      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(result.stdout.toString(), contains('PASS'));
      expect(result.stdout.toString(), isNot(contains('FAIL')));
    }, timeout: Timeout(Duration(seconds: 30)));
  });
}
