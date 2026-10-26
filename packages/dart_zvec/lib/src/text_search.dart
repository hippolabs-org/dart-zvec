part of 'zvec.dart';

extension ZvecCollectionTextSearch on ZvecCollection {
  /// Ranked BM25 results (higher scores first), optionally restricted by a raw
  /// native scalar filter. Authorize/encode filter values in the calling layer.
  /// Vector and text queries are independent; this method performs no fusion.
  List<ZvecHit> searchText(
    String field,
    ZvecTextQuery input, {
    int limit = 10,
    String? filter,
  }) {
    _requireOpen();
    if (!_textIndexes.containsKey(field)) {
      throw ArgumentError('Not a full-text indexed field: $field');
    }
    _positive(limit, 'limit');
    _validateText(input.text);
    if (input.text.trim().isEmpty) throw ArgumentError('Empty text query.');
    if (filter != null) _validateText(filter);
    final query = native.zvec_vector_query_create();
    final fts = native.zvec_fts_create();
    final operator = input.operator._name.toNativeUtf8();
    final params = native.zvec_query_params_fts_create(operator.cast());
    var ownsParams = true;
    final name = field.toNativeUtf8();
    final text = input.text.toNativeUtf8();
    final filterPtr = filter?.toNativeUtf8();
    final results = calloc<ffi.Pointer<ffi.Pointer<native.zvec_doc_t>>>();
    final count = calloc<ffi.Size>();
    try {
      if (query == ffi.nullptr || fts == ffi.nullptr || params == ffi.nullptr) {
        throw StateError('Cannot allocate full-text query.');
      }
      _check('set text query input', switch (input) {
        ZvecTextMatch() => native.zvec_fts_set_match_string(fts, text.cast()),
        ZvecTextExpression() => native.zvec_fts_set_query_string(
          fts,
          text.cast(),
        ),
      });
      _check(
        'set text query field',
        native.zvec_vector_query_set_field_name(query, name.cast()),
      );
      // Payload is copied; parameters transfer ownership only on success.
      _check(
        'set text query payload',
        native.zvec_vector_query_set_fts(query, fts),
      );
      _check(
        'set text query parameters',
        native.zvec_vector_query_set_fts_params(query, params),
      );
      ownsParams = false;
      _check(
        'set text query limit',
        native.zvec_vector_query_set_topk(query, limit),
      );
      if (filterPtr != null) {
        _check(
          'set text query filter',
          native.zvec_vector_query_set_filter(query, filterPtr.cast()),
        );
      }
      _check(
        'query text',
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
      if (query != ffi.nullptr) native.zvec_vector_query_destroy(query);
      if (fts != ffi.nullptr) native.zvec_fts_destroy(fts);
      if (ownsParams && params != ffi.nullptr) {
        native.zvec_query_params_fts_destroy(params);
      }
      calloc.free(operator);
      calloc.free(name);
      calloc.free(text);
      if (filterPtr != null) calloc.free(filterPtr);
      calloc.free(results);
      calloc.free(count);
    }
  }
}

ffi.Pointer<native.zvec_field_schema_t> _textSchema(
  String name,
  ZvecTextIndex config,
) {
  final namePtr = name.toNativeUtf8();
  final field = native.zvec_field_schema_create(
    namePtr.cast(),
    2,
    config.nullable,
    0,
  );
  final index = native.zvec_index_params_create(11); // FTS
  final tokenizer = config.tokenizer._name.toNativeUtf8();
  final parameters = jsonEncode(config._parameters).toNativeUtf8();
  // An empty allocated array explicitly disables native default token filters.
  final filters = native.zvec_string_array_create(config.filters.length);
  try {
    if (field == ffi.nullptr ||
        index == ffi.nullptr ||
        filters == ffi.nullptr) {
      throw StateError('Cannot allocate full-text schema.');
    }
    for (var i = 0; i < config.filters.length; i++) {
      final value = config.filters[i]._name.toNativeUtf8();
      try {
        native.zvec_string_array_add(filters, i, value.cast());
      } finally {
        calloc.free(value);
      }
    }
    _check(
      'configure text index',
      native.zvec_index_params_set_fts_params(
        index,
        tokenizer.cast(),
        filters,
        parameters.cast(),
      ),
    );
    _check(
      'attach text index',
      native.zvec_field_schema_set_index_params(field, index),
    );
    return field;
  } catch (_) {
    if (field != ffi.nullptr) native.zvec_field_schema_destroy(field);
    rethrow;
  } finally {
    if (index != ffi.nullptr) native.zvec_index_params_destroy(index);
    if (filters != ffi.nullptr) native.zvec_string_array_destroy(filters);
    calloc.free(namePtr);
    calloc.free(tokenizer);
    calloc.free(parameters);
  }
}

ZvecTextIndex _readTextIndex(
  ffi.Pointer<native.zvec_index_params_t> index, {
  required bool nullable,
}) {
  final tokenizer = calloc<ffi.Pointer<ffi.Char>>();
  final parameters = calloc<ffi.Pointer<ffi.Char>>();
  final filters = calloc<ffi.Pointer<native.zvec_string_array_t>>();
  try {
    _check(
      'read text index',
      native.zvec_index_params_get_fts_params(
        index,
        tokenizer,
        filters,
        parameters,
      ),
    );
    final name = tokenizer.value.cast<Utf8>().toDartString();
    final json = parameters.value == ffi.nullptr
        ? ''
        : parameters.value.cast<Utf8>().toDartString();
    final extra = json.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(json) as Map<String, dynamic>;
    final ZvecTokenizer config = switch (name) {
      'standard' => ZvecStandardTokenizer(
        maxTokenLength: extra.remove('max_token_length') as int? ?? 255,
      ),
      'whitespace' => const ZvecWhitespaceTokenizer(),
      'ngram' => ZvecNgramTokenizer(
        min: extra.remove('ngram_min') as int? ?? 2,
        max: extra.remove('ngram_max') as int? ?? 2,
        characters: (extra.remove('token_chars') as List<dynamic>? ?? []).map(
          (v) => ZvecTokenCharacter.values.byName(v as String),
        ),
      ),
      'jieba' => ZvecJiebaTokenizer(
        dictionaryDirectory: extra.remove('jieba_dict_dir') as String?,
        userDictionaryPath: extra.remove('user_dict_path') as String?,
        mode: ZvecJiebaMode.values.byName(
          extra.remove('cut_mode') as String? ?? 'search',
        ),
      ),
      _ => throw UnsupportedError('Unsupported persisted tokenizer: $name'),
    };
    final language = extra.remove('stemmer_lang') as String? ?? 'english';
    if (extra.isNotEmpty) {
      throw UnsupportedError(
        'Unsupported persisted FTS settings: ${extra.keys}',
      );
    }
    return ZvecTextIndex(
      tokenizer: config,
      nullable: nullable,
      stemmerLanguage: language,
      filters: [
        if (filters.value != ffi.nullptr)
          for (var i = 0; i < filters.value.ref.count; i++)
            ZvecTokenFilter.values.firstWhere(
              (f) =>
                  f._name ==
                  filters.value.ref.strings[i].data.cast<Utf8>().toDartString(),
            ),
      ],
    );
  } finally {
    // Tokenizer/JSON strings are borrowed from index; only the filter array is owned.
    if (filters.value != ffi.nullptr) {
      native.zvec_string_array_destroy(filters.value);
    }
    calloc.free(tokenizer);
    calloc.free(parameters);
    calloc.free(filters);
  }
}
