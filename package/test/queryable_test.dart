import 'dart:async';

import 'package:test/test.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/queryable.dart';
import 'package:zenoh_dart/src/session.dart';

void main() {
  group('Queryable lifecycle', () {
    late Session session;

    setUpAll(() async {
      session = await Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('declareQueryable returns a Queryable', () {
      final queryable = session.declareQueryable('demo/test/queryable');
      expect(queryable, isA<Queryable>());
      queryable.close();
    });

    test('Queryable.keyExpr returns the declared key expression', () {
      final queryable = session.declareQueryable('demo/test/queryable');
      expect(queryable.keyExpr, equals('demo/test/queryable'));
      queryable.close();
    });

    test('Queryable.close completes without error', () {
      final queryable = session.declareQueryable('demo/test/queryable');
      expect(queryable.close, returnsNormally);
    });

    test('Queryable.close is idempotent', () {
      final queryable = session.declareQueryable('demo/test/queryable')
        ..close();
      expect(queryable.close, returnsNormally);
    });

    test('declareQueryable on closed session throws StateError', () async {
      final closedSession = await Session.open()
        ..close();
      expect(
        () => closedSession.declareQueryable('demo/test/queryable'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test(
      'declareQueryable with invalid key expression throws ZenohException',
      () {
        expect(
          () => session.declareQueryable(''),
          throwsA(isA<ZenohException>()),
        );
      },
    );

    test('Queryable stream closes on undeclare', () async {
      final queryable = session.declareQueryable('demo/test/queryable/stream');

      final doneCompleter = Completer<void>();
      queryable.stream.listen((_) {}, onDone: doneCompleter.complete);

      queryable.close();

      await doneCompleter.future.timeout(const Duration(seconds: 5));
    });
  });
}
