import 'dart:io';
import 'dart:typed_data';

import 'package:dart_zvec/dart_zvec.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  ZvecCollection? collection;
  setUp(() => temp = Directory.systemTemp.createTempSync('zvec-fts-'));
  tearDown(() {
    collection?.close();
    collection = null;
    temp.deleteSync(recursive: true);
  });

  ZvecRecord text(String id, String content, {String scope = 'a'}) =>
      ZvecRecord.text(
        id,
        fields: {'content': ZvecString(content), 'scope': ZvecString(scope)},
      );

  test(
    'text-only BM25 ranks, filters and persists raw text without vectors',
    () {
      final indexes = {'content': ZvecTextIndex(nullable: false)};
      var db = collection = ZvecCollection.create(
        '${temp.path}/db',
        textIndexes: indexes,
        scalarFields: {'scope': ZvecScalarType.string},
      );
      db.insert([
        text('precise', 'vector search'),
        text('long', 'vector search ${List.filled(40, 'unrelated').join(' ')}'),
        text('partial', 'vector storage'),
        text('other-scope', 'vector search', scope: 'b'),
        text('unrelated', 'sunshine clouds'),
      ]);
      db.flush();
      db.optimize();
      final hits = db.searchText(
        'content',
        const ZvecTextMatch('VECTOR SEARCH'),
        filter: "scope = 'a'",
      );
      expect(hits.first.id, 'precise');
      expect(
        hits.map((h) => h.id),
        containsAll(['precise', 'long', 'partial']),
      );
      expect(hits.map((h) => h.id), isNot(contains('other-scope')));
      for (var i = 1; i < hits.length; i++) {
        expect(hits[i - 1].score, greaterThanOrEqualTo(hits[i].score));
      }
      expect(hits.first.score, greaterThan(0));
      expect(
        db
            .searchText(
              'content',
              const ZvecTextMatch('vector search'),
              limit: 1,
              filter: "scope = 'a'",
            )
            .single
            .id,
        'precise',
      );
      expect(
        (hits.first.fields['content'] as ZvecString).value,
        'vector search',
      );
      final both = db.searchText(
        'content',
        const ZvecTextMatch('vector search', operator: ZvecTextOperator.and),
        filter: "scope = 'a'",
      );
      expect(both.map((h) => h.id), unorderedEquals(['precise', 'long']));
      expect(db.searchText('content', const ZvecTextMatch('unknown')), isEmpty);
      expect(
        db.searchText(
          'content',
          const ZvecTextMatch('vector'),
          filter: "scope = 'none'",
        ),
        isEmpty,
      );
      expect(db.fetch(['precise']).single.embedding, isNull);
      expect(db.hasVectorField, isFalse);
      db.close();
      // Incorrect expectations must close the native handle, allowing the next open.
      expect(
        () => ZvecCollection.open('${temp.path}/db', dimensions: 2),
        throwsArgumentError,
      );
      expect(
        () => ZvecCollection.open(
          '${temp.path}/db',
          textIndexes: {
            'content': ZvecTextIndex(
              tokenizer: const ZvecWhitespaceTokenizer(),
              nullable: false,
            ),
          },
        ),
        throwsArgumentError,
      );
      db = collection = ZvecCollection.open(
        '${temp.path}/db',
        textIndexes: indexes,
      );
      expect(db.dimensions, isNull);
      expect(db.textIndexes['content']!.nullable, isFalse);
      expect(
        db.textIndexes['content']!.tokenizer,
        isA<ZvecStandardTokenizer>(),
      );
      expect(db.scalarFields['content'], ZvecScalarType.string);
      expect(
        db
            .searchText(
              'content',
              const ZvecTextMatch('search'),
              filter: "scope = 'a'",
            )
            .first
            .id,
        'precise',
      );
      expect(db.fetch(['precise']).single.embedding, isNull);
    },
  );

  test('phrases, boolean operators, replacement and deletions update FTS', () {
    final db = collection = ZvecCollection.create(
      '${temp.path}/db',
      textIndexes: {'content': ZvecTextIndex()},
      scalarFields: {'scope': ZvecScalarType.string},
    );
    db.upsert([
      text('phrase', 'machine learning neural'),
      text('separated', 'machine advanced learning'),
      text('other', 'machine hardware'),
    ]);
    db.optimize();
    expect(
      db
          .searchText('content', const ZvecTextExpression('"machine learning"'))
          .map((h) => h.id),
      ['phrase'],
    );
    expect(
      db
          .searchText(
            'content',
            const ZvecTextExpression('machine AND learning NOT neural'),
          )
          .map((h) => h.id),
      ['separated'],
    );
    db.upsert([text('phrase', 'ocean coral')]);
    db.flush();
    db.optimize();
    expect(db.searchText('content', const ZvecTextMatch('neural')), isEmpty);
    expect(
      db.searchText('content', const ZvecTextMatch('coral')).single.id,
      'phrase',
    );
    // Replacement also removes optional text and changes filter membership.
    db.upsert([const ZvecRecord.text('phrase')]);
    expect(db.searchText('content', const ZvecTextMatch('coral')), isEmpty);
    expect(db.fetch(['phrase']).single.fields, isEmpty);
    db.upsert([text('phrase', 'coral', scope: 'b')]);
    expect(
      db.searchText(
        'content',
        const ZvecTextMatch('coral'),
        filter: "scope = 'a'",
      ),
      isEmpty,
    );
    expect(
      db
          .searchText(
            'content',
            const ZvecTextMatch('coral'),
            filter: "scope = 'b'",
          )
          .single
          .id,
      'phrase',
    );
    db.delete(['phrase']);
    expect(db.searchText('content', const ZvecTextMatch('coral')), isEmpty);
    db.deleteWhere("scope = 'a'");
    expect(db.searchText('content', const ZvecTextMatch('machine')), isEmpty);
    db.close();
    collection = ZvecCollection.open('${temp.path}/db');
    expect(
      collection!.searchText('content', const ZvecTextMatch('machine coral')),
      isEmpty,
    );
  });

  test('combined collection supports independent text and vector queries', () {
    var db = collection = ZvecCollection.create(
      '${temp.path}/db',
      dimensions: 2,
      textIndexes: {'content': ZvecTextIndex()},
      scalarFields: {'scope': ZvecScalarType.string},
    );
    expect(
      () => db.insert([
        ZvecRecord.text(
          'missing-vector',
          fields: {'content': ZvecString('alpha')},
        ),
      ]),
      throwsArgumentError,
    );
    db.upsert([
      ZvecRecord(
        'one',
        Float32List.fromList([1, 0]),
        fields: {
          'content': ZvecString('alpha ready'),
          'scope': ZvecString('a'),
        },
      ),
      ZvecRecord(
        'two',
        Float32List.fromList([0, 1]),
        fields: {
          'content': ZvecString('alpha other'),
          'scope': ZvecString('b'),
        },
      ),
    ]);
    db.optimize();
    expect(
      db.searchText('content', const ZvecTextMatch('alpha')).map((h) => h.id),
      unorderedEquals(['one', 'two']),
    );
    expect(
      db
          .searchText(
            'content',
            const ZvecTextMatch('alpha'),
            filter: "scope = 'a'",
          )
          .single
          .id,
      'one',
    );
    expect(
      db.search(Float32List.fromList([0, 1]), exact: true).first.id,
      'two',
    );
    db.close();
    expect(() => ZvecCollection.open('${temp.path}/db'), throwsArgumentError);
    db = collection = ZvecCollection.open('${temp.path}/db', dimensions: 2);
    expect(db.fetch(['two']).single.embedding, [0, 1]);
    expect(
      db.search(Float32List.fromList([0, 1]), exact: true).first.id,
      'two',
    );
    expect(
      db.searchText('content', const ZvecTextMatch('other')).single.id,
      'two',
    );
  });

  for (final language in ['english', 'german']) {
    test('$language stemming and Unicode survive reopen', () {
      final indexes = {
        'content': ZvecTextIndex(
          filters: [ZvecTokenFilter.lowercase, ZvecTokenFilter.stemmer],
          stemmerLanguage: language,
        ),
      };
      var db = collection = ZvecCollection.create(
        '${temp.path}/db',
        textIndexes: indexes,
      );
      final input = language == 'english'
          ? 'RUNNING runners cafés'
          : 'HÄUSER Häusern Straße';
      final query = language == 'english' ? 'run' : 'Haus';
      db.insert([
        ZvecRecord.text('unicode', fields: {'content': ZvecString(input)}),
      ]);
      db.close();
      db = collection = ZvecCollection.open(
        '${temp.path}/db',
        textIndexes: indexes,
      );
      expect(
        db.searchText('content', ZvecTextMatch(query)).single.id,
        'unicode',
      );
      expect(
        (db.fetch(['unicode']).single.fields['content'] as ZvecString).value,
        input,
      );
      expect(db.textIndexes['content']!.stemmerLanguage, language);
    });
  }

  test(
    'whitespace, empty filters, ASCII folding and ngram settings round-trip',
    () {
      final indexes = {
        'exact': ZvecTextIndex(
          tokenizer: const ZvecWhitespaceTokenizer(),
          filters: [],
        ),
        'folded': ZvecTextIndex(
          filters: [ZvecTokenFilter.lowercase, ZvecTokenFilter.asciiFolding],
        ),
        'grams': ZvecTextIndex(
          tokenizer: ZvecNgramTokenizer(
            min: 2,
            max: 3,
            characters: [ZvecTokenCharacter.letter],
          ),
        ),
      };
      var db = collection = ZvecCollection.create(
        '${temp.path}/db',
        textIndexes: indexes,
      );
      db.insert([
        ZvecRecord.text(
          'one',
          fields: {
            'exact': ZvecString('Hello-world'),
            'folded': ZvecString('CAFÉ'),
            'grams': ZvecString('abcd'),
          },
        ),
      ]);
      db.close();
      db = collection = ZvecCollection.open(
        '${temp.path}/db',
        textIndexes: indexes,
      );
      expect(
        db.searchText('exact', const ZvecTextMatch('Hello-world')).single.id,
        'one',
      );
      expect(
        db.searchText('exact', const ZvecTextMatch('hello-world')),
        isEmpty,
      );
      expect(
        db.searchText('folded', const ZvecTextMatch('cafe')).single.id,
        'one',
      );
      expect(
        db.searchText('grams', const ZvecTextMatch('bc')).single.id,
        'one',
      );
    },
  );

  test('invalid queries and schemas fail without poisoning the handle', () {
    final path = '${temp.path}/db';
    expect(
      () => ZvecCollection.create(
        path,
        dimensions: 2,
        textIndexes: {'embedding': ZvecTextIndex()},
      ),
      throwsArgumentError,
    );
    expect(
      () => ZvecCollection.create(
        path,
        textIndexes: {'bad-name': ZvecTextIndex()},
      ),
      throwsArgumentError,
    );
    final db = collection = ZvecCollection.create(
      path,
      textIndexes: {'content': ZvecTextIndex(nullable: false)},
    );
    expect(
      () => db.insert([
        ZvecRecord.text('valid', fields: {'content': ZvecString('search')}),
        const ZvecRecord.text('missing'),
      ]),
      throwsArgumentError,
    );
    expect(db.fetch(['valid']), isEmpty);
    expect(
      () => db.insert([
        ZvecRecord.text('wrong', fields: {'content': ZvecNumber(1)}),
      ]),
      throwsArgumentError,
    );
    expect(
      () => db.searchText('missing', const ZvecTextMatch('word')),
      throwsArgumentError,
    );
    expect(
      () => db.searchText('content', const ZvecTextMatch('  ')),
      throwsArgumentError,
    );
    expect(
      () => db.searchText('content', const ZvecTextMatch('bad\u0000')),
      throwsArgumentError,
    );
    expect(
      () => db.searchText('content', const ZvecTextMatch('word'), limit: 0),
      throwsRangeError,
    );
    expect(() => db.search(Float32List.fromList([1, 0])), throwsStateError);
    db.insert([
      ZvecRecord.text('ok', fields: {'content': ZvecString('search')}),
    ]);
    db.optimize();
    // Exercise cleanup for both native parser and filter errors repeatedly.
    for (var i = 0; i < 10; i++) {
      expect(
        () => db.searchText('content', const ZvecTextExpression('(')),
        throwsA(isA<ZvecException>()),
      );
      expect(
        () => db.searchText(
          'content',
          const ZvecTextMatch('search'),
          filter: 'missing = 1',
        ),
        throwsA(isA<ZvecException>()),
      );
    }
    expect(
      db.searchText('content', const ZvecTextMatch('search')).single.id,
      'ok',
    );
    db.close();
    expect(
      () => db.searchText('content', const ZvecTextMatch('search')),
      throwsStateError,
    );
  });

  test('read-only text collections can share a persisted index', () {
    final path = '${temp.path}/db';
    final writer = collection = ZvecCollection.create(
      path,
      textIndexes: {'content': ZvecTextIndex()},
    );
    writer.insert([
      ZvecRecord.text('one', fields: {'content': ZvecString('search')}),
    ]);
    writer.close();
    final first = collection = ZvecCollection.open(path, readOnly: true);
    final second = ZvecCollection.open(path, readOnly: true);
    try {
      expect(
        first.searchText('content', const ZvecTextMatch('search')).single.id,
        'one',
      );
      expect(
        second.searchText('content', const ZvecTextMatch('search')).single.id,
        'one',
      );
      expect(
        () => first.upsert([
          ZvecRecord.text('two', fields: {'content': ZvecString('search')}),
        ]),
        throwsA(isA<ZvecException>()),
      );
    } finally {
      second.close();
    }
  });
}
