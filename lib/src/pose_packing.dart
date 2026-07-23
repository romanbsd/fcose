import 'dart:math' as math;

import 'geometry.dart';
import 'packing.dart';

/// Incremental POSE component packing from cytoscape-layout-utilities 1.1.1.
final class IncrementalComponentPacker {
  const IncrementalComponentPacker({this.componentSpacing = 80, this.iterations = _defaultIterationCount});

  static const _defaultIterationCount = 100;
  static const _edgeRefreshPeriod = 5;

  final double componentSpacing;
  final int iterations;
  double get _effectiveSpacing => math.max(1, componentSpacing);

  List<Offset> pack(List<PackingComponent> components) {
    if (components.length < 2) return List.filled(components.length, Offset.zero);

    final currentCenter = _layoutUtilitiesCenter(components);
    final polygons = [for (final component in components) _PosePolygon.fromComponent(component)];
    var edges = _constructEdges(polygons);
    final forces = List.filled(polygons.length, Offset.zero);
    final intersectionForces = List.filled(polygons.length, Offset.zero);

    for (var iteration = 1; iteration <= iterations; iteration++) {
      for (var from = 0; from < edges.length; from++) {
        for (final to in edges[from]) {
          _accumulateForce(polygons, from, to, forces, intersectionForces, _attractiveForce);
        }
      }

      // POSE 1.1.1 applies this force to connected pairs despite the upstream
      // comment describing non-connected pairs. Preserve the shipped behavior.
      for (var first = 0; first < polygons.length; first++) {
        for (var second = first + 1; second < polygons.length; second++) {
          if (!edges[first].contains(second)) continue;
          _accumulateForce(polygons, first, second, forces, intersectionForces, _repulsiveForce);
        }
      }

      for (var index = 0; index < polygons.length; index++) {
        final intersection = intersectionForces[index];
        polygons[index].move(intersection == Offset.zero ? forces[index] : intersection);
        forces[index] = Offset.zero;
        intersectionForces[index] = Offset.zero;
      }

      if (iteration % _edgeRefreshPeriod == 0) {
        edges = _constructEdges(polygons);
      }
    }

    final rawShifts = [for (final polygon in polygons) polygon.base];
    final shifted = [
      for (var index = 0; index < components.length; index++) components[index].translated(rawShifts[index]),
    ];
    final centerShift = currentCenter - _layoutUtilitiesCenter(shifted);
    return [for (final shift in rawShifts) shift + centerShift];
  }

  double _attractiveForce(double squaredDistance) =>
      3 * (math.log(math.sqrt(squaredDistance) / _effectiveSpacing) / math.ln2);

  double _repulsiveForce(double squaredDistance) => -(_effectiveSpacing * _effectiveSpacing / squaredDistance - 1);

  void _accumulateForce(
    List<_PosePolygon> polygons,
    int first,
    int second,
    List<Offset> forces,
    List<Offset> intersectionForces,
    double Function(double squaredDistance) multiplier,
  ) {
    final firstPolygon = polygons[first];
    final secondPolygon = polygons[second];
    if (_intersects(firstPolygon, secondPolygon)) {
      final direction = (secondPolygon.center - firstPolygon.center).normalized();
      final force = direction * -_effectiveSpacing;
      intersectionForces[first] = intersectionForces[first] + force;
      intersectionForces[second] = intersectionForces[second] - force;
      return;
    }

    final distance = _convexPolygonDistance(firstPolygon, secondPolygon);
    final calculated = multiplier(distance.squaredDistance);
    final magnitude = calculated.abs() < _effectiveSpacing ? calculated : _effectiveSpacing * calculated.sign;
    final force = distance.unitVector * magnitude;
    forces[first] = forces[first] + force;
    forces[second] = forces[second] - force;
  }
}

Offset _layoutUtilitiesCenter(Iterable<PackingComponent> components) {
  var left = double.maxFinite;
  var right = -double.maxFinite;
  var top = double.maxFinite;
  var bottom = -double.maxFinite;
  for (final node in components.expand((component) => component.nodes)) {
    left = math.min(left, node.left);
    right = math.max(right, node.right - 1);
    top = math.min(top, node.top);
    bottom = math.max(bottom, node.bottom - 1);
  }
  return Offset((left + right) / 2, (top + bottom) / 2);
}

List<List<int>> _constructEdges(List<_PosePolygon> polygons) {
  final count = polygons.length;
  final edges = List.generate(count, (_) => <int>[]);
  if (count < 2) return edges;
  if (count == 2) {
    edges[0].add(1);
    return edges;
  }

  final centers = [for (final polygon in polygons) polygon.center];
  if (_areCollinear(centers)) {
    final order = List.generate(count, (index) => index)
      ..sort((first, second) {
        final xOrder = centers[first].x.compareTo(centers[second].x);
        return xOrder != 0 ? xOrder : centers[first].y.compareTo(centers[second].y);
      });
    for (var position = 0; position < order.length; position++) {
      final index = order[position];
      if (position > 0 && order[position - 1] > index) edges[index].add(order[position - 1]);
      if (position + 1 < order.length && order[position + 1] > index) edges[index].add(order[position + 1]);
    }
    return edges;
  }

  final neighbors = List.generate(count, (_) => <int>{});
  for (final triangle in _delaunayTriangles(centers)) {
    _connect(neighbors, triangle.first, triangle.second);
    _connect(neighbors, triangle.second, triangle.third);
    _connect(neighbors, triangle.third, triangle.first);
  }
  for (var index = 0; index < count; index++) {
    edges[index].addAll(neighbors[index].where((neighbor) => neighbor > index).toList()..sort());
  }
  return edges;
}

void _connect(List<Set<int>> neighbors, int first, int second) {
  if (first == second) return;
  neighbors[first].add(second);
  neighbors[second].add(first);
}

bool _areCollinear(List<Offset> points) {
  final first = points.first;
  final second = points[1];
  return points.skip(2).every((point) => _orientation(first, second, point).abs() <= 1e-10);
}

List<({int first, int second, int third})> _delaunayTriangles(List<Offset> input) {
  var left = input.first.x;
  var right = left;
  var top = input.first.y;
  var bottom = top;
  for (final point in input.skip(1)) {
    left = math.min(left, point.x);
    right = math.max(right, point.x);
    top = math.min(top, point.y);
    bottom = math.max(bottom, point.y);
  }
  final span = math.max(right - left, bottom - top);
  final center = Offset((left + right) / 2, (top + bottom) / 2);
  // A 20x span leaves every input circumcircle inside the seed triangle.
  final points = [
    ...input,
    Offset(center.x - 20 * span, center.y - span),
    Offset(center.x, center.y + 20 * span),
    Offset(center.x + 20 * span, center.y - span),
  ];
  final inputCount = input.length;
  var triangles = <({int first, int second, int third})>[
    (first: inputCount, second: inputCount + 1, third: inputCount + 2),
  ];

  for (var pointIndex = 0; pointIndex < inputCount; pointIndex++) {
    final boundaryCounts = <({int first, int second}), int>{};
    final survivors = <({int first, int second, int third})>[];
    for (final triangle in triangles) {
      if (_circumcircleContains(triangle, pointIndex, points)) {
        _countBoundaryEdge(boundaryCounts, triangle.first, triangle.second);
        _countBoundaryEdge(boundaryCounts, triangle.second, triangle.third);
        _countBoundaryEdge(boundaryCounts, triangle.third, triangle.first);
      } else {
        survivors.add(triangle);
      }
    }
    triangles = survivors;
    for (final entry in boundaryCounts.entries) {
      if (entry.value == 1) {
        triangles.add((first: entry.key.first, second: entry.key.second, third: pointIndex));
      }
    }
  }

  return triangles
      .where((triangle) => triangle.first < inputCount && triangle.second < inputCount && triangle.third < inputCount)
      .toList();
}

void _countBoundaryEdge(Map<({int first, int second}), int> counts, int first, int second) {
  final edge = first < second ? (first: first, second: second) : (first: second, second: first);
  counts[edge] = (counts[edge] ?? 0) + 1;
}

bool _circumcircleContains(({int first, int second, int third}) triangle, int pointIndex, List<Offset> points) {
  final point = points[pointIndex];
  final first = points[triangle.first] - point;
  final second = points[triangle.second] - point;
  final third = points[triangle.third] - point;
  final determinant =
      (first.x * first.x + first.y * first.y) * (second.x * third.y - third.x * second.y) -
      (second.x * second.x + second.y * second.y) * (first.x * third.y - third.x * first.y) +
      (third.x * third.x + third.y * third.y) * (first.x * second.y - second.x * first.y);
  final winding = _orientation(points[triangle.first], points[triangle.second], points[triangle.third]);
  return winding > 0 ? determinant > 0 : determinant < 0;
}

({double squaredDistance, Offset unitVector}) _convexPolygonDistance(_PosePolygon first, _PosePolygon second) {
  final minkowskiPoints = <Offset>[
    for (final firstPoint in first.points)
      for (final secondPoint in second.negative().points) firstPoint + secondPoint,
  ];
  final difference = _PosePolygon.fromPoints(minkowskiPoints);
  late ({double squaredDistance, Offset unitVector}) closest;
  for (final (index, point) in difference.points.indexed) {
    final shortest = _shortestPointOnSegment(point, difference.points[(index + 1) % difference.points.length]);
    final squaredDistance = shortest.x * shortest.x + shortest.y * shortest.y;
    final unitVector = Offset(-shortest.x, -shortest.y) / math.sqrt(squaredDistance);
    final candidate = (squaredDistance: squaredDistance, unitVector: unitVector);
    if (index == 0 || candidate.squaredDistance < closest.squaredDistance) closest = candidate;
  }
  return closest;
}

Offset _shortestPointOnSegment(Offset start, Offset end) {
  final delta = end - start;
  final lengthSquared = delta.x * delta.x + delta.y * delta.y;
  if (lengthSquared == 0) return start;
  final parameter = (-(start.x * delta.x + start.y * delta.y) / lengthSquared).clamp(0.0, 1.0);
  return start + delta * parameter;
}

bool _intersects(_PosePolygon first, _PosePolygon second) {
  for (final polygon in [first, second]) {
    final points = polygon.points;
    for (final (index, point) in points.indexed) {
      final edge = points[(index + 1) % points.length] - point;
      final axis = Offset(-edge.y, edge.x);
      var firstMinimum = double.infinity;
      var firstMaximum = double.negativeInfinity;
      var secondMinimum = double.infinity;
      var secondMaximum = double.negativeInfinity;
      for (final candidate in first.points) {
        final projection = candidate.x * axis.x + candidate.y * axis.y;
        firstMinimum = math.min(firstMinimum, projection);
        firstMaximum = math.max(firstMaximum, projection);
      }
      for (final candidate in second.points) {
        final projection = candidate.x * axis.x + candidate.y * axis.y;
        secondMinimum = math.min(secondMinimum, projection);
        secondMaximum = math.max(secondMaximum, projection);
      }
      if (firstMaximum <= secondMinimum || secondMaximum <= firstMinimum) return false;
    }
  }
  return true;
}

final class _PosePolygon {
  _PosePolygon._(this._points)
    : centerOffset = _points.fold(Offset.zero, (sum, point) => sum + point) / _points.length.toDouble();

  factory _PosePolygon.fromComponent(PackingComponent component) => _PosePolygon.fromPoints([
    for (final node in component.nodes) ...[
      Offset(node.left, node.top),
      Offset(node.right, node.top),
      Offset(node.left, node.bottom),
      Offset(node.right, node.bottom),
    ],
  ]);

  factory _PosePolygon.fromPoints(List<Offset> points) {
    final remaining = List<Offset>.of(points);
    var topLeft = remaining.first;
    for (final point in remaining.skip(1)) {
      if (point.y < topLeft.y || (point.y == topLeft.y && point.x < topLeft.x)) {
        topLeft = point;
      }
    }
    remaining.remove(topLeft);
    remaining.sort((first, second) => _slopeAngle(topLeft, first).compareTo(_slopeAngle(topLeft, second)));

    final unique = <Offset>[];
    for (var index = 0; index < remaining.length;) {
      var point = remaining[index];
      var next = index + 1;
      while (next < remaining.length && _slopeAngle(topLeft, point) == _slopeAngle(topLeft, remaining[next])) {
        if ((remaining[next] - topLeft).length > (point - topLeft).length) point = remaining[next];
        next++;
      }
      unique.add(point);
      index = next;
    }

    final hull = <Offset>[topLeft];
    for (final point in unique) {
      while (hull.length > 1 && _orientation(hull[hull.length - 2], hull.last, point) < 0) {
        hull.removeLast();
      }
      hull.add(point);
    }
    return _PosePolygon._(hull);
  }

  final List<Offset> _points;
  final Offset centerOffset;
  Offset base = Offset.zero;

  List<Offset> get points => base == Offset.zero ? _points : [for (final point in _points) point + base];
  Offset get center => centerOffset + base;

  void move(Offset displacement) => base += displacement;

  _PosePolygon negative() => _PosePolygon._([for (final point in points) point * -1]);
}

double _slopeAngle(Offset from, Offset to) => math.atan2(to.y - from.y, to.x - from.x);

double _orientation(Offset first, Offset second, Offset third) =>
    second.x * third.y -
    second.y * third.x -
    first.x * third.y +
    first.x * second.y +
    first.y * third.x -
    first.y * second.x;
