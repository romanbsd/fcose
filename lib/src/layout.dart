import 'dart:collection';
import 'dart:math' as math;

import 'compound_graph.dart';
import 'constraint_handler.dart';
import 'constraints.dart';
import 'geometry.dart';
import 'model.dart';
import 'options.dart';
import 'spectral.dart';

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
    final constraintHandler = _constraintHandler;
    if (options.randomize) {
      constraintHandler.transformInitial(positions);
    }
    constraintHandler.enforce(positions);

    var iterations = 0;
    if (options.quality != LayoutQuality.draft) {
      iterations = _runSpringEmbedder(working, positions, constraintHandler);
    }
    if (!_hasConstraints) {
      _packComponents(working, positions);
    }

    final rectangles = working.compounds.rectangles(positions, padding: options.compoundPadding);
    final allPositions = <String, Offset>{
      ...positions,
      for (final node in graph.nodes)
        if (working.compounds.isCompound(node.id)) node.id: rectangles[node.id]!.center,
    };
    return FcoseResult(positions: allPositions, rectangles: rectangles, iterations: iterations);
  }

  Map<String, Offset> _initialPositions(_WorkingGraph graph, _Random random) {
    if (!options.randomize) {
      if (graph.leaves.any((node) => node.position == null)) {
        throw StateError('randomize: false requires an initial position for every leaf node');
      }
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
    return SpectralInitializer(
      sampleSize: options.sampleSize,
      samplingType: options.samplingType,
      nodeSeparation: options.nodeSeparation,
      tolerance: options.powerIterationTolerance,
      seed: random.nextInt(0x7fffffff),
    ).run(component, graph.adjacency).positions;
  }

  int _runSpringEmbedder(_WorkingGraph graph, Map<String, Offset> positions, ConstraintHandler constraintHandler) {
    final forces = <String, Offset>{};
    final fixed = options.fixedNodes.map((constraint) => constraint.nodeId).toSet();
    var coolingFactor = options.initialEnergyOnIncremental;
    var coolingCycle = 0;
    var totalDisplacement = double.infinity;
    var oldTotalDisplacement = 0.0;
    final maxCoolingCycle = options.maxIterations / 100;
    final averageIdealLength = graph.edges.isEmpty
        ? options.idealEdgeLength
        : graph.edges
                  .map((edge) => edge.idealLength ?? options.idealEdgeLength)
                  .reduce((first, second) => first + second) /
              graph.edges.length;
    final totalDisplacementThreshold = 0.03 * averageIdealLength * graph.graph.nodes.length;

    for (var iteration = 0; iteration < options.maxIterations; iteration++) {
      final iterationNumber = iteration + 1;
      if (iterationNumber == options.maxIterations) return iterationNumber;
      if (iterationNumber % 100 == 0) {
        final converged = totalDisplacement < totalDisplacementThreshold;
        final oscillating =
            iterationNumber > options.maxIterations / 3 && (totalDisplacement - oldTotalDisplacement).abs() < 2;
        oldTotalDisplacement = totalDisplacement;
        if (converged || oscillating) return iterationNumber;
        coolingCycle++;
        final adjuster = switch (options.quality) {
          LayoutQuality.draft => coolingCycle.toDouble(),
          LayoutQuality.defaultQuality => coolingCycle / 3,
          LayoutQuality.proof => 1.0,
        };
        final exponent =
            math.log(100 * (options.initialEnergyOnIncremental - options.minTemperature)) / math.log(maxCoolingCycle);
        coolingFactor = math.max(
          options.initialEnergyOnIncremental - math.pow(coolingCycle, exponent) / 100 * adjuster,
          options.minTemperature,
        );
      }
      final rectangles = graph.compounds.rectangles(positions, padding: options.compoundPadding);
      for (final node in graph.graph.nodes) {
        forces[node.id] = Offset.zero;
      }

      // layout-base calculates repulsion only between nodes in the same owner
      // graph. Compound nodes are ordinary siblings at their parent's level.
      for (final siblings in graph.graph.childrenByParent.values) {
        for (var i = 0; i < siblings.length; i++) {
          final first = siblings[i];
          for (var j = i + 1; j < siblings.length; j++) {
            final second = siblings[j];
            final firstRect = rectangles[first.id]!;
            final secondRect = rectangles[second.id]!;
            final firstWeight = graph.compounds.descendantLeaves(first.id).length;
            final secondWeight = graph.compounds.descendantLeaves(second.id).length;
            if (firstRect.overlaps(secondRect)) {
              final childFactor = firstWeight * secondWeight / (firstWeight + secondWeight);
              final separation = firstRect.separationAmountTo(secondRect, buffer: options.idealEdgeLength / 2);
              final force = separation * (-2 * childFactor);
              forces[first.id] = forces[first.id]! + force;
              forces[second.id] = forces[second.id]! - force;
              continue;
            }
            var delta = secondRect.boundaryDisplacementTo(firstRect);
            if (delta.length < 1e-7) {
              delta = firstRect.center - secondRect.center;
            }
            if (delta.length < 1e-7) {
              delta = Offset(1e-3 * (i + 1), 1e-3 * (j + 1));
            }
            // CoSE's FR-grid variant only evaluates nodes in the surrounding
            // range: 2 * (level + 1) * idealEdgeLength. At the root level this
            // excludes non-neighbouring nodes in Mermaid's linear chains.
            final repulsionRange = 2 * options.idealEdgeLength;
            final distanceX =
                (firstRect.center.x - secondRect.center.x).abs() - (firstRect.width + secondRect.width) / 2;
            final distanceY =
                (firstRect.center.y - secondRect.center.y).abs() - (firstRect.height + secondRect.height) / 2;
            if (distanceX > repulsionRange || distanceY > repulsionRange) continue;
            final minimumComponentDistance = averageIdealLength / 10;
            delta = Offset(
              delta.x.abs() < minimumComponentDistance ? delta.x.sign * minimumComponentDistance : delta.x,
              delta.y.abs() < minimumComponentDistance ? delta.y.sign * minimumComponentDistance : delta.y,
            );
            final boundaryDistance = delta.length;
            if (boundaryDistance == 0) continue;
            final magnitude =
                options.nodeRepulsion * firstWeight * secondWeight / (boundaryDistance * boundaryDistance);
            final force = delta.normalized() * magnitude;
            forces[first.id] = forces[first.id]! + force;
            forces[second.id] = forces[second.id]! - force;
          }
        }
      }

      // Hooke springs act on their real endpoints, including compounds.
      for (final edge in graph.edges) {
        final source = edge.source;
        final target = edge.target;
        if (source == target) continue;
        final sourceRect = rectangles[source]!;
        final targetRect = rectangles[target]!;
        var delta = sourceRect.boundaryDisplacementTo(targetRect);
        if (delta.length < 1e-7) continue;
        delta = Offset(
          delta.x.abs() < _minimumSpringComponentLength ? delta.x.sign : delta.x,
          delta.y.abs() < _minimumSpringComponentLength ? delta.y.sign : delta.y,
        );
        final baseIdeal = edge.idealLength ?? options.idealEdgeLength;
        var ideal = baseIdeal;
        if (graph.compounds.ownerOf(source) != graph.compounds.ownerOf(target)) {
          final lca = graph.compounds.lowestCommonOwner(source, target);
          final lcaDepth = lca == null ? 1 : graph.compounds.inclusionDepthOf(lca);
          final nestingDepth =
              graph.compounds.inclusionDepthOf(source) + graph.compounds.inclusionDepthOf(target) - 2 * lcaDepth;
          final sourceInLca = graph.compounds.childInOwner(source, lca);
          final targetInLca = graph.compounds.childInOwner(target, lca);
          ideal += baseIdeal * options.nestingFactor * nestingDepth;
          ideal +=
              graph.compounds.estimatedSizeOf(sourceInLca) +
              graph.compounds.estimatedSizeOf(targetInLca) -
              2 * _layoutBaseSimpleNodeSize;
        }
        final elasticity = edge.elasticity ?? options.edgeElasticity;
        final magnitude = elasticity * (delta.length - ideal);
        final force = delta.normalized() * magnitude;
        forces[source] = forces[source]! + force;
        forces[target] = forces[target]! - force;
      }

      final leafDisplacements = {for (final leaf in graph.leaves) leaf.id: Offset.zero};
      for (final node in graph.graph.nodes) {
        if (fixed.contains(node.id)) continue;
        final position = rectangles[node.id]!.center;
        final owner = graph.compounds.ownerOf(node.id);
        var gravityForce = Offset.zero;
        if (!graph.compounds.isOwnerConnected(owner)) {
          final ownerBounds = graph.compounds.ownerBounds(owner, rectangles);
          final ownerCenter = ownerBounds.center;
          final distance = position - ownerCenter;
          final rangeFactor = owner == null ? options.gravityRange : options.compoundGravityRange;
          final estimatedSize = math.max(ownerBounds.width, ownerBounds.height);
          final nodeRect = rectangles[node.id]!;
          if (distance.x.abs() + nodeRect.width / 2 > estimatedSize * rangeFactor ||
              distance.y.abs() + nodeRect.height / 2 > estimatedSize * rangeFactor) {
            final strength = options.gravity * (owner == null ? 1 : options.compoundGravity);
            gravityForce = (ownerCenter - position) * strength;
          }
        }
        final descendants = graph.compounds.descendantLeaves(node.id).toList();
        final fixedDescendantCount = descendants.where(fixed.contains).length;
        // cose-base assigns weight 100 to each fixed leaf below a compound so
        // forces on the ancestor only gently move its unfixed descendants.
        final movementWeight = fixedDescendantCount == 0 ? descendants.length : fixedDescendantCount * 100;
        var displacement = (forces[node.id]! + gravityForce) * (coolingFactor / movementWeight);
        final displacementLimit = coolingFactor * 100;
        displacement = Offset(
          displacement.x.clamp(-displacementLimit, displacementLimit),
          displacement.y.clamp(-displacementLimit, displacementLimit),
        );
        // CoSENode first accumulates every compound displacement into its
        // descendant leaves; only leaf nodes are moved in the subsequent move
        // phase. Keeping these phases separate also makes every gravity force
        // use the same iteration geometry.
        for (final leaf in descendants) {
          if (!fixed.contains(leaf)) {
            leafDisplacements[leaf] = leafDisplacements[leaf]! + displacement;
          }
        }
      }
      totalDisplacement = 0;
      constraintHandler.constrainDisplacements(positions, leafDisplacements, iteration: iterationNumber);
      for (final entry in leafDisplacements.entries) {
        positions[entry.key] = positions[entry.key]! + entry.value;
        totalDisplacement += entry.value.x.abs() + entry.value.y.abs();
      }
    }
    return options.maxIterations;
  }

  ConstraintHandler get _constraintHandler => ConstraintHandler(
    fixedNodes: options.fixedNodes,
    alignment: options.alignment,
    relativePlacements: options.relativePlacements,
    defaultGap: options.idealEdgeLength,
    seed: options.seed,
  );

  bool get _hasConstraints =>
      options.fixedNodes.isNotEmpty ||
      options.alignment.vertical.isNotEmpty ||
      options.alignment.horizontal.isNotEmpty ||
      options.relativePlacements.isNotEmpty;

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

    final compoundIds = graph.nodes
        .where((node) => graph.childrenByParent[node.id]?.isNotEmpty ?? false)
        .map((node) => node.id)
        .toSet();
    final constrainedCompounds = constrained.where(compoundIds.contains).toSet();
    if (constrainedCompounds.isNotEmpty) {
      throw ArgumentError.value(
        constrainedCompounds,
        'constraints',
        'fCoSE placement constraints apply to simple nodes only',
      );
    }

    for (final axis in RelativePlacementAxis.values) {
      final edges = options.relativePlacements.where((constraint) => constraint.axis == axis);
      final outgoing = <String, Set<String>>{};
      final indegree = <String, int>{};
      for (final edge in edges) {
        outgoing.putIfAbsent(edge.first, () => {}).add(edge.second);
        indegree.putIfAbsent(edge.first, () => 0);
        indegree[edge.second] = (indegree[edge.second] ?? 0) + 1;
      }
      final queue = Queue<String>()..addAll(indegree.keys.where((id) => indegree[id] == 0));
      var visited = 0;
      while (queue.isNotEmpty) {
        final current = queue.removeFirst();
        visited++;
        for (final next in outgoing[current] ?? const {}) {
          indegree[next] = indegree[next]! - 1;
          if (indegree[next] == 0) queue.add(next);
        }
      }
      if (visited != indegree.length) {
        throw ArgumentError.value(axis, 'relativePlacements', 'constraints must form a DAG');
      }
    }

    final fixed = {for (final item in options.fixedNodes) item.nodeId: item.position};
    for (final constraint in options.relativePlacements) {
      final first = fixed[constraint.first];
      final second = fixed[constraint.second];
      if (first == null || second == null) continue;
      final actual = constraint.axis == RelativePlacementAxis.horizontal ? second.x - first.x : second.y - first.y;
      if (actual < (constraint.gap ?? options.idealEdgeLength)) {
        throw ArgumentError.value(constraint, 'relativePlacements', 'fixed node positions contradict the required gap');
      }
    }
  }

  void _validateOptions() {
    if (options.maxIterations < 1 || options.sampleSize < 1) {
      throw ArgumentError('maxIterations and sampleSize must be positive');
    }
    if (options.idealEdgeLength <= 0 || options.nodeSeparation <= 0) {
      throw ArgumentError('layout lengths must be positive');
    }
    if (options.powerIterationTolerance <= 0) {
      throw ArgumentError.value(options.powerIterationTolerance, 'powerIterationTolerance', 'must be positive');
    }
    if (options.minTemperature <= 0 ||
        options.initialEnergyOnIncremental <= options.minTemperature ||
        options.initialEnergyOnIncremental > 1) {
      throw ArgumentError('cooling energy must satisfy 0 < minTemperature < initialEnergyOnIncremental <= 1');
    }
  }
}

/// layout-base `LayoutConstants.SIMPLE_NODE_SIZE`, in logical pixels.
const _layoutBaseSimpleNodeSize = 40.0;

/// `LEdge.updateLength()` snaps sub-pixel clipped spring components to their
/// sign before calculating length, avoiding unstable near-axis projections.
const _minimumSpringComponentLength = 1.0;

final class _WorkingGraph {
  _WorkingGraph(this.graph)
    : nodeById = graph.nodeById,
      leaves = List.unmodifiable(graph.leafNodes),
      compounds = CompoundGraphManager(graph) {
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
  final CompoundGraphManager compounds;
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
