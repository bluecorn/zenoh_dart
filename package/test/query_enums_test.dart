import 'package:test/test.dart';
import 'package:zenoh_dart/zenoh.dart';

void main() {
  group('QueryTarget', () {
    test('has correct values', () {
      expect(QueryTarget.bestMatching.index, 0);
      expect(QueryTarget.all.index, 1);
      expect(QueryTarget.allComplete.index, 2);
      expect(QueryTarget.values.length, 3);
    });
  });

  group('ConsolidationMode', () {
    test('has correct values via value getter', () {
      expect(ConsolidationMode.auto.value, -1);
      expect(ConsolidationMode.none.value, 0);
      expect(ConsolidationMode.monotonic.value, 1);
      expect(ConsolidationMode.latest.value, 2);
    });
  });
}
