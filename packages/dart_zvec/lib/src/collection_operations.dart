part of 'zvec.dart';

/// Additional storage operations using the same owned native handle.
extension ZvecCollectionStorage on ZvecCollection {
  void flush() =>
      _check('flush collection', native.zvec_collection_flush(_requireOpen()));

  List<ZvecRecord> fetch(Iterable<String> ids) {
    final input = ids.toSet().toList();
    _requireOpen();
    if (input.isEmpty) return [];
    return _withIds(input, (pks) {
      final docs = calloc<ffi.Pointer<ffi.Pointer<native.zvec_doc_t>>>();
      final count = calloc<ffi.Size>();
      try {
        _check(
          'fetch documents',
          native.zvec_collection_fetch(
            _requireOpen(),
            pks,
            input.length,
            ffi.nullptr,
            0,
            true,
            docs,
            count,
          ),
        );
        return [
          for (var i = 0; i < count.value; i++) _readRecord(docs.value[i]),
        ];
      } finally {
        if (docs.value != ffi.nullptr) {
          native.zvec_docs_free(docs.value, count.value);
        }
        calloc.free(docs);
        calloc.free(count);
      }
    });
  }

  void delete(Iterable<String> ids) {
    final input = ids.toSet().toList();
    _requireOpen();
    if (input.isEmpty) return;
    _withIds(input, (pks) {
      final success = calloc<ffi.Size>();
      final errors = calloc<ffi.Size>();
      try {
        _check(
          'delete documents',
          native.zvec_collection_delete(
            _requireOpen(),
            pks,
            input.length,
            success,
            errors,
          ),
        );
        if (errors.value != 0) {
          throw ZvecException(
            'delete documents',
            -1,
            '${errors.value} failed.',
          );
        }
      } finally {
        calloc.free(success);
        calloc.free(errors);
      }
    });
  }

  void deleteWhere(String filter) {
    _validateText(filter);
    if (filter.trim().isEmpty) {
      throw ArgumentError('A delete filter is required.');
    }
    final expression = filter.toNativeUtf8();
    try {
      _check(
        'delete by filter',
        native.zvec_collection_delete_by_filter(
          _requireOpen(),
          expression.cast(),
        ),
      );
    } finally {
      calloc.free(expression);
    }
  }
}

extension on ZvecCollection {
  void _loadSchema() {
    final schema = calloc<ffi.Pointer<native.zvec_collection_schema_t>>();
    final fields =
        calloc<ffi.Pointer<ffi.Pointer<native.zvec_field_schema_t>>>();
    final count = calloc<ffi.Size>();
    final name = fieldName.toNativeUtf8();
    try {
      _check(
        'read collection schema',
        native.zvec_collection_get_schema(_requireOpen(), schema),
      );
      final vector = native.zvec_collection_schema_get_field(
        schema.value,
        name.cast(),
      );
      if (vector == ffi.nullptr ||
          native.zvec_field_schema_get_dimension(vector) != dimensions ||
          native.zvec_field_schema_get_data_type(vector) != 23) {
        throw ArgumentError('Persisted vector field/dimensions do not match.');
      }
      final index = native.zvec_field_schema_get_index_params(vector);
      if (index == ffi.nullptr ||
          native.zvec_index_params_get_metric_type(index) !=
              metric._nativeValue) {
        throw ArgumentError('Persisted vector metric does not match.');
      }
      _check(
        'read scalar schema',
        native.zvec_collection_schema_get_forward_fields(
          schema.value,
          fields,
          count,
        ),
      );
      _fields = {
        for (var i = 0; i < count.value; i++)
          native
              .zvec_field_schema_get_name(fields.value[i])
              .cast<Utf8>()
              .toDartString(): ZvecScalarType.values.firstWhere(
            (type) =>
                type._nativeValue ==
                native.zvec_field_schema_get_data_type(fields.value[i]),
          ),
      };
    } finally {
      if (fields.value != ffi.nullptr) native.zvec_free(fields.value.cast());
      if (schema.value != ffi.nullptr) {
        native.zvec_collection_schema_destroy(schema.value);
      }
      calloc.free(schema);
      calloc.free(fields);
      calloc.free(count);
      calloc.free(name);
    }
  }
}

T _withIds<T>(
  List<String> ids,
  T Function(ffi.Pointer<ffi.Pointer<ffi.Char>>) action,
) {
  for (final id in ids) {
    _validateText(id);
    if (id.isEmpty) throw ArgumentError('Empty ID.');
  }
  final pointers = calloc<ffi.Pointer<ffi.Char>>(ids.length);
  var allocated = 0;
  try {
    for (final id in ids) {
      pointers[allocated++] = id.toNativeUtf8().cast();
    }
    return action(pointers);
  } finally {
    for (var i = 0; i < allocated; i++) {
      calloc.free(pointers[i]);
    }
    calloc.free(pointers);
  }
}

ffi.Pointer<native.zvec_field_schema_t> _scalarSchema(
  String name,
  ZvecScalarType type,
) {
  if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(name)) {
    throw ArgumentError('Invalid scalar field name.');
  }
  final namePtr = name.toNativeUtf8();
  final field = native.zvec_field_schema_create(
    namePtr.cast(),
    type._nativeValue,
    true,
    0,
  );
  final index = native.zvec_index_params_create(10);
  try {
    if (field == ffi.nullptr || index == ffi.nullptr) {
      throw StateError('Cannot allocate scalar schema.');
    }
    _check(
      'configure scalar index',
      native.zvec_index_params_set_invert_params(
        index,
        type == ZvecScalarType.number,
        false,
      ),
    );
    _check(
      'attach scalar index',
      native.zvec_field_schema_set_index_params(field, index),
    );
    return field;
  } catch (_) {
    if (field != ffi.nullptr) native.zvec_field_schema_destroy(field);
    rethrow;
  } finally {
    if (index != ffi.nullptr) native.zvec_index_params_destroy(index);
    calloc.free(namePtr);
  }
}
