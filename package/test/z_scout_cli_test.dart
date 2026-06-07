import 'dart:io';

import 'package:test/test.dart';

void main() {
  // Get the package root (where pubspec.yaml lives)
  // Tests run from package/
  final packageRoot = Directory.current.path;
  final dartBin = Platform.resolvedExecutable;

  group('z_scout CLI', () {
    Future<ProcessResult> runZScout([List<String> args = const []]) async {
      return Process.run('fvm', [
        'dart',
        'run',
        'example/z_scout.dart',
        ...args,
      ], workingDirectory: packageRoot).timeout(const Duration(seconds: 15));
    }

    test('runs with default arguments', () async {
      final result = await runZScout();
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      final stdout = result.stdout as String;
      // Must contain either 'Hello' or 'Did not find any zenoh process'
      expect(
        stdout.contains('Hello') ||
            stdout.contains('Did not find any zenoh process'),
        isTrue,
        reason: 'stdout should contain Hello or no-process message: $stdout',
      );
    });

    test('accepts connect and listen flags', () async {
      final result = await runZScout(['-e', 'tcp/127.0.0.1:7447']);
      // Process completes without argument parse error
      final stderr = result.stderr as String;
      expect(stderr, isNot(contains('Could not find an option named')));
      expect(stderr, isNot(contains('FormatException')));
    });

    test('discovers a listening peer', () async {
      // Use a helper script that opens a session with multicast on loopback
      // and then scouts with multicast on loopback. This is necessary because
      // multicast scouting on the default interface may not work on all
      // machines (especially when loopback doesn't have the MULTICAST flag).
      final helperScript = '''
import 'package:zenoh/zenoh.dart';

Future<void> main() async {
  Zenoh.initLog('error');

  // Open a peer session with multicast on loopback and TCP listen
  final sessionConfig = Config();
  sessionConfig.insertJson5('listen/endpoints', '["tcp/127.0.0.1:18561"]');
  sessionConfig.insertJson5('scouting/multicast/interface', '"lo"');
  final session = Session.open(config: sessionConfig);

  // Wait for session to bind and be discoverable
  await Future.delayed(Duration(seconds: 2));

  // Scout with multicast on loopback
  final scoutConfig = Config();
  scoutConfig.insertJson5('scouting/multicast/interface', '"lo"');
  final hellos = await Zenoh.scout(config: scoutConfig, timeoutMs: 2000);

  if (hellos.isEmpty) {
    print('NO_HELLOS');
  } else {
    for (final hello in hellos) {
      print(hello);
    }
  }

  session.close();
}
''';

      // Write temporary helper script
      final tempDir = await Directory.systemTemp.createTemp('z_scout_test_');
      final tempScript = File('${tempDir.path}/scout_helper.dart');
      await tempScript.writeAsString(helperScript);

      addTearDown(() async {
        await tempDir.delete(recursive: true);
      });

      // Run the helper script from the repo root so it can
      // resolve the package:zenoh import via workspace package_config.json
      final result = await Process.run(dartBin, [
        'run',
        '--packages=$packageRoot/.dart_tool/package_config.json',
        tempScript.path,
      ], workingDirectory: packageRoot).timeout(const Duration(seconds: 15));

      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      final stdout = result.stdout as String;

      // Should discover at least one Hello with zid, whatami, and locators
      expect(stdout, contains('Hello'));
      expect(stdout, matches(RegExp(r'zid: [0-9a-f]+')));
      expect(stdout, matches(RegExp(r'whatami: (router|peer|client)')));
      expect(stdout, contains('locators:'));
    });

    test('handles no discoverable entities gracefully', () async {
      // With default config and short timeout, may or may not find entities
      // (depends on network). Either way, exit code should be 0.
      final result = await runZScout();
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      final stdout = result.stdout as String;
      // Should contain Scouting... at minimum
      expect(stdout, contains('Scouting...'));
    });
  });
}
