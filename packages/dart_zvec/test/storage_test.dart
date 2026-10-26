import 'dart:io';
import 'dart:typed_data';

import 'package:dart_zvec/dart_zvec.dart';
import 'package:test/test.dart';

void main() {
  for (final metric in ZvecMetric.values) {
    test('${metric.name}: scalar fields, upsert, fetch, filter and reopen', () {
      final temp = Directory.systemTemp.createTempSync('zvec-storage-');
      final path = '${temp.path}/collection';
      var collection = ZvecCollection.create(
        path,
        dimensions: 3,
        metric: metric,
        scalarFields: {
          'tenant': ZvecScalarType.string,
          'age': ZvecScalarType.number,
          'active': ZvecScalarType.boolean,
        },
      );
      try {
        collection.upsert([
          ZvecRecord(
            'one',
            Float32List.fromList([1, 0, 0]),
            fields: {
              'tenant': ZvecString('a'),
              'age': ZvecNumber(1.5),
              'active': const ZvecBool(true),
            },
          ),
          ZvecRecord(
            'two',
            Float32List.fromList([0.6, 0.8, 0]),
            fields: {'tenant': ZvecString('b')},
          ),
          ZvecRecord('three', Float32List.fromList([-1, 0, 0])),
        ]);
        collection.flush();
        final records = collection.fetch(['one', 'missing']);
        expect(records, hasLength(1));
        expect(records.single.embedding, [1, 0, 0]);
        expect((records.single.fields['tenant']! as ZvecString).value, 'a');
        expect((records.single.fields['age']! as ZvecNumber).value, 1.5);
        expect((records.single.fields['active']! as ZvecBool).value, true);
        // Query-owned HNSW parameters must be freed once, even on failure.
        expect(
          () => collection.search(
            Float32List.fromList([1, 0, 0]),
            filter: 'unknown_field = 1',
          ),
          throwsA(isA<ZvecException>()),
        );
        expect(
          () => collection.upsert([
            ZvecRecord('rejected', Float32List.fromList([1, 0, 0])),
            ZvecRecord('invalid', Float32List.fromList([1, 0])),
          ]),
          throwsArgumentError,
        );
        expect(collection.fetch(['rejected']), isEmpty);
        collection.optimize();
        final hits = collection.search(
          Float32List.fromList([1, 0, 0]),
          exact: true,
        );
        final expected = switch (metric) {
          ZvecMetric.euclidean => [0.0, 0.8, 4.0],
          ZvecMetric.innerProduct => [1.0, 0.6, -1.0],
          ZvecMetric.cosine => [0.0, 0.4, 2.0],
        };
        for (var i = 0; i < expected.length; i++) {
          expect(hits[i].score, closeTo(expected[i], 0.00001));
        }
        expect(hits.map((h) => h.id), ['one', 'two', 'three']);
        expect(
          collection
              .search(
                Float32List.fromList([1, 0, 0]),
                filter: "tenant = 'a'",
                exact: true,
              )
              .map((h) => h.id),
          ['one'],
        );
        collection.upsert([
          ZvecRecord(
            'one',
            Float32List.fromList([0, 1, 0]),
            fields: {'tenant': ZvecString('new')},
          ),
        ]);
        expect(collection.fetch(['one']).single.fields.keys, ['tenant']);
        collection.close();
        expect(
          () => ZvecCollection.open(path, dimensions: 4, metric: metric),
          throwsArgumentError,
        );
        // A rejected open must release its native writer handle.
        collection = ZvecCollection.open(path, dimensions: 3, metric: metric);
        expect(collection.scalarFields['age'], ZvecScalarType.number);
        expect(collection.fetch(['one']).single.embedding, [0, 1, 0]);
        collection.delete(['two']);
        collection.deleteWhere("tenant = 'new'");
        expect(collection.fetch(['one', 'two', 'three']).map((r) => r.id), [
          'three',
        ]);
      } finally {
        collection.close();
        temp.deleteSync(recursive: true);
      }
    });
  }
}
