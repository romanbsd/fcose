import 'dart:math' as math;

/// A framework-independent two-dimensional vector or point.
final class Offset {
  const Offset(this.x, this.y);

  static const zero = Offset(0, 0);

  final double x;
  final double y;

  bool get isFinite => x.isFinite && y.isFinite;
  double get length => math.sqrt(x * x + y * y);

  double distanceTo(Offset other) => (this - other).length;

  Offset normalized() {
    final magnitude = length;
    return magnitude == 0 ? zero : this / magnitude;
  }

  Offset operator +(Offset other) => Offset(x + other.x, y + other.y);
  Offset operator -(Offset other) => Offset(x - other.x, y - other.y);
  Offset operator *(double factor) => Offset(x * factor, y * factor);
  Offset operator /(double divisor) => Offset(x / divisor, y / divisor);

  @override
  bool operator ==(Object other) => other is Offset && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Offset($x, $y)';
}

/// An axis-aligned rectangle represented by its top-left corner and size.
final class Rect {
  const Rect(this.x, this.y, this.width, this.height);

  factory Rect.fromCenter(Offset center, double width, double height) =>
      Rect(center.x - width / 2, center.y - height / 2, width, height);

  final double x;
  final double y;
  final double width;
  final double height;

  double get left => x;
  double get top => y;
  double get right => x + width;
  double get bottom => y + height;
  Offset get center => Offset(x + width / 2, y + height / 2);

  bool overlaps(Rect other) => left < other.right && right > other.left && top < other.bottom && bottom > other.top;

  bool containsRect(Rect other) =>
      left <= other.left && top <= other.top && right >= other.right && bottom >= other.bottom;

  Rect inflate(double amount) => Rect(x - amount, y - amount, width + 2 * amount, height + 2 * amount);

  Rect shift(Offset delta) => Rect(x + delta.x, y + delta.y, width, height);

  Rect union(Rect other) {
    final newLeft = math.min(left, other.left);
    final newTop = math.min(top, other.top);
    final newRight = math.max(right, other.right);
    final newBottom = math.max(bottom, other.bottom);
    return Rect(newLeft, newTop, newRight - newLeft, newBottom - newTop);
  }

  @override
  String toString() => 'Rect($x, $y, $width, $height)';
}
