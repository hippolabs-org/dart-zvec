part of 'zvec.dart';

/// A typed tokenizer pipeline. Index and query analysis use the same settings.
sealed class ZvecTokenizer {
  const ZvecTokenizer();
  String get _name;
  Map<String, Object> get _parameters;
  void _validate();
}

final class ZvecStandardTokenizer extends ZvecTokenizer {
  const ZvecStandardTokenizer({this.maxTokenLength = 255});
  final int maxTokenLength;
  @override
  String get _name => 'standard';
  @override
  Map<String, Object> get _parameters => {'max_token_length': maxTokenLength};
  @override
  void _validate() => _positive(maxTokenLength, 'maxTokenLength');
}

final class ZvecWhitespaceTokenizer extends ZvecTokenizer {
  const ZvecWhitespaceTokenizer();
  @override
  String get _name => 'whitespace';
  @override
  Map<String, Object> get _parameters => {};
  @override
  void _validate() {}
}

enum ZvecTokenCharacter { letter, digit, whitespace, punctuation, symbol }

final class ZvecNgramTokenizer extends ZvecTokenizer {
  ZvecNgramTokenizer({
    this.min = 2,
    this.max = 2,
    Iterable<ZvecTokenCharacter> characters = const [],
  }) : characters = List.unmodifiable(characters);
  final int min;
  final int max;

  /// Empty means all valid UTF-8 characters.
  final List<ZvecTokenCharacter> characters;
  @override
  String get _name => 'ngram';
  @override
  Map<String, Object> get _parameters => {
    'ngram_min': min,
    'ngram_max': max,
    'token_chars': characters.map((c) => c.name).toList(),
  };
  @override
  void _validate() {
    _positive(min, 'min');
    if (max < min) throw ArgumentError('max must be at least min.');
  }
}

enum ZvecJiebaMode { search, mix, full, hmm }

/// Chinese segmentation. Dictionaries are supplied by the application, not
/// bundled with this package. Null paths use native environment/config defaults.
final class ZvecJiebaTokenizer extends ZvecTokenizer {
  const ZvecJiebaTokenizer({
    this.dictionaryDirectory,
    this.userDictionaryPath,
    this.mode = ZvecJiebaMode.search,
  });
  final String? dictionaryDirectory;
  final String? userDictionaryPath;
  final ZvecJiebaMode mode;
  @override
  String get _name => 'jieba';
  @override
  Map<String, Object> get _parameters => {
    'jieba_dict_dir': ?dictionaryDirectory,
    'user_dict_path': ?userDictionaryPath,
    'cut_mode': mode.name,
  };
  @override
  void _validate() {
    if (dictionaryDirectory != null) _validateText(dictionaryDirectory!);
    if (userDictionaryPath != null) _validateText(userDictionaryPath!);
  }
}

enum ZvecTokenFilter {
  lowercase('lowercase'),
  asciiFolding('ascii_folding'),
  stemmer('stemmer');

  const ZvecTokenFilter(this._name);
  final String _name;
}

/// Configuration of one nullable or required STRING field with a BM25 index.
final class ZvecTextIndex {
  ZvecTextIndex({
    this.tokenizer = const ZvecStandardTokenizer(),
    Iterable<ZvecTokenFilter> filters = const [ZvecTokenFilter.lowercase],
    this.stemmerLanguage = 'english',
    this.nullable = true,
  }) : filters = List.unmodifiable(filters) {
    tokenizer._validate();
    _validateText(stemmerLanguage);
    if (stemmerLanguage.trim().isEmpty) {
      throw ArgumentError('stemmerLanguage must not be empty.');
    }
  }

  final ZvecTokenizer tokenizer;
  final List<ZvecTokenFilter> filters;

  /// Snowball language/algorithm, for example english, german or porter.
  /// Used only with [ZvecTokenFilter.stemmer]; native Zvec validates support.
  final String stemmerLanguage;
  final bool nullable;

  Map<String, Object> get _parameters => {
    ...tokenizer._parameters,
    if (filters.contains(ZvecTokenFilter.stemmer))
      'stemmer_lang': stemmerLanguage,
  };

  String get _signature => jsonEncode({
    'tokenizer': tokenizer._name,
    'filters': filters.map((f) => f._name).toList(),
    'parameters': _parameters,
    'nullable': nullable,
  });
}

enum ZvecTextOperator {
  or('OR'),
  and('AND');

  const ZvecTextOperator(this._name);
  final String _name;
}

/// Exactly one FTS input mode. Match input is plain text; expression input is
/// native boolean/phrase syntax and should be an explicit user choice.
sealed class ZvecTextQuery {
  const ZvecTextQuery(this.text, {this.operator = ZvecTextOperator.or});
  final String text;
  final ZvecTextOperator operator;
}

final class ZvecTextMatch extends ZvecTextQuery {
  const ZvecTextMatch(super.text, {super.operator});
}

final class ZvecTextExpression extends ZvecTextQuery {
  const ZvecTextExpression(super.text, {super.operator});
}

void _positive(int value, String name) {
  if (value < 1 || value > 0xffffffff) {
    throw RangeError.range(value, 1, 0xffffffff, name);
  }
}
