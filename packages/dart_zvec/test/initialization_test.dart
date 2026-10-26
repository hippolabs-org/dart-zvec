import 'dart:isolate';

import 'package:dart_zvec/dart_zvec.dart';
import 'package:test/test.dart';

void main() {
  test(
    'default initialization is idempotent across concurrent isolates',
    () async {
      Zvec.shutdown();
      final ready = ReceivePort();
      final gates = <SendPort>[];
      final outcomes = <Object?>[];
      final completed = ready.listen((message) {
        if (message is SendPort) {
          gates.add(message);
          if (gates.length == 12) {
            for (final gate in gates) {
              gate.send(null);
            }
          }
        } else {
          outcomes.add(message);
          if (outcomes.length == 12) ready.close();
        }
      });
      final done = completed.asFuture<void>();
      for (var i = 0; i < 12; i++) {
        await Isolate.spawn(_initialize, ready.sendPort);
      }
      await done;
      expect(outcomes, everyElement('ok'));
      Zvec.shutdown();
    },
  );
}

Future<void> _initialize(SendPort parent) async {
  final gate = ReceivePort();
  parent.send(gate.sendPort);
  await gate.first;
  try {
    Zvec.initialize();
    parent.send('ok');
  } catch (error) {
    parent.send(error.toString());
  }
}
