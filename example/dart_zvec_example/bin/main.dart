import 'dart:io';
import 'dart:typed_data';

import 'package:dart_zvec/dart_zvec.dart';

void main() {
  final directory = Directory.systemTemp.createTempSync('dart-zvec-example-');
  try {
    final collection = ZvecCollection.create(
      '${directory.path}/demo',
      dimensions: 3,
    );
    try {
      collection.insert([
        ZvecRecord('port', Float32List.fromList([1, 0, 0])),
        ZvecRecord('sonography', Float32List.fromList([0, 1, 0])),
      ]);
      collection.optimize();
      for (final hit in collection.search(
        Float32List.fromList([0.9, 0.1, 0]),
      )) {
        stdout.writeln('${hit.id}: ${hit.score}');
      }
    } finally {
      collection.close();
    }
  } finally {
    Zvec.shutdown();
    directory.deleteSync(recursive: true);
  }
}
