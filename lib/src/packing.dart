import 'dart:math' as math;

import 'geometry.dart';
import 'options.dart';

/// Geometry passed to cytoscape-layout-utilities-style component packing.
final class PackingComponent {
  const PackingComponent({required this.nodes, required this.edges});

  final List<Rect> nodes;
  final List<({Offset start, Offset end})> edges;

  PackingComponent translated(Offset shift) => PackingComponent(
    nodes: [for (final node in nodes) node.shift(shift)],
    edges: [for (final edge in edges) (start: edge.start + shift, end: edge.end + shift)],
  );

  static Rect combinedBounds(Iterable<PackingComponent> components) {
    final nodes = components.expand((component) => component.nodes);
    final iterator = nodes.iterator;
    if (!iterator.moveNext()) {
      throw ArgumentError.value(components, 'components', 'must contain at least one node');
    }
    var bounds = iterator.current;
    while (iterator.moveNext()) {
      bounds = bounds.union(iterator.current);
    }
    return bounds;
  }
}

/// Randomized polyomino packing from cytoscape-layout-utilities 1.1.1.
final class RandomizedComponentPacker {
  const RandomizedComponentPacker({
    this.componentSpacing = 80,
    this.desiredAspectRatio = 1,
    this.gridSizeFactor = 1,
    this.utility = PackingUtility.adjustedFullness,
  });

  final double componentSpacing;
  final double desiredAspectRatio;
  final double gridSizeFactor;
  final PackingUtility utility;

  List<Offset> pack(List<PackingComponent> components) {
    if (components.length < 2) return List.filled(components.length, Offset.zero);
    final currentCenter = _layoutUtilitiesCenter(components);
    final nodeCount = components.fold(0, (sum, component) => sum + component.nodes.length);
    final averageDimension =
        components.expand((component) => component.nodes).fold(0.0, (sum, node) => sum + node.width + node.height) /
        (2 * nodeCount);
    final gridStep = math.max(1, (averageDimension * gridSizeFactor).floor());
    final spacing = math.max(1.0, componentSpacing - 52);

    var gridWidth = 0.0;
    var gridHeight = 0.0;
    final polyominos = <_Polyomino>[];
    for (final (index, component) in components.indexed) {
      final expandedNodes = [for (final node in component.nodes) node.inflate(spacing)];
      var x1 = double.maxFinite;
      var x2 = -double.maxFinite;
      var y1 = double.maxFinite;
      var y2 = -double.maxFinite;
      for (final node in expandedNodes) {
        x1 = math.min(x1, node.left);
        x2 = math.max(x2, node.right);
        y1 = math.min(y1, node.top);
        y2 = math.max(y2, node.bottom);
      }
      for (final edge in component.edges) {
        x1 = math.min(x1, edge.start.x);
        x2 = math.max(x2, edge.end.x);
        y1 = math.min(y1, edge.start.y);
        y2 = math.max(y2, edge.end.y);
      }

      final polyomino = _Polyomino(x1, y1, x2 - x1, y2 - y1, gridStep, index);
      for (final node in expandedNodes) {
        final left = ((node.left - x1) / gridStep).floor();
        final top = ((node.top - y1) / gridStep).floor();
        final right = ((node.right - x1) / gridStep).floor();
        final bottom = ((node.bottom - y1) / gridStep).floor();
        for (var x = left; x <= right; x++) {
          for (var y = top; y <= bottom; y++) {
            polyomino.cells[x][y] = true;
          }
        }
      }
      for (final edge in component.edges) {
        final start = Offset((edge.start.x - x1) / gridStep, (edge.start.y - y1) / gridStep);
        final end = Offset((edge.end.x - x1) / gridStep, (edge.end.y - y1) / gridStep);
        for (final point in _lineSupercover(start, end)) {
          final x = point.x.floor();
          final y = point.y.floor();
          if (x >= 0 && x < polyomino.stepWidth && y >= 0 && y < polyomino.stepHeight) {
            polyomino.cells[x][y] = true;
          }
        }
      }
      polyomino.occupiedCellCount = polyomino.cells.fold(
        0,
        (sum, column) => sum + column.where((occupied) => occupied).length,
      );
      gridWidth += polyomino.width;
      gridHeight += polyomino.height;
      polyominos.add(polyomino);
    }

    polyominos.sort((first, second) {
      final sizeOrder = (second.stepWidth * second.stepHeight).compareTo(first.stepWidth * first.stepHeight);
      return sizeOrder == 0 ? first.index.compareTo(second.index) : sizeOrder;
    });
    final grid = _PackingGrid(2 * gridWidth + gridStep, 2 * gridHeight + gridStep, gridStep);
    grid.place(polyominos.first, grid.centerX, grid.centerY);
    for (final polyomino in polyominos.skip(1)) {
      var candidates = <({int x, int y})>[];
      ({int x, int y})? selected;
      var bestFullness = 0.0;
      var bestAdjustedFullness = 0.0;
      var bestWeightedUtility = 0.0;
      var minimumAspectRatioDifference = 1000000.0;
      while (selected == null) {
        candidates = grid.directNeighbors(candidates, (math.max(polyomino.stepWidth, polyomino.stepHeight) / 2).ceil());
        for (final candidate in candidates) {
          if (!grid.canPlace(polyomino, candidate.x, candidate.y)) continue;
          final value = grid.utilityOf(polyomino, candidate.x, candidate.y, desiredAspectRatio);
          var choose = false;
          switch (utility) {
            case PackingUtility.adjustedFullness:
              final aspectDifference = (value.aspectRatio - desiredAspectRatio).abs();
              choose =
                  value.adjustedFullness > bestAdjustedFullness ||
                  (value.adjustedFullness == bestAdjustedFullness &&
                      (value.fullness > bestFullness ||
                          (value.fullness == bestFullness && aspectDifference <= minimumAspectRatioDifference)));
              if (choose) {
                bestAdjustedFullness = value.adjustedFullness;
                bestFullness = value.fullness;
                minimumAspectRatioDifference = aspectDifference;
              }
            case PackingUtility.weighted:
              final aspectDifference = (value.aspectRatio - desiredAspectRatio).abs();
              final weighted =
                  value.fullness * 0.5 + (1 - aspectDifference / math.max(value.aspectRatio, desiredAspectRatio) * 0.5);
              choose = weighted > bestWeightedUtility;
              if (choose) bestWeightedUtility = weighted;
          }
          if (choose) selected = candidate;
        }
        if (candidates.isEmpty) {
          throw StateError('component packing grid has no available placement');
        }
      }
      grid.place(polyomino, selected.x, selected.y);
    }

    polyominos.sort((first, second) => first.index.compareTo(second.index));
    final rawShifts = [
      for (final polyomino in polyominos)
        Offset(
          (polyomino.locationX - polyomino.centerX - grid.left) * gridStep - polyomino.x,
          (polyomino.locationY - polyomino.centerY - grid.top) * gridStep - polyomino.y,
        ),
    ];
    final expandedComponents = [
      for (var index = 0; index < components.length; index++)
        PackingComponent(
          nodes: [for (final node in components[index].nodes) node.inflate(spacing).shift(rawShifts[index])],
          edges: components[index].edges,
        ),
    ];
    final packedCenter = _layoutUtilitiesCenter(expandedComponents);
    final centerShift = currentCenter - packedCenter;
    return [for (final shift in rawShifts) shift + centerShift];
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

List<Offset> _lineSupercover(Offset start, Offset end) {
  final deltaX = end.x - start.x;
  final deltaY = end.y - start.y;
  final countX = deltaX.abs().floor();
  final countY = deltaY.abs().floor();
  final directionX = deltaX > 0 ? 1 : -1;
  final directionY = deltaY > 0 ? 1 : -1;
  var x = start.x;
  var y = start.y;
  final result = <Offset>[Offset(x, y)];
  var indexX = 0;
  var indexY = 0;
  while (indexX < countX || indexY < countY) {
    final xProgress = countX == 0 ? double.infinity : (0.5 + indexX) / countX;
    final yProgress = countY == 0 ? double.infinity : (0.5 + indexY) / countY;
    if (xProgress == yProgress) {
      x += directionX;
      y += directionY;
      indexX++;
      indexY++;
    } else if (xProgress < yProgress) {
      x += directionX;
      indexX++;
    } else {
      y += directionY;
      indexY++;
    }
    result.add(Offset(x, y));
  }
  return result;
}

final class _Polyomino {
  _Polyomino(this.x, this.y, this.width, this.height, this.gridStep, this.index)
    : cells = List.generate((width / gridStep).floor() + 1, (_) => List.filled((height / gridStep).floor() + 1, false));

  final double x;
  final double y;
  final double width;
  final double height;
  final int gridStep;
  final int index;
  final List<List<bool>> cells;
  late final int centerX = stepWidth ~/ 2;
  late final int centerY = stepHeight ~/ 2;
  int locationX = -1;
  int locationY = -1;
  int occupiedCellCount = 0;

  int get stepWidth => (width / gridStep).floor() + 1;
  int get stepHeight => (height / gridStep).floor() + 1;
}

final class _PackingGrid {
  /// Largest integer represented exactly by both the Dart VM and JavaScript.
  static const _largestExactJavaScriptInteger = 0x1fffffffffffff;

  _PackingGrid(double width, double height, this.step)
    : cells = List.generate(
        (width / step).floor() + 1,
        (_) => List.generate((height / step).floor() + 1, (_) => _PackingCell()),
      );

  final int step;
  final List<List<_PackingCell>> cells;
  int left = _largestExactJavaScriptInteger;
  int right = -_largestExactJavaScriptInteger;
  int top = _largestExactJavaScriptInteger;
  int bottom = -_largestExactJavaScriptInteger;
  int occupiedCellCount = 0;

  int get width => cells.length;
  int get height => cells.first.length;
  int get centerX => width ~/ 2;
  int get centerY => height ~/ 2;

  List<({int x, int y})> directNeighbors(List<({int x, int y})> candidates, int level) {
    final result = <({int x, int y})>[];
    if (candidates.isEmpty) {
      for (var x = 0; x < width; x++) {
        for (var y = 0; y < height; y++) {
          if (cells[x][y].occupied) result.addAll(_cellNeighbors(x, y));
        }
      }
      var start = 0;
      var end = result.length - 1;
      for (var distance = 2; distance <= level; distance++) {
        for (var index = start; index <= end; index++) {
          result.addAll(_cellNeighbors(result[index].x, result[index].y));
        }
        start = end + 1;
        end = result.length - 1;
      }
    } else {
      for (final candidate in candidates) {
        result.addAll(_cellNeighbors(candidate.x, candidate.y));
      }
    }
    return result;
  }

  List<({int x, int y})> _cellNeighbors(int x, int y) {
    const directions = [
      (x: -1, y: 0),
      (x: 1, y: 0),
      (x: 0, y: -1),
      (x: 0, y: 1),
      (x: -1, y: 0),
      (x: -1, y: -1),
      (x: 1, y: -1),
      (x: -1, y: 1),
      (x: 1, y: 1),
    ];
    final result = <({int x, int y})>[];
    for (final direction in directions) {
      final nextX = x + direction.x;
      final nextY = y + direction.y;
      if (nextX < 0 || nextX >= width || nextY < 0 || nextY >= height) continue;
      final cell = cells[nextX][nextY];
      if (cell.occupied || cell.visited) continue;
      cell.visited = true;
      result.add((x: nextX, y: nextY));
    }
    return result;
  }

  bool canPlace(_Polyomino polyomino, int x, int y) {
    for (var localX = 0; localX < polyomino.stepWidth; localX++) {
      for (var localY = 0; localY < polyomino.stepHeight; localY++) {
        final gridX = localX - polyomino.centerX + x;
        final gridY = localY - polyomino.centerY + y;
        if (gridX < 0 || gridX >= width || gridY < 0 || gridY >= height) return false;
        if (polyomino.cells[localX][localY] && cells[gridX][gridY].occupied) return false;
      }
    }
    return true;
  }

  void place(_Polyomino polyomino, int x, int y) {
    polyomino
      ..locationX = x
      ..locationY = y;
    for (var localX = 0; localX < polyomino.stepWidth; localX++) {
      for (var localY = 0; localY < polyomino.stepHeight; localY++) {
        if (polyomino.cells[localX][localY]) {
          cells[localX - polyomino.centerX + x][localY - polyomino.centerY + y].occupied = true;
        }
      }
    }
    occupiedCellCount += polyomino.occupiedCellCount;
    left = math.min(left, x - polyomino.centerX);
    right = math.max(right, x - polyomino.centerX + polyomino.stepWidth - 1);
    top = math.min(top, y - polyomino.centerY);
    bottom = math.max(bottom, y - polyomino.centerY + polyomino.stepHeight - 1);
    for (final column in cells) {
      for (final cell in column) {
        cell.visited = false;
      }
    }
  }

  ({double aspectRatio, double fullness, double adjustedFullness}) utilityOf(
    _Polyomino polyomino,
    int x,
    int y,
    double desiredAspectRatio,
  ) {
    final newLeft = math.min(left, x - polyomino.centerX);
    final newRight = math.max(right, x - polyomino.centerX + polyomino.stepWidth - 1);
    final newTop = math.min(top, y - polyomino.centerY);
    final newBottom = math.max(bottom, y - polyomino.centerY + polyomino.stepHeight - 1);
    final occupiedWidth = newRight - newLeft + 1;
    final occupiedHeight = newBottom - newTop + 1;
    final aspectRatio = occupiedWidth / occupiedHeight;
    final occupied = occupiedCellCount + polyomino.occupiedCellCount;
    final fullness = occupied / (occupiedWidth * occupiedHeight);
    final adjustedFullness = aspectRatio > desiredAspectRatio
        ? occupied / (occupiedWidth * (occupiedWidth / desiredAspectRatio))
        : occupied / ((occupiedHeight * desiredAspectRatio) * occupiedHeight);
    return (aspectRatio: aspectRatio, fullness: fullness, adjustedFullness: adjustedFullness);
  }
}

final class _PackingCell {
  bool occupied = false;
  bool visited = false;
}
