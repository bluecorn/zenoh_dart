// Seed #6 slices 2-3: the query-parameters channel, both directions.
//
// The selector's parameters segment is a value a caller chooses and a queryable
// reads back, so it is a value path under the fidelity doctrine: correct in,
// correct out, over the CONTRACT's domain rather than over what today's callers
// happen to send.
//
// At HEAD the channel was strlen-seamed on both sides -- the shim handed canon
// a NUL-terminated `const char*` and posted the received parameters back as a
// C string -- so an interior NUL truncated the value silently in the same way
// the v0.18.1 payload class did. Canon has stable length-carried siblings for
// both send entries (`z_get_with_parameters_substr`,
// `z_querier_get_with_parameters_substr`), and `z_get` is literally the substr
// entry with `strlen_or_zero` applied (zenoh-c src/get.rs:305), so moving onto
// them is a strictly-wider carriage rather than a different code path.
//
// ⚠️ Spelling: an interior NUL is written `\x00`. Never a raw byte -- a raw NUL
// makes this file binary to grep and invisible to diff.
//
// Domain note: canon requires the parameters string to be valid UTF-8
// (`z_get_with_parameters_substr` rejects otherwise with Z_EINVAL), so the
// contract's domain is UTF-8 text -- interior NUL included, since NUL is
// valid UTF-8 -- and NOT arbitrary bytes. The cells drive exactly that domain.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

void main() {
  group('Slice 2: parameters are length-carried on the send seam (TCP 19340)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19340"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19340"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    /// Declares a Stream-path queryable on [key] that answers every query and
    /// reports the `parameters` it observed.
    ///
    /// The queryable replies so the getter's stream terminates promptly; the
    /// parameters are captured before the reply so a delivery failure shows up
    /// as a timeout on [observed] rather than as a silent pass.
    Completer<String> observeParameters(String key) {
      final observed = Completer<String>();
      final queryable = sessionA.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        if (!observed.isCompleted) observed.complete(query.parameters);
        query
          ..reply(key, 'ack')
          ..dispose();
      });
      return observed;
    }

    Future<String> roundTripViaGet(String key, String parameters) async {
      final observed = observeParameters(key);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await sessionB
          .get(key, parameters: parameters)
          .toList()
          .timeout(const Duration(seconds: 10));
      return observed.future.timeout(const Duration(seconds: 5));
    }

    test(
      'an interior NUL in query parameters survives the send seam',
      () async {
        const sent = 'a=1\x00b=2';
        final received = await roundTripViaGet(
          'zenoh/dart/test/s2/get/nul',
          sent,
        );
        // Before the rebase canon measured the length with strlen and the value
        // arrived as 'a=1'.
        expect(received, equals(sent));
      },
    );

    test("the querier's send seam carries an interior NUL too", () async {
      const key = 'zenoh/dart/test/s2/querier/nul';
      const sent = 'x=1\x00y=2';
      final observed = observeParameters(key);
      final querier = sessionB.declareQuerier(key);
      addTearDown(querier.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      await querier
          .get(parameters: sent)
          .toList()
          .timeout(const Duration(seconds: 10));

      expect(
        await observed.future.timeout(const Duration(seconds: 5)),
        equals(sent),
      );
    });

    test('ordinary ASCII parameters round-trip unchanged', () async {
      // The rebase is not a behaviour change for the common case: this is the
      // control that keeps the two NUL cells above from passing because the
      // whole channel broke in some new way.
      const sent = 'key=value;mode=plain';
      expect(
        await roundTripViaGet('zenoh/dart/test/s2/get/ascii', sent),
        equals(sent),
      );
    });

    test('a multi-byte UTF-8 parameters string round-trips', () async {
      // Canon requires valid UTF-8 here, so multi-byte sequences -- not
      // arbitrary bytes -- are the wide end of this channel's domain.
      const sent = 'city=København;emoji=🛰;cjk=键值';
      expect(
        await roundTripViaGet('zenoh/dart/test/s2/get/utf8', sent),
        equals(sent),
      );
    });

    test('an empty parameters string is carried, not rejected', () async {
      // A zero-length buffer is a legitimate value, not an error: canon's
      // CStringView accepts a NULL pointer at length 0 and a non-NULL pointer
      // at length 0 alike.
      expect(
        await roundTripViaGet('zenoh/dart/test/s2/get/empty', ''),
        isEmpty,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Slice 3: MEASUREMENT — absent parameters versus present-but-empty.
  //
  // Canon documents NULL = "none" on the send side. Nothing anywhere — canon's
  // tests, cpp's tests, our probes — measured what the RECEIVE side reports for
  // absent versus present-but-empty. These cells pin what was observed, not
  // what would be convenient.
  //
  // MEASURED 2026-08-19 (probe + verbatim output at test/helpers/probes/):
  //
  //   q0  parameters OMITTED  -> parameters len=0 []   payloadBytes=null
  //   q1  parameters: ''      -> parameters len=0 []   payloadBytes=[]
  //   q2  parameters: 'x=1'   -> parameters len=3 [120,61,49]
  //
  // So the two are INDISTINGUISHABLE: both arrive as the empty string. Nothing
  // is "fixed" to manufacture a distinction canon does not draw — and the
  // collapse is canon's own, verified at source in slice 2:
  // `CStringView::new_borrowed` takes NULL-at-length-0 and non-NULL-at-0 alike
  // (extern/zenoh-c/src/collections.rs:164), so both reach zenoh as the same
  // empty `&str` before any wire encoding happens. `Query.parameters` is a
  // non-nullable String for the same reason: there is no absent value to show.
  group('Slice 3: parameters absent versus empty, pinned as measured '
      '(TCP 19341)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = await Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:19341"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sessionB = await Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:19341"]')
          ..insertJson5('scouting/multicast/enabled', 'false')
          ..insertJson5('scouting/gossip/enabled', 'false'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    /// Declares a queryable that captures the whole received [Query] shape.
    Completer<({String parameters, Uint8List? payloadBytes})> observe(
      String key,
    ) {
      final observed =
          Completer<({String parameters, Uint8List? payloadBytes})>();
      final queryable = sessionA.declareQueryable(key);
      addTearDown(queryable.close);
      queryable.stream.listen((query) {
        if (!observed.isCompleted) {
          observed.complete((
            parameters: query.parameters,
            payloadBytes: query.payloadBytes,
          ));
        }
        query
          ..reply(key, 'ack')
          ..dispose();
      });
      return observed;
    }

    test('absent parameters arrive as the empty string', () async {
      const key = 'zenoh/dart/test/s3/absent';
      final observed = observe(key);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await sessionB.get(key).toList().timeout(const Duration(seconds: 10));

      final result = await observed.future.timeout(const Duration(seconds: 5));
      expect(result.parameters, isEmpty);
    });

    test(
      'present-but-empty parameters arrive the same way — the pair',
      () async {
        const key = 'zenoh/dart/test/s3/empty';
        final observed = observe(key);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await sessionB
            .get(key, parameters: '')
            .toList()
            .timeout(const Duration(seconds: 10));

        final result = await observed.future.timeout(
          const Duration(seconds: 5),
        );
        // Identical to the cell above. Taken together the two pin the answer:
        // the distinction does not survive, and the binding does not pretend it
        // does.
        expect(result.parameters, isEmpty);
      },
    );

    test('the payload path DOES draw the distinction — the control', () async {
      // Without this, an empty-equals-empty result above could just as well be
      // a blind harness. The payload rides the same query, the same callback
      // and the same NativePort message, and it reports absent as null and
      // present-but-empty as a non-null empty list. So the harness can see an
      // absent/empty distinction when one exists, which makes the parameters
      // result a real finding.
      const absentKey = 'zenoh/dart/test/s3/payload/absent';
      const emptyKey = 'zenoh/dart/test/s3/payload/empty';
      final absent = observe(absentKey);
      final empty = observe(emptyKey);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      await sessionB
          .get(absentKey)
          .toList()
          .timeout(const Duration(seconds: 10));
      await sessionB
          .get(emptyKey, payload: ZBytes.fromString(''))
          .toList()
          .timeout(const Duration(seconds: 10));

      expect((await absent.future).payloadBytes, isNull);
      expect((await empty.future).payloadBytes, isNotNull);
      expect((await empty.future).payloadBytes, isEmpty);
    });
  });

  group('Slice 2: the dead strlen parameters accessor is gone', () {
    test('zd_query_parameters is absent from the generated bindings', () {
      // [inspection]. The accessor measured a received query's parameters with
      // strlen, on a path this seed length-carries. It had zero callers outside
      // the generated bindings, and leaving an exported strlen accessor on a
      // length-carried path is the thing a future maintainer wires up.
      final bindings = File('lib/src/bindings.dart').readAsStringSync();
      expect(bindings.contains('zd_query_parameters'), isFalse);

      final header = File('../src/zenoh_dart.h').readAsStringSync();
      expect(header.contains('zd_query_parameters'), isFalse);
    });

    test('no source outside the generated bindings ever called it', () {
      // The paired grep that makes the removal above a safe one rather than a
      // hopeful one: it is asserted over lib/ and test/ as they stand now, so
      // a future re-introduction fails here rather than silently.
      final offenders = <String>[];
      for (final dir in [Directory('lib'), Directory('test')]) {
        for (final entity in dir.listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          if (entity.path.endsWith('src/bindings.dart')) continue;
          if (entity.path.endsWith('parameters_fidelity_test.dart')) continue;
          // ⚠️ [API] slice 8 excluded, and the ground is that this cell's
          // subject changed shape. `dead_export_test.dart` names this symbol
          // in a STRING LITERAL, to assert that `example/README.md` no longer
          // presents it as an existing accessor -- which it did, falsely,
          // long after the removal this cell pins. An exclusion is right
          // here: the cell is about a CALL being re-introduced, and a file
          // whose whole purpose is to check that the symbol stays gone is not
          // that.
          if (entity.path.endsWith('dead_export_test.dart')) continue;
          if (entity.readAsStringSync().contains('zd_query_parameters')) {
            offenders.add(entity.path);
          }
        }
      }
      expect(offenders, isEmpty);
    });
  });
}
