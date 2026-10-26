part of 'zvec.dart';

enum ZvecMetric {
  euclidean(1),
  innerProduct(2),
  cosine(3);

  const ZvecMetric(this._nativeValue);
  final int _nativeValue;
}

enum ZvecScalarType {
  string(2),
  boolean(3),
  number(9);

  const ZvecScalarType(this._nativeValue);
  final int _nativeValue;
}

sealed class ZvecValue {
  const ZvecValue();
  ZvecScalarType get type;
}

final class ZvecString extends ZvecValue {
  ZvecString(this.value) {
    _validateText(value);
  }
  final String value;
  @override
  ZvecScalarType get type => ZvecScalarType.string;
}

final class ZvecBool extends ZvecValue {
  const ZvecBool(this.value);
  final bool value;
  @override
  ZvecScalarType get type => ZvecScalarType.boolean;
}

final class ZvecNumber extends ZvecValue {
  ZvecNumber(this.value) {
    if (!value.isFinite) throw ArgumentError('Scalar numbers must be finite.');
  }
  final double value;
  @override
  ZvecScalarType get type => ZvecScalarType.number;
}

/// Native input/output document. Missing scalar fields are nullable.
final class ZvecRecord {
  const ZvecRecord(this.id, this.embedding, {this.fields = const {}});
  final String id;
  final Float32List embedding;
  final Map<String, ZvecValue> fields;
}

/// Native engine scores are not normalized by this low-level package.
final class ZvecHit {
  const ZvecHit(this.id, this.score, {this.fields = const {}});
  final String id;
  final double score;
  final Map<String, ZvecValue> fields;
}

void _validateText(String text) {
  if (text.contains('\u0000') || utf8.decode(utf8.encode(text)) != text) {
    throw ArgumentError('Expected Unicode scalar text without NUL.');
  }
}
