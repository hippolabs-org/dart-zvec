import 'dart:ffi';

@Native<Uint32 Function(Pointer<Void>)>(
  symbol: 'zvec_collection_close',
  assetId: 'package:dart_zvec/src/bindings.dart',
)
external int _collectionClose(Pointer<Void> handle);

@Native<
  Int64 Function(
    Pointer<Void>,
    Pointer<NativeFunction<Uint32 Function(Pointer<Void>)>>,
  )
>(symbol: 'dart_zvec_track')
external int _track(
  Pointer<Void> handle,
  Pointer<NativeFunction<Uint32 Function(Pointer<Void>)>> close,
);

@Native<Int32 Function(Int64)>(symbol: 'dart_zvec_close_tracked')
external int _close(int id);

@Native<Int32 Function(Int64)>(symbol: 'dart_zvec_is_tracked')
external int _isTracked(int id);

bool isTrackedCollection(int id) => _isTracked(id) != 0;

@Native<Int32 Function()>(symbol: 'dart_zvec_close_all_tracked')
external int _closeAll();

int trackCollection(Pointer<Void> handle) {
  final id = _track(handle, Native.addressOf(_collectionClose));
  if (id == 0) throw StateError('Could not register the Zvec collection.');
  return id;
}

void closeTrackedCollection(int id) {
  if (_close(id) != 0) throw StateError('Could not close a Zvec collection.');
}

void closeAllTrackedCollections() {
  if (_closeAll() != 0) {
    throw StateError('Could not close all Zvec collections safely.');
  }
}
