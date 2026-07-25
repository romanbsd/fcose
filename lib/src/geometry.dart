import 'dart:math' as math;
import 'dart:typed_data';

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
    final points = Float64List(4);
    writeBoundaryIntersection(this, other, points);
    return Offset(points[2] - points[0], points[3] - points[1]);
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

/// Writes the points where the line joining the centers of [source] and
/// [target] leaves [source] and enters [target] into [out], as
/// `[sourceX, sourceY, targetX, targetY]`.
///
/// The caller must have established that the rectangles do not overlap. Writing
/// into a caller-owned buffer keeps the spring embedder's inner loops free of
/// per-pair allocation.
void writeBoundaryIntersection(Rect source, Rect target, Float64List out) {
  final sourceCenterX = source.x + source.width / 2;
  final sourceCenterY = source.y + source.height / 2;
  final targetCenterX = target.x + target.width / 2;
  final targetCenterY = target.y + target.height / 2;
  if (sourceCenterX == targetCenterX) {
    final sourceAbove = sourceCenterY > targetCenterY;
    out[0] = sourceCenterX;
    out[1] = sourceAbove ? source.top : source.bottom;
    out[2] = targetCenterX;
    out[3] = sourceAbove ? target.bottom : target.top;
    return;
  }
  if (sourceCenterY == targetCenterY) {
    final sourceRightOf = sourceCenterX > targetCenterX;
    out[0] = sourceRightOf ? source.left : source.right;
    out[1] = sourceCenterY;
    out[2] = sourceRightOf ? target.right : target.left;
    out[3] = targetCenterY;
    return;
  }

  final sourceDiagonalSlope = source.height / source.width;
  final targetDiagonalSlope = target.height / target.width;
  final centerSlope = (targetCenterY - sourceCenterY) / (targetCenterX - sourceCenterX);
  var sourceClipped = false;
  var targetClipped = false;

  if (-sourceDiagonalSlope == centerSlope) {
    sourceClipped = true;
    out[0] = sourceCenterX > targetCenterX ? source.left : source.right;
    out[1] = sourceCenterX > targetCenterX ? source.bottom : source.top;
  } else if (sourceDiagonalSlope == centerSlope) {
    sourceClipped = true;
    out[0] = sourceCenterX > targetCenterX ? source.left : source.right;
    out[1] = sourceCenterX > targetCenterX ? source.top : source.bottom;
  }
  if (-targetDiagonalSlope == centerSlope) {
    targetClipped = true;
    out[2] = targetCenterX > sourceCenterX ? target.left : target.right;
    out[3] = targetCenterX > sourceCenterX ? target.bottom : target.top;
  } else if (targetDiagonalSlope == centerSlope) {
    targetClipped = true;
    out[2] = targetCenterX > sourceCenterX ? target.left : target.right;
    out[3] = targetCenterX > sourceCenterX ? target.top : target.bottom;
  }

  late final int sourceDirection;
  late final int targetDirection;
  if (sourceCenterX > targetCenterX) {
    if (sourceCenterY > targetCenterY) {
      sourceDirection = _cardinalDirection(sourceDiagonalSlope, centerSlope, 4);
      targetDirection = _cardinalDirection(targetDiagonalSlope, centerSlope, 2);
    } else {
      sourceDirection = _cardinalDirection(-sourceDiagonalSlope, centerSlope, 3);
      targetDirection = _cardinalDirection(-targetDiagonalSlope, centerSlope, 1);
    }
  } else if (sourceCenterY > targetCenterY) {
    sourceDirection = _cardinalDirection(-sourceDiagonalSlope, centerSlope, 1);
    targetDirection = _cardinalDirection(-targetDiagonalSlope, centerSlope, 3);
  } else {
    sourceDirection = _cardinalDirection(sourceDiagonalSlope, centerSlope, 2);
    targetDirection = _cardinalDirection(targetDiagonalSlope, centerSlope, 4);
  }

  if (!sourceClipped) {
    _writeClipPoint(source, sourceCenterX, sourceCenterY, centerSlope, sourceDirection, out, 0);
  }
  if (!targetClipped) {
    _writeClipPoint(target, targetCenterX, targetCenterY, centerSlope, targetDirection, out, 2);
  }
}

int _cardinalDirection(double diagonalSlope, double centerSlope, int line) =>
    diagonalSlope > centerSlope ? line : 1 + line % 4;

void _writeClipPoint(
  Rect rectangle,
  double centerX,
  double centerY,
  double centerSlope,
  int direction,
  Float64List out,
  int offset,
) {
  final halfWidth = rectangle.width / 2;
  final halfHeight = rectangle.height / 2;
  switch (direction) {
    case 1:
      out[offset] = centerX + (-halfHeight) / centerSlope;
      out[offset + 1] = rectangle.top;
    case 2:
      out[offset] = rectangle.right;
      out[offset + 1] = centerY + halfWidth * centerSlope;
    case 3:
      out[offset] = centerX + halfHeight / centerSlope;
      out[offset + 1] = rectangle.bottom;
    case 4:
      out[offset] = rectangle.left;
      out[offset + 1] = centerY + (-halfWidth) * centerSlope;
    default:
      throw ArgumentError.value(direction, 'direction', 'must be a cardinal direction');
  }
}
