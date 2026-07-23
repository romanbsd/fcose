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

  bool overlaps(Rect other) => left <= other.right && right >= other.left && top <= other.bottom && bottom >= other.top;

  bool containsRect(Rect other) =>
      left <= other.left && top <= other.top && right >= other.right && bottom >= other.bottom;

  /// Vector between the two points where the line joining the rectangle
  /// centers exits this rectangle and enters [other]. This is the edge length
  /// primitive used by layout-base and CoSE.
  Offset boundaryDisplacementTo(Rect other) {
    if (overlaps(other)) return Offset.zero;
    final points = _intersectionPoints(this, other);
    return points.target - points.source;
  }

  double boundaryDistanceTo(Rect other) => boundaryDisplacementTo(other).length;

  /// Half the movement needed to separate two intersecting rectangles, plus
  /// [buffer] on each axis. This matches layout-base's
  /// `IGeometry.calcSeparationAmount`; CoSE negates twice this value when
  /// converting it to repulsion force on this rectangle.
  Offset separationAmountTo(Rect other, {required double buffer}) {
    if (!overlaps(other)) {
      throw ArgumentError.value(other, 'other', 'rectangles must overlap');
    }
    final sourceCenter = center;
    final targetCenter = other.center;
    final directionX = sourceCenter.x < targetCenter.x ? -1.0 : 1.0;
    final directionY = sourceCenter.y < targetCenter.y ? -1.0 : 1.0;
    var overlapX = math.min(right, other.right) - math.max(left, other.left);
    var overlapY = math.min(bottom, other.bottom) - math.max(top, other.top);
    if (left <= other.left && right >= other.right) {
      overlapX += math.min(other.left - left, right - other.right);
    } else if (other.left <= left && other.right >= right) {
      overlapX += math.min(left - other.left, other.right - right);
    }
    if (top <= other.top && bottom >= other.bottom) {
      overlapY += math.min(other.top - top, bottom - other.bottom);
    } else if (other.top <= top && other.bottom >= bottom) {
      overlapY += math.min(top - other.top, other.bottom - bottom);
    }

    final centerDelta = targetCenter - sourceCenter;
    final slope = centerDelta == Offset.zero ? 1.0 : (centerDelta.y / centerDelta.x).abs();
    var moveY = slope * overlapX;
    var moveX = overlapY / slope;
    if (overlapX < moveX) {
      moveX = overlapX;
    } else {
      moveY = overlapY;
    }
    return Offset(-directionX * (moveX / 2 + buffer), -directionY * (moveY / 2 + buffer));
  }

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

({Offset source, Offset target}) _intersectionPoints(Rect source, Rect target) {
  final sourceCenter = source.center;
  final targetCenter = target.center;
  if (sourceCenter.x == targetCenter.x) {
    return sourceCenter.y > targetCenter.y
        ? (source: Offset(sourceCenter.x, source.top), target: Offset(targetCenter.x, target.bottom))
        : (source: Offset(sourceCenter.x, source.bottom), target: Offset(targetCenter.x, target.top));
  }
  if (sourceCenter.y == targetCenter.y) {
    return sourceCenter.x > targetCenter.x
        ? (source: Offset(source.left, sourceCenter.y), target: Offset(target.right, targetCenter.y))
        : (source: Offset(source.right, sourceCenter.y), target: Offset(target.left, targetCenter.y));
  }

  final sourceDiagonalSlope = source.height / source.width;
  final targetDiagonalSlope = target.height / target.width;
  final centerSlope = (targetCenter.y - sourceCenter.y) / (targetCenter.x - sourceCenter.x);
  Offset? sourceClip;
  Offset? targetClip;

  if (-sourceDiagonalSlope == centerSlope) {
    sourceClip = sourceCenter.x > targetCenter.x
        ? Offset(source.left, source.bottom)
        : Offset(source.right, source.top);
  } else if (sourceDiagonalSlope == centerSlope) {
    sourceClip = sourceCenter.x > targetCenter.x
        ? Offset(source.left, source.top)
        : Offset(source.right, source.bottom);
  }
  if (-targetDiagonalSlope == centerSlope) {
    targetClip = targetCenter.x > sourceCenter.x
        ? Offset(target.left, target.bottom)
        : Offset(target.right, target.top);
  } else if (targetDiagonalSlope == centerSlope) {
    targetClip = targetCenter.x > sourceCenter.x
        ? Offset(target.left, target.top)
        : Offset(target.right, target.bottom);
  }

  late final int sourceDirection;
  late final int targetDirection;
  if (sourceCenter.x > targetCenter.x) {
    if (sourceCenter.y > targetCenter.y) {
      sourceDirection = _cardinalDirection(sourceDiagonalSlope, centerSlope, 4);
      targetDirection = _cardinalDirection(targetDiagonalSlope, centerSlope, 2);
    } else {
      sourceDirection = _cardinalDirection(-sourceDiagonalSlope, centerSlope, 3);
      targetDirection = _cardinalDirection(-targetDiagonalSlope, centerSlope, 1);
    }
  } else if (sourceCenter.y > targetCenter.y) {
    sourceDirection = _cardinalDirection(-sourceDiagonalSlope, centerSlope, 1);
    targetDirection = _cardinalDirection(-targetDiagonalSlope, centerSlope, 3);
  } else {
    sourceDirection = _cardinalDirection(sourceDiagonalSlope, centerSlope, 2);
    targetDirection = _cardinalDirection(targetDiagonalSlope, centerSlope, 4);
  }

  return (
    source: sourceClip ?? _clipPoint(source, sourceCenter, centerSlope, sourceDirection),
    target: targetClip ?? _clipPoint(target, targetCenter, centerSlope, targetDirection),
  );
}

int _cardinalDirection(double diagonalSlope, double centerSlope, int line) =>
    diagonalSlope > centerSlope ? line : 1 + line % 4;

Offset _clipPoint(Rect rectangle, Offset center, double centerSlope, int direction) {
  final halfWidth = rectangle.width / 2;
  final halfHeight = rectangle.height / 2;
  return switch (direction) {
    1 => Offset(center.x + (-halfHeight) / centerSlope, rectangle.top),
    2 => Offset(rectangle.right, center.y + halfWidth * centerSlope),
    3 => Offset(center.x + halfHeight / centerSlope, rectangle.bottom),
    4 => Offset(rectangle.left, center.y + (-halfWidth) * centerSlope),
    _ => throw ArgumentError.value(direction, 'direction', 'must be a cardinal direction'),
  };
}
