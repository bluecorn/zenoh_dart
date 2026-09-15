import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

/// The sealed-discriminated-result convention's first consumer.
///
/// These cells pin the SHAPE, not any channel behaviour: the type is pure
/// Dart with no native resource, so nothing here opens a session. The
/// behavioural legs live in `pull_subscriber_test.dart`,
/// `pull_channel_test.dart` and `pull_recv_test.dart`.
///
/// The spelling under test is copied verbatim from
/// `development/reference/sealed-result-convention-20260818.md` §S2b, which
/// pins it once for both of its instantiations (`RecvResult<Sample>` here,
/// `RecvResult<Reply>` in seed #6) so neither seed owns the shape by arrival
/// order.
void main() {
  Sample makeSample(String payload) => Sample(
    keyExpr: 'zenoh/dart/recvresult',
    payload: payload,
    payloadBytes: Uint8List.fromList(payload.codeUnits),
    kind: SampleKind.put,
  );

  group('RecvResult shape', () {
    test('RecvData carries canon Z_OK payload and nothing else', () {
      final s = makeSample('hello');
      final result = RecvData<Sample>(s);

      // Canon's Z_OK arm carries exactly one thing: the value. `identical`
      // rather than `equals`, because the variant must hand back the very
      // object it was given -- a copy would be a transform.
      expect(identical(result.value, s), isTrue);
    });

    test('an exhaustive switch over the sealed base needs no default arm', () {
      // The point of the sealed base: three arms are provably total, so a
      // consumer that forgets a future variant would not compile rather than
      // silently absorbing it in a `default`.
      String describe(RecvResult<Sample> r) => switch (r) {
        RecvData<Sample>() => 'data',
        RecvEmpty<Sample>() => 'empty',
        RecvDisconnected<Sample>() => 'disconnected',
      };

      expect(describe(RecvData<Sample>(makeSample('x'))), 'data');
      expect(describe(const RecvEmpty<Sample>()), 'empty');
      expect(describe(const RecvDisconnected<Sample>()), 'disconnected');
    });

    test('the payload-free variants are const and mutually distinct', () {
      const empty = RecvEmpty<Sample>();
      const disconnected = RecvDisconnected<Sample>();

      // Canon draws these two apart deliberately -- NODATA means "keep
      // polling", DISCONNECTED means "stop" -- so the rendering must never let
      // one stand in for the other.
      expect(empty, isNot(isA<RecvDisconnected<Sample>>()));
      expect(disconnected, isNot(isA<RecvEmpty<Sample>>()));
      expect(empty, isNot(isA<RecvData<Sample>>()));
      expect(disconnected, isNot(isA<RecvData<Sample>>()));

      // Const-constructible, so the payload-free arms allocate nothing per
      // call. Identical const instances are canonicalized by the compiler.
      expect(identical(empty, const RecvEmpty<Sample>()), isTrue);
      expect(identical(disconnected, const RecvDisconnected<Sample>()), isTrue);
    });
  });

  group('RecvResult genericity', () {
    test('the family is generic, not sample-specific', () {
      // Seed #6 instantiates `RecvResult<Reply>` with NO change to this type.
      // Driving it here with a third, unrelated argument is what proves the
      // genericity is real rather than a `Sample` alias wearing type
      // parameters.
      const RecvResult<int> data = RecvData<int>(7);

      final described = switch (data) {
        RecvData<int>(:final value) => 'data:$value',
        RecvEmpty<int>() => 'empty',
        RecvDisconnected<int>() => 'disconnected',
      };

      expect(described, 'data:7');
      expect((data as RecvData<int>).value, 7);
    });
  });
}
