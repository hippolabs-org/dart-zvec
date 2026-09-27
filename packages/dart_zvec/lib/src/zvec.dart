import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart' as native;

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
    _check('initialize', native.zvec_initialize(ffi.nullptr));
  }

  /// Call after closing every collection.
  static void shutdown() {
    if (!native.zvec_is_initialized()) return;
    _check('shutdown', native.zvec_shutdown());
  }
}

/// One named embedding and its catalog or document identifier.
final class ZvecRecord {
  const ZvecRecord(this.id, this.embedding);

  final String id;
  final Float32List embedding;
}

/// A vector search candidate. Scores are returned by Zvec unchanged.
final class ZvecHit {
  const ZvecHit(this.id, this.score);

  final String id;
  final double score;
}

/// A persistent, single-vector-field collection using cosine HNSW search.
///
/// The collection directory is owned by Zvec. Call [close] when finished.
final class ZvecCollection {
  ZvecCollection._(this._handle, this.dimensions, this.fieldName);

  ffi.Pointer<native.zvec_collection_t>? _handle;
  final int dimensions;
  final String fieldName;

  static ZvecCollection create(
    String path, {
    required int dimensions,
    String name = 'vectors',
    String fieldName = 'embedding',
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
            'set cosine metric',
            native.zvec_index_params_set_metric_type(index, 3),
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
      _check(
        'create collection',
        native.zvec_collection_create_and_open(
          pathPtr.cast(),
          schema,
          ffi.nullptr,
          out,
        ),
      );
      return ZvecCollection._(out.value, dimensions, fieldName);
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
  }) {
    if (dimensions < 1 || fieldName.isEmpty) {
      throw ArgumentError('Invalid vector field or dimension.');
    }
    Zvec.initialize();
    final pathPtr = path.toNativeUtf8();
    final out = calloc<ffi.Pointer<native.zvec_collection_t>>();
    try {
      _check(
        'open collection',
        native.zvec_collection_open(pathPtr.cast(), ffi.nullptr, out),
      );
      return ZvecCollection._(out.value, dimensions, fieldName);
    } finally {
      calloc.free(pathPtr);
      calloc.free(out);
    }
  }

  void insert(Iterable<ZvecRecord> records) {
    final input = records.toList(growable: false);
    if (input.isEmpty) return;
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
        } finally {
          calloc.free(id);
          calloc.free(name);
          calloc.free(values);
        }
      }
      _check(
        'insert documents',
        native.zvec_collection_insert(
          _requireOpen(),
          documents,
          input.length,
          success,
          errors,
        ),
      );
      if (errors.value != 0 || success.value != input.length) {
        throw ZvecException(
          'insert documents',
          -1,
          '${success.value} inserted, ${errors.value} failed.',
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

  List<ZvecHit> search(Float32List embedding, {int limit = 10}) {
    _validateVector(embedding);
    if (limit < 1) throw RangeError.range(limit, 1, null, 'limit');
    final query = native.zvec_vector_query_create();
    if (query == ffi.nullptr) {
      throw StateError('Zvec could not allocate a query.');
    }
    final name = fieldName.toNativeUtf8();
    final values = calloc<ffi.Float>(dimensions);
    final results = calloc<ffi.Pointer<ffi.Pointer<native.zvec_doc_t>>>();
    final count = calloc<ffi.Size>();
    try {
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
          ),
      ];
    } finally {
      if (results.value != ffi.nullptr) {
        native.zvec_docs_free(results.value, count.value);
      }
      native.zvec_vector_query_destroy(query);
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
