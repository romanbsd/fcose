import 'dart:collection';
import 'dart:math' as math;

import 'constraints.dart';
import 'geometry.dart';
import 'model.dart';
import 'options.dart';

/// Immutable output of an fCoSE layout run.
final class FcoseResult {
  FcoseResult({required Map<String, Offset> positions, required Map<String, Rect> rectangles, required this.iterations})
    : positions = Map.unmodifiable(positions),
      rectangles = Map.unmodifiable(rectangles);

  final Map<String, Offset> positions;
  final Map<String, Rect> rectangles;
  final int iterations;

  Offset positionOf(String id) => positions[id] ?? (throw ArgumentError.value(id, 'id', 'unknown node'));

  Rect rectOf(String id) => rectangles[id] ?? (throw ArgumentError.value(id, 'id', 'unknown node'));

  Rect boundsOf(Iterable<String> ids) {
    final iterator = ids.iterator;
    if (!iterator.moveNext()) throw ArgumentError.value(ids, 'ids', 'must not be empty');
    var result = rectOf(iterator.current);
    while (iterator.moveNext()) {
      result = result.union(rectOf(iterator.current));
    }
    return result;
  }
}

/// Pure Dart implementation of the fCoSE spectral + compound spring layout.
///
/// The input and output deliberately contain no Cytoscape, DOM, or Flutter
/// objects, making this class suitable for a Dart Mermaid renderer.
final class FcoseLayout {
  const FcoseLayout({this.options = const FcoseOptions()});

  final FcoseOptions options;

  FcoseResult run(FcoseGraph graph) {
    _validateOptions();
    _validateConstraints(graph);
    if (graph.nodes.isEmpty) {
      return FcoseResult(positions: const {}, rectangles: const {}, iterations: 0);
    }

    final working = _WorkingGraph(graph);
    final random = _Random(options.seed);
    final positions = _initialPositions(working, random);
    _projectConstraints(positions, working);

    var iterations = 0;
    if (options.quality != LayoutQuality.draft) {
      iterations = _runSpringEmbedder(working, positions);
    }
    _projectConstraints(positions, working);
    _packComponents(working, positions);
    _projectConstraints(positions, working);

    final allPositions = <String, Offset>{...positions};
    final rectangles = <String, Rect>{};
    for (final node in working.leaves) {
      rectangles[node.id] = Rect.fromCenter(positions[node.id]!, node.width, node.height);
    }
    _calculateCompoundBounds(graph, allPositions, rectangles);
    return FcoseResult(positions: allPositions, rectangles: rectangles, iterations: iterations);
  }

  Map<String, Offset> _initialPositions(_WorkingGraph graph, _Random random) {
    if (!options.randomize && graph.leaves.every((node) => node.position != null)) {
      return {for (final node in graph.leaves) node.id: node.position!};
    }
    final positions = <String, Offset>{};
    for (final component in graph.components) {
      final local = _spectralComponent(graph, component, random);
      positions.addAll(local);
    }
    return positions;
  }

  /// Landmark graph-distance embedding corresponding to fCoSE's spectral phase.
  Map<String, Offset> _spectralComponent(_WorkingGraph graph, List<String> component, _Random random) {
    if (component.length == 1) return {component.single: Offset.zero};
    final start = component[random.nextInt(component.length)];
    final fromStart = graph.distances(start, component);
    final pivotX = _farthest(component, fromStart);
    final fromX = graph.distances(pivotX, component);
    final pivotY = _farthest(component, fromX);
    final fromY = graph.distances(pivotY, component);
    final diameter = math.max(1, fromX[pivotY] ?? 1);
    final result = <String, Offset>{};
    for (final id in component) {
      final dx = (fromX[id] ?? diameter).toDouble();
      final dy = (fromY[id] ?? diameter).toDouble();
      // Classical two-landmark projection. A tiny seeded perturbation avoids
      // coincident vertices in symmetric graphs before force refinement.
      final x = (dx - dy) * options.nodeSeparation / 2;
      final radial = math.max(0, dx * dx - math.pow(x / options.nodeSeparation + diameter / 2, 2));
      final y = math.sqrt(radial) * options.nodeSeparation;
      final jitter = Offset(random.nextDouble() - 0.5, random.nextDouble() - 0.5) * 1e-3;
      result[id] = Offset(x, y) + jitter;
    }
    return result;
  }

  String _farthest(List<String> ids, Map<String, int> distances) {
    var result = ids.first;
    for (final id in ids.skip(1)) {
      if ((distances[id] ?? -1) > (distances[result] ?? -1)) result = id;
    }
    return result;
  }

  int _runSpringEmbedder(_WorkingGraph graph, Map<String, Offset> positions) {
    final forces = <String, Offset>{};
    final fixed = options.fixedNodes.map((constraint) => constraint.nodeId).toSet();
    var stableChecks = 0;
    var previousEnergy = double.infinity;

    for (var iteration = 0; iteration < options.maxIterations; iteration++) {
      for (final node in graph.leaves) {
        forces[node.id] = Offset.zero;
      }

      // CoSE repulsion. Node dimensions contribute to the effective distance.
      for (var i = 0; i < graph.leaves.length; i++) {
        final first = graph.leaves[i];
        for (var j = i + 1; j < graph.leaves.length; j++) {
          final second = graph.leaves[j];
          var delta = positions[first.id]! - positions[second.id]!;
          if (delta.length < 1e-7) delta = Offset(1e-3 * (i + 1), 1e-3 * (j + 1));
          final boundaryDistance = math.max(
            1,
            delta.length - (first.width + first.height + second.width + second.height) / 8,
          );
          final magnitude = options.nodeRepulsion / (boundaryDistance * boundaryDistance);
          final force = delta.normalized() * magnitude;
          forces[first.id] = forces[first.id]! + force;
          forces[second.id] = forces[second.id]! - force;
        }
      }

      // Hooke springs; compound endpoints are represented by a descendant leaf.
      for (final edge in graph.edges) {
        final source = graph.representative(edge.source);
        final target = graph.representative(edge.target);
        if (source == target) continue;
        var delta = positions[target]! - positions[source]!;
        if (delta.length < 1e-7) delta = const Offset(1e-3, 0);
        final ideal = edge.idealLength ?? options.idealEdgeLength;
        final elasticity = edge.elasticity ?? options.edgeElasticity;
        final magnitude = elasticity * (delta.length - ideal);
        final force = delta.normalized() * magnitude;
        forces[source] = forces[source]! + force;
        forces[target] = forces[target]! - force;
      }

      final center = positions.values.fold(Offset.zero, (sum, point) => sum + point) / positions.length.toDouble();
      final progress = iteration / math.max(1, options.maxIterations - 1);
      final temperature = math
          .max(options.minTemperature, options.initialTemperature * math.pow(1 - progress, 2))
          .toDouble();
      var energy = 0.0;
      for (final node in graph.leaves) {
        if (fixed.contains(node.id)) continue;
        final position = positions[node.id]!;
        final gravityForce = (center - position) * options.gravity;
        var displacement = forces[node.id]! + gravityForce;
        if (displacement.length > temperature) displacement = displacement.normalized() * temperature;
        positions[node.id] = position + displacement;
        energy += displacement.length;
      }
      _projectConstraints(positions, graph);

      final averageEnergy = energy / math.max(1, graph.leaves.length);
      if (averageEnergy < options.convergenceThreshold ||
          (previousEnergy - averageEnergy).abs() < options.convergenceThreshold * 0.01) {
        stableChecks++;
        if (stableChecks >= 8) return iteration + 1;
      } else {
        stableChecks = 0;
      }
      previousEnergy = averageEnergy;
    }
    return options.maxIterations;
  }

  void _projectConstraints(Map<String, Offset> positions, _WorkingGraph graph) {
    final fixed = {for (final constraint in options.fixedNodes) constraint.nodeId: constraint.position};
    final fixedX = fixed.keys.map(graph.representative).toSet();
    final fixedY = fixed.keys.map(graph.representative).toSet();
    for (final entry in fixed.entries) {
      positions[graph.representative(entry.key)] = entry.value;
    }
    for (final ids in options.alignment.vertical) {
      _align(ids, positions, graph, fixed, horizontal: false);
      if (ids.any(fixed.containsKey)) fixedX.addAll(ids.map(graph.representative));
    }
    for (final ids in options.alignment.horizontal) {
      _align(ids, positions, graph, fixed, horizontal: true);
      if (ids.any(fixed.containsKey)) fixedY.addAll(ids.map(graph.representative));
    }
    // Repeated relaxation handles chains of relative constraints without
    // depending on their input order.
    for (var pass = 0; pass < options.relativePlacements.length + 1; pass++) {
      for (final constraint in options.relativePlacements) {
        final first = graph.representative(constraint.first);
        final second = graph.representative(constraint.second);
        final a = positions[first]!;
        final b = positions[second]!;
        final gap = constraint.gap ?? options.idealEdgeLength;
        switch (constraint.axis) {
          case RelativePlacementAxis.horizontal:
            if (b.x - a.x < gap) {
              _movePair(first, second, Offset(gap - (b.x - a.x), 0), positions, fixedX);
            }
          case RelativePlacementAxis.vertical:
            if (b.y - a.y < gap) {
              _movePair(first, second, Offset(0, gap - (b.y - a.y)), positions, fixedY);
            }
        }
      }
    }
    // Fixed positions have final authority, as in upstream ConstraintHandler.
    for (final entry in fixed.entries) {
      positions[graph.representative(entry.key)] = entry.value;
    }
  }

  void _align(
    List<String> ids,
    Map<String, Offset> positions,
    _WorkingGraph graph,
    Map<String, Offset> fixed, {
    required bool horizontal,
  }) {
    if (ids.isEmpty) return;
    final representatives = ids.map(graph.representative).toSet();
    final fixedId = ids.where(fixed.containsKey).firstOrNull;
    final coordinate = fixedId != null
        ? (horizontal ? fixed[fixedId]!.y : fixed[fixedId]!.x)
        : representatives.map((id) => horizontal ? positions[id]!.y : positions[id]!.x).reduce((a, b) => a + b) /
              representatives.length;
    for (final id in representatives) {
      final old = positions[id]!;
      positions[id] = horizontal ? Offset(old.x, coordinate) : Offset(coordinate, old.y);
    }
  }

  void _movePair(String first, String second, Offset correction, Map<String, Offset> positions, Set<String> fixed) {
    final firstFixed = fixed.contains(first);
    final secondFixed = fixed.contains(second);
    if (firstFixed && secondFixed) return;
    if (firstFixed) {
      positions[second] = positions[second]! + correction;
    } else if (secondFixed) {
      positions[first] = positions[first]! - correction;
    } else {
      positions[first] = positions[first]! - correction / 2;
      positions[second] = positions[second]! + correction / 2;
    }
  }

  void _packComponents(_WorkingGraph graph, Map<String, Offset> positions) {
    if (graph.components.length < 2 || options.fixedNodes.isNotEmpty) return;
    final areas = <({List<String> ids, Rect bounds})>[];
    for (final component in graph.components) {
      Rect? bounds;
      for (final id in component) {
        final node = graph.nodeById[id]!;
        final rect = Rect.fromCenter(positions[id]!, node.width, node.height);
        bounds = bounds == null ? rect : bounds.union(rect);
      }
      areas.add((ids: component, bounds: bounds!));
    }
    areas.sort((a, b) => b.bounds.height.compareTo(a.bounds.height));
    final totalArea = areas.fold(0.0, (sum, area) => sum + area.bounds.width * area.bounds.height);
    final rowLimit = math.max(math.sqrt(totalArea) * 1.5, areas.first.bounds.width);
    var cursorX = 0.0;
    var cursorY = 0.0;
    var rowHeight = 0.0;
    for (final area in areas) {
      if (cursorX > 0 && cursorX + area.bounds.width > rowLimit) {
        cursorX = 0;
        cursorY += rowHeight + options.componentSeparation;
        rowHeight = 0;
      }
      final shift = Offset(cursorX - area.bounds.left, cursorY - area.bounds.top);
      for (final id in area.ids) {
        positions[id] = positions[id]! + shift;
      }
      cursorX += area.bounds.width + options.componentSeparation;
      rowHeight = math.max(rowHeight, area.bounds.height);
    }
  }

  void _calculateCompoundBounds(FcoseGraph graph, Map<String, Offset> positions, Map<String, Rect> rectangles) {
    final pending = graph.nodes.where((node) => graph.childrenByParent[node.id]?.isNotEmpty ?? false).toSet();
    while (pending.isNotEmpty) {
      final node = pending.firstWhere(
        (candidate) => graph.childrenByParent[candidate.id]!.every((child) => rectangles.containsKey(child.id)),
      );
      final children = graph.childrenByParent[node.id]!;
      var bounds = rectangles[children.first.id]!;
      for (final child in children.skip(1)) {
        bounds = bounds.union(rectangles[child.id]!);
      }
      bounds = bounds.inflate(options.compoundPadding);
      final width = math.max(node.width, bounds.width);
      final height = math.max(node.height, bounds.height);
      final rect = Rect.fromCenter(bounds.center, width, height);
      rectangles[node.id] = rect;
      positions[node.id] = rect.center;
      pending.remove(node);
    }
  }

  void _validateConstraints(FcoseGraph graph) {
    final ids = graph.nodeById.keys.toSet();
    final constrained = <String>[
      ...options.fixedNodes.map((constraint) => constraint.nodeId),
      ...options.alignment.vertical.expand((group) => group),
      ...options.alignment.horizontal.expand((group) => group),
      ...options.relativePlacements.expand((constraint) => [constraint.first, constraint.second]),
    ];
    final unknown = constrained.where((id) => !ids.contains(id)).toSet();
    if (unknown.isNotEmpty) throw ArgumentError.value(unknown, 'constraints', 'unknown node IDs');
  }

  void _validateOptions() {
    if (options.maxIterations < 1 || options.sampleSize < 1) {
      throw ArgumentError('maxIterations and sampleSize must be positive');
    }
    if (options.idealEdgeLength <= 0 || options.nodeSeparation <= 0) {
      throw ArgumentError('layout lengths must be positive');
    }
  }
}

final class _WorkingGraph {
  _WorkingGraph(this.graph) : nodeById = graph.nodeById, leaves = List.unmodifiable(graph.leafNodes) {
    adjacency = {for (final node in leaves) node.id: <String>{}};
    for (final edge in graph.edges) {
      final source = representative(edge.source);
      final target = representative(edge.target);
      if (source != target) {
        adjacency[source]!.add(target);
        adjacency[target]!.add(source);
      }
    }
    components = _findComponents();
  }

  final FcoseGraph graph;
  final Map<String, FcoseNode> nodeById;
  final List<FcoseNode> leaves;
  List<FcoseEdge> get edges => graph.edges;
  late final Map<String, Set<String>> adjacency;
  late final List<List<String>> components;
  final Map<String, String> _representatives = {};

  String representative(String id) => _representatives.putIfAbsent(id, () {
    var current = nodeById[id]!;
    while (graph.childrenByParent[current.id]?.isNotEmpty ?? false) {
      current = graph.childrenByParent[current.id]!.first;
    }
    return current.id;
  });

  Map<String, int> distances(String start, Iterable<String> allowed) {
    final allowedSet = allowed.toSet();
    final result = <String, int>{start: 0};
    final queue = Queue<String>()..add(start);
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      for (final next in adjacency[current]!) {
        if (allowedSet.contains(next) && !result.containsKey(next)) {
          result[next] = result[current]! + 1;
          queue.add(next);
        }
      }
    }
    return result;
  }

  List<List<String>> _findComponents() {
    final unseen = adjacency.keys.toSet();
    final result = <List<String>>[];
    while (unseen.isNotEmpty) {
      final first = unseen.first;
      final component = <String>[];
      final queue = Queue<String>()..add(first);
      unseen.remove(first);
      while (queue.isNotEmpty) {
        final current = queue.removeFirst();
        component.add(current);
        for (final next in adjacency[current]!) {
          if (unseen.remove(next)) queue.add(next);
        }
      }
      result.add(component);
    }
    return result;
  }
}

/// Small deterministic PRNG so layouts remain identical on all Dart platforms.
final class _Random {
  _Random(int seed) : _state = seed & 0xffffffff;
  int _state;

  int _next() {
    var value = _state;
    value ^= value << 13;
    value ^= value >>> 17;
    value ^= value << 5;
    _state = value & 0xffffffff;
    return _state;
  }

  double nextDouble() => _next() / 0x100000000;
  int nextInt(int maximum) => _next() % maximum;
}
