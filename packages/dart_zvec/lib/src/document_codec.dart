part of 'zvec.dart';

void _addScalar(
  ffi.Pointer<native.zvec_doc_t> document,
  String field,
  ZvecValue value,
) {
  final name = field.toNativeUtf8();
  ffi.Pointer<ffi.Void> data = ffi.nullptr;
  var size = 0;
  try {
    switch (value) {
      case ZvecString(:final value):
        data = value.toNativeUtf8().cast();
        size = utf8.encode(value).length;
      case ZvecNumber(:final value):
        final buffer = calloc<ffi.Double>()..value = value;
        data = buffer.cast();
        size = ffi.sizeOf<ffi.Double>();
      case ZvecBool(:final value):
        final buffer = calloc<ffi.Bool>()..value = value;
        data = buffer.cast();
        size = ffi.sizeOf<ffi.Bool>();
    }
    _check(
      'add scalar field',
      native.zvec_doc_add_field_by_value(
        document,
        name.cast(),
        value.type._nativeValue,
        data,
        size,
      ),
    );
  } finally {
    calloc.free(name);
    if (data != ffi.nullptr) calloc.free(data);
  }
}

T _readField<T>(
  ffi.Pointer<native.zvec_doc_t> document,
  String field,
  int type,
  T Function(ffi.Pointer<ffi.Void>, int) decode,
) {
  final name = field.toNativeUtf8();
  final value = calloc<ffi.Pointer<ffi.Void>>();
  final size = calloc<ffi.Size>();
  try {
    _check(
      'read field',
      native.zvec_doc_get_field_value_pointer(
        document,
        name.cast(),
        type,
        value,
        size,
      ),
    );
    if (value.value == ffi.nullptr && size.value != 0) {
      throw StateError('Null field data.');
    }
    return decode(value.value, size.value);
  } finally {
    calloc.free(name);
    calloc.free(value);
    calloc.free(size);
  }
}

extension on ZvecCollection {
  Map<String, ZvecValue> _readFields(ffi.Pointer<native.zvec_doc_t> document) {
    final fields = <String, ZvecValue>{};
    for (final entry in _fields.entries) {
      final name = entry.key.toNativeUtf8();
      final bool present;
      try {
        present = native.zvec_doc_has_field_value(document, name.cast());
      } finally {
        calloc.free(name);
      }
      if (!present) continue;
      fields[entry.key] = _readField(
        document,
        entry.key,
        entry.value._nativeValue,
        (data, size) => switch (entry.value) {
          ZvecScalarType.string => ZvecString(
            size == 0 ? '' : data.cast<Utf8>().toDartString(),
          ),
          ZvecScalarType.number => ZvecNumber(data.cast<ffi.Double>().value),
          ZvecScalarType.boolean => ZvecBool(data.cast<ffi.Bool>().value),
        },
      );
    }
    return Map.unmodifiable(fields);
  }

  ZvecRecord _readRecord(ffi.Pointer<native.zvec_doc_t> document) {
    final vector = _readField(document, fieldName, 23, (data, size) {
      if (size != dimensions * ffi.sizeOf<ffi.Float>()) {
        throw StateError('Stored vector size mismatch.');
      }
      return Float32List.fromList(
        data.cast<ffi.Float>().asTypedList(dimensions),
      );
    });
    return ZvecRecord(
      native.zvec_doc_get_pk_pointer(document).cast<Utf8>().toDartString(),
      vector,
      fields: _readFields(document),
    );
  }
}
