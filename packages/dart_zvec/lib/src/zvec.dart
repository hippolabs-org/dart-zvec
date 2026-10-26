import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart' as native;

part 'models.dart';
part 'document_codec.dart';
part 'collection_operations.dart';

/// A failure returned by the Zvec C API.
final class ZvecException implements Exception {
  const ZvecException(this.operation, this.code, this.message);

  final String operation;
  final int code;
  final String message;

  @override
  String toString() => 'ZvecException($operation, $code): $message';
}

/// Process-level Zvec initialization.
abstract final class Zvec {
  static String get version =>
      native.zvec_get_version().cast<Utf8>().toDartString();

  static void initialize() {
    if (native.zvec_is_initialized()) return;
    final result = native.zvec_initialize(ffi.nullptr);
    // Another isolate may initialize the shared library after the first check.
    // All callers use the same default configuration; the initialized state is
    // authoritative. Shutdown still requires coordination by the application.
    if (result != native.zvec_error_code_t.ZVEC_OK &&
        !native.zvec_is_initialized()) {
      _check('initialize', result);
    }
  }

  /// Call after closing every collection.
  static void shutdown() {
    if (!native.zvec_is_initialized()) return;
    _check('shutdown', native.zvec_shutdown());
  }
}

/// A persistent, single-vector-field collection using configurable HNSW search.
///
/// The collection directory is owned by Zvec. Call [close] when finished.
final class ZvecCollection {
  ZvecCollection._(this._handle, this.dimensions, this.fieldName, this.metric);

  ffi.Pointer<native.zvec_collection_t>? _handle;
  final int dimensions;
  final String fieldName;
  final ZvecMetric metric;
  Map<String, ZvecScalarType> _fields = {};

  Map<String, ZvecScalarType> get scalarFields => Map.unmodifiable(_fields);

  static ZvecCollection create(
    String path, {
    required int dimensions,
    String name = 'vectors',
    String fieldName = 'embedding',
    ZvecMetric metric = ZvecMetric.cosine,
    Map<String, ZvecScalarType> scalarFields = const {},
    int m = 16,
    int efConstruction = 200,
  }) {
    if (dimensions < 1 ||
        name.isEmpty ||
        fieldName.isEmpty ||
        m < 2 ||
        efConstruction < 1) {
      throw ArgumentError('Invalid Zvec collection or HNSW parameters.');
    }
    _validateText(name);
    _validateText(path);
    _validateText(fieldName);
    Zvec.initialize();
    final pathPtr = path.toNativeUtf8();
    final namePtr = name.toNativeUtf8();
    final fieldNamePtr = fieldName.toNativeUtf8();
    final out = calloc<ffi.Pointer<native.zvec_collection_t>>();
    final schema = native.zvec_collection_schema_create(namePtr.cast());
    if (schema == ffi.nullptr) {
      calloc.free(pathPtr);
      calloc.free(namePtr);
      calloc.free(fieldNamePtr);
      calloc.free(out);
      throw StateError('Zvec could not allocate a collection schema.');
    }
    try {
      final field = native.zvec_field_schema_create(
        fieldNamePtr.cast(),
        23,
        false,
        dimensions,
      );
      if (field == ffi.nullptr) {
        throw StateError('Zvec could not allocate a vector field.');
      }
      try {
        final index = native.zvec_index_params_create(1); // HNSW
        if (index == ffi.nullptr) {
          throw StateError('Zvec could not allocate HNSW parameters.');
        }
        try {
          _check(
            'set vector metric',
            native.zvec_index_params_set_metric_type(
              index,
              metric._nativeValue,
            ),
          );
          _check(
            'set HNSW parameters',
            native.zvec_index_params_set_hnsw_params(index, m, efConstruction),
          );
          _check(
            'attach HNSW index',
            native.zvec_field_schema_set_index_params(field, index),
          );
        } finally {
          native.zvec_index_params_destroy(index);
        }
        _check(
          'add vector field',
          native.zvec_collection_schema_add_field(schema, field),
        );
      } finally {
        native.zvec_field_schema_destroy(field);
      }
      for (final entry in scalarFields.entries) {
        if (entry.key == fieldName) {
          throw ArgumentError('Scalar/vector field name collision.');
        }
        final scalar = _scalarSchema(entry.key, entry.value);
        try {
          _check(
            'add scalar field',
            native.zvec_collection_schema_add_field(schema, scalar),
          );
        } finally {
          native.zvec_field_schema_destroy(scalar);
        }
      }
      _check(
        'create collection',
        native.zvec_collection_create_and_open(
          pathPtr.cast(),
          schema,
          ffi.nullptr,
          out,
        ),
      );
      return ZvecCollection._(out.value, dimensions, fieldName, metric)
        .._fields = Map.of(scalarFields);
    } finally {
      native.zvec_collection_schema_destroy(schema);
      calloc.free(pathPtr);
      calloc.free(namePtr);
      calloc.free(fieldNamePtr);
      calloc.free(out);
    }
  }

  /// Open a collection previously created with the same vector field and dimension.
  static ZvecCollection open(
    String path, {
    required int dimensions,
    String fieldName = 'embedding',
    bool readOnly = false,
    ZvecMetric metric = ZvecMetric.cosine,
  }) {
    if (dimensions < 1 || fieldName.isEmpty) {
      throw ArgumentError('Invalid vector field or dimension.');
    }
    _validateText(path);
    _validateText(fieldName);
    Zvec.initialize();
    final pathPtr = path.toNativeUtf8();
    final out = calloc<ffi.Pointer<native.zvec_collection_t>>();
    final options = readOnly
        ? native.zvec_collection_options_create()
        : ffi.nullptr;
    try {
      if (readOnly) {
        if (options == ffi.nullptr) {
          throw StateError('Zvec could not allocate collection options.');
        }
        _check(
          'set read-only mode',
          native.zvec_collection_options_set_read_only(options, true),
        );
      }
      _check(
        'open collection',
        native.zvec_collection_open(pathPtr.cast(), options, out),
      );
      final collection = ZvecCollection._(
        out.value,
        dimensions,
        fieldName,
        metric,
      );
      try {
        collection._loadSchema();
        return collection;
      } catch (_) {
        collection.close();
        rethrow;
      }
    } finally {
      if (options != ffi.nullptr) {
        native.zvec_collection_options_destroy(options);
      }
      calloc.free(pathPtr);
      calloc.free(out);
    }
  }

  void insert(Iterable<ZvecRecord> records) => _write(records, upsert: false);

  void upsert(Iterable<ZvecRecord> records) => _write(records, upsert: true);

  void _write(Iterable<ZvecRecord> records, {required bool upsert}) {
    final input = records.toList(growable: false);
    _requireOpen();
    if (input.isEmpty) return;
    for (final record in input) {
      _validateVector(record.embedding);
      _validateText(record.id);
      if (record.id.isEmpty) {
        throw ArgumentError('Record IDs must not be empty.');
      }
      for (final entry in record.fields.entries) {
        if (_fields[entry.key] != entry.value.type) {
          throw ArgumentError(
            'Unknown field or incompatible scalar type: ${entry.key}',
          );
        }
      }
    }
    final documents = calloc<ffi.Pointer<native.zvec_doc_t>>(input.length);
    final success = calloc<ffi.Size>();
    final errors = calloc<ffi.Size>();
    var created = 0;
    try {
      for (final record in input) {
        _validateVector(record.embedding);
        if (record.id.isEmpty) {
          throw ArgumentError.value(record.id, 'id', 'Must not be empty.');
        }
        final document = native.zvec_doc_create();
        if (document == ffi.nullptr) {
          throw StateError('Zvec could not allocate a document.');
        }
        documents[created++] = document;
        final id = record.id.toNativeUtf8();
        final name = fieldName.toNativeUtf8();
        final values = calloc<ffi.Float>(dimensions);
        try {
          native.zvec_doc_set_pk(document, id.cast());
          for (var i = 0; i < dimensions; i++) {
            values[i] = record.embedding[i];
          }
          _check(
            'set embedding',
            native.zvec_doc_add_field_by_value(
              document,
              name.cast(),
              23, // VECTOR_FP32
              values.cast(),
              dimensions * ffi.sizeOf<ffi.Float>(),
            ),
          );
          for (final entry in record.fields.entries) {
            _addScalar(document, entry.key, entry.value);
          }
        } finally {
          calloc.free(id);
          calloc.free(name);
          calloc.free(values);
        }
      }
      _check(
        upsert ? 'upsert documents' : 'insert documents',
        (upsert
            ? native.zvec_collection_upsert
            : native.zvec_collection_insert)(
          _requireOpen(),
          documents,
          input.length,
          success,
          errors,
        ),
      );
      if (errors.value != 0 || success.value != input.length) {
        throw ZvecException(
          upsert ? 'upsert documents' : 'insert documents',
          -1,
          '${success.value} written, ${errors.value} failed.',
        );
      }
    } finally {
      for (var i = 0; i < created; i++) {
        native.zvec_doc_destroy(documents[i]);
      }
      calloc.free(documents);
      calloc.free(success);
      calloc.free(errors);
    }
  }

  /// Build or compact indexes after a batch of inserts.
  void optimize() => _check(
    'optimize collection',
    native.zvec_collection_optimize(_requireOpen()),
  );

  List<ZvecHit> search(
    Float32List embedding, {
    int limit = 10,
    String? filter,
    bool exact = false,
    int efSearch = 100,
  }) {
    _validateVector(embedding);
    if (limit < 1) throw RangeError.range(limit, 1, null, 'limit');
    if (efSearch < 1) throw ArgumentError('efSearch must be positive.');
    if (filter != null) _validateText(filter);
    final query = native.zvec_vector_query_create();
    if (query == ffi.nullptr) {
      throw StateError('Zvec could not allocate a query.');
    }
    final name = fieldName.toNativeUtf8();
    final values = calloc<ffi.Float>(dimensions);
    final results = calloc<ffi.Pointer<ffi.Pointer<native.zvec_doc_t>>>();
    final count = calloc<ffi.Size>();
    final params = native.zvec_query_params_hnsw_create(
      efSearch,
      0,
      exact,
      false,
    );
    var ownsParams = true;
    final filterPtr = filter?.toNativeUtf8();
    try {
      if (params == ffi.nullptr) {
        throw StateError('Cannot allocate HNSW query parameters.');
      }
      _check(
        'set query parameters',
        native.zvec_vector_query_set_hnsw_params(query, params),
      );
      ownsParams = false; // Successful setter transfers ownership to the query.
      if (filterPtr != null) {
        _check(
          'set query filter',
          native.zvec_vector_query_set_filter(query, filterPtr.cast()),
        );
      }
      for (var i = 0; i < dimensions; i++) {
        values[i] = embedding[i];
      }
      _check(
        'set query field',
        native.zvec_vector_query_set_field_name(query, name.cast()),
      );
      _check(
        'set query vector',
        native.zvec_vector_query_set_query_vector(
          query,
          values.cast(),
          dimensions * ffi.sizeOf<ffi.Float>(),
        ),
      );
      _check(
        'set query limit',
        native.zvec_vector_query_set_topk(query, limit),
      );
      _check(
        'query collection',
        native.zvec_collection_query(_requireOpen(), query, results, count),
      );
      return [
        for (var i = 0; i < count.value; i++)
          ZvecHit(
            native
                .zvec_doc_get_pk_pointer(results.value[i])
                .cast<Utf8>()
                .toDartString(),
            native.zvec_doc_get_score(results.value[i]),
            fields: _readFields(results.value[i]),
          ),
      ];
    } finally {
      if (results.value != ffi.nullptr) {
        native.zvec_docs_free(results.value, count.value);
      }
      native.zvec_vector_query_destroy(query);
      if (ownsParams && params != ffi.nullptr) {
        native.zvec_query_params_hnsw_destroy(params);
      }
      if (filterPtr != null) calloc.free(filterPtr);
      calloc.free(name);
      calloc.free(values);
      calloc.free(results);
      calloc.free(count);
    }
  }

  void close() {
    final handle = _handle;
    if (handle == null) return;
    _handle = null;
    _check('close collection', native.zvec_collection_close(handle));
  }

  ffi.Pointer<native.zvec_collection_t> _requireOpen() {
    final handle = _handle;
    if (handle == null) throw StateError('Zvec collection is closed.');
    return handle;
  }

  void _validateVector(Float32List value) {
    if (value.length != dimensions) {
      throw ArgumentError.value(
        value.length,
        'embedding.length',
        'Expected $dimensions dimensions.',
      );
    }
    if (value.any((component) => !component.isFinite)) {
      throw ArgumentError.value(
        value,
        'embedding',
        'Components must be finite.',
      );
    }
  }
}

void _check(String operation, native.zvec_error_code_t result) {
  if (result == native.zvec_error_code_t.ZVEC_OK) return;
  final message = calloc<ffi.Pointer<ffi.Char>>();
  try {
    native.zvec_get_last_error(message);
    final text = message.value == ffi.nullptr
        ? result.name
        : message.value.cast<Utf8>().toDartString();
    throw ZvecException(operation, result.value, text);
  } finally {
    if (message.value != ffi.nullptr) native.zvec_free(message.value.cast());
    calloc.free(message);
  }
}
