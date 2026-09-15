// The `String | KeyExpr` union on the advanced (unstable-door) entry points.
//
// Split from `keyexpr_union_test.dart` because these need the unstable door
// open, and because one leg here has to run on the OPPOSITE side of the
// variant matrix from the rest.
import 'dart:async';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

import 'helpers/poll.dart';

/// Matches the union's wrong-type rejection: named parameter, both types.
Matcher throwsUnionArgumentError(String paramName) => throwsA(
  isA<ArgumentError>()
      .having((e) => e.name, 'name', paramName)
      .having(
        (e) => e.message.toString(),
        'message',
        allOf(contains('String'), contains('KeyExpr')),
      ),
);

void main() {
  group(
    'union -- advanced pub/sub',
    skip: ZenohFeatures.hasUnstableApi
        ? false
        : 'requires the unstable variant (unstable API)',
    () {
      late Session publisherSession;
      late Session subscriberSession;

      setUpAll(() async {
        final configA = Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19090"]')
          ..insertJson5('timestamping/enabled', 'true')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false');
        publisherSession = await Session.open(config: configA);

        await Future<void>.delayed(const Duration(milliseconds: 500));

        final configB = Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19090"]')
          ..insertJson5('timestamping/enabled', 'true')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false');
        subscriberSession = await Session.open(config: configB);

        await Future<void>.delayed(const Duration(seconds: 1));
      });

      tearDownAll(() {
        publisherSession.close();
        subscriberSession.close();
      });

      test(
        'both advanced entry points accept a declared key expression',
        () async {
          final pattern = subscriberSession.declareKeyExpr(
            'zenoh/dart/f5/adv/**',
          );
          final subscriber = subscriberSession.declareAdvancedSubscriber(
            pattern,
          );
          addTearDown(subscriber.close);
          final received = <Sample>[];
          final sub = subscriber.stream.listen(received.add);
          addTearDown(sub.cancel);

          await Future<void>.delayed(const Duration(seconds: 1));

          final declared = publisherSession.declareKeyExpr(
            'zenoh/dart/f5/adv/a',
          );
          final publisher = publisherSession.declareAdvancedPublisher(declared);
          addTearDown(publisher.close);

          // The getter's type is unchanged.
          expect(publisher.keyExpr, equals('zenoh/dart/f5/adv/a'));

          publisher.put('advanced');

          await waitUntil(
            () => received.isNotEmpty,
            description: 'the advanced publication',
          );
          expect(received.first.keyExpr, equals('zenoh/dart/f5/adv/a'));
          expect(received.first.payload, equals('advanced'));

          publisherSession.undeclareKeyExpr(declared);
          subscriberSession.undeclareKeyExpr(pattern);
        },
      );

      test('a wrong-typed argument is an ArgumentError', () {
        expect(
          () => publisherSession.declareAdvancedPublisher(42),
          throwsUnionArgumentError('keyExpr'),
        );
        expect(
          () => subscriberSession.declareAdvancedSubscriber(42),
          throwsUnionArgumentError('keyExpr'),
        );
      });

      test('an invalid string still throws with canon own code', () {
        expect(
          () => publisherSession.declareAdvancedPublisher('demo//x'),
          throwsA(
            isA<ZenohException>().having((e) => e.returnCode, 'returnCode', -1),
          ),
        );
      });
    },
  );

  // ⚠️ INVERSE GATING, deliberately. This group asserts the ORDER of two
  // guards, and the only way to observe that order is on a native where the
  // first one actually fires -- the stable variant. Placed inside the group
  // above it would skip on exactly the leg it needs and its green would mean
  // "never ran". Under the variant matrix this executes on the stable leg and
  // is inert on the unstable one.
  group(
    'union -- the unstable gate still runs before key-expression validation',
    skip: ZenohFeatures.hasUnstableApi
        ? 'unstable variant -- the gate does not fire'
        : false,
    () {
      late Session session;

      setUpAll(() async => session = await Session.open());
      tearDownAll(() => session.close());

      test(
        'an invalid string surfaces UnsupportedError, not ZenohException',
        () {
          // requireUnstable() runs first, so a stable-native consumer learns
          // that the door is shut rather than that their key expression was
          // malformed.
          expect(
            () => session.declareAdvancedPublisher('demo//x'),
            throwsUnsupportedError,
          );
        },
      );

      test('a wrong-typed argument also surfaces UnsupportedError', () {
        expect(
          () => session.declareAdvancedSubscriber(42),
          throwsUnsupportedError,
        );
      });
    },
  );
}
