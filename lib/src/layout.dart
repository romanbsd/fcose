import 'dart:collection';
import 'dart:math' as math;

import 'compound_graph.dart';
import 'constraint_handler.dart';
import 'constraints.dart';
import 'geometry.dart';
import 'model.dart';
import 'options.dart';
import 'packing.dart';
import 'pose_packing.dart';
import 'random.dart';
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
/// objects, keeping the layout engine framework-independent.
final class FcoseLayout {
  const FcoseLayout({this.options = const FcoseOptions()});

  final FcoseOptions options;

  FcoseResult run(FcoseGraph graph) {
    _validateOptions();
    _validateConstraints(graph);
    if (graph.nodes.isEmpty) {
      return FcoseResult(positions: const {}, rectangles: const {}, iterations: 0);
    }

    final random = Xorshift32(options.seed);
    var working = _WorkingGraph(graph);
    final originalComponentCenters = _componentCenters(working, {
      for (final leaf in working.leaves) leaf.id: leaf.position ?? Offset.zero,
    });
    var positions = _initialPositions(working, random);
    final constraintHandler = _constraintHandler;
    if (options.randomize) {
      constraintHandler.transformInitial(positions);
    }
    constraintHandler.enforce(positions);

    if (_shouldTileFlatZeroDegreeNodes(working)) {
      _tileFlatZeroDegreeNodes(working, positions);
      final rectangles = working.compounds.rectangles(positions, padding: options.compoundPadding);
      final effectiveMax = math.max(options.maxIterations, _minimumIterationsPerNode);
      return FcoseResult(
        positions: positions,
        rectangles: rectangles,
        iterations: options.quality == LayoutQuality.draft ? 0 : math.min(effectiveMax, _convergenceCheckPeriod),
      );
    }

    final tiling = _prepareTiling(graph, positions);
    if (tiling != null) {
      working = _WorkingGraph(tiling.graph);
      positions = tiling.positions;
    }

    var iterations = 0;
    if (options.quality != LayoutQuality.draft) {
      iterations = _runSpringEmbedder(working, positions, constraintHandler, random);
    }
    if (!_hasConstraints && tiling == null) {
      if (options.packComponents && working.packingComponents.length > 1) {
        _relocateComponentsToOriginalCenters(working, positions, originalComponentCenters);
      }
      _packComponents(working, positions);
    }

    final rectangles = working.compounds.rectangles(positions, padding: options.compoundPadding);
    final allPositions = <String, Offset>{
      ...positions,
      for (final node in working.graph.nodes)
        if (working.compounds.isCompound(node.id)) node.id: rectangles[node.id]!.center,
    };
    final result = FcoseResult(positions: allPositions, rectangles: rectangles, iterations: iterations);
    return tiling == null ? result : _restoreTiling(graph, tiling, result);
  }

  Map<String, Offset> _initialPositions(_WorkingGraph graph, Xorshift32 random) {
    if (!options.randomize) {
      if (graph.leaves.any((node) => node.position == null)) {
        throw StateError('randomize: false requires an initial position for every leaf node');
      }
      return {for (final node in graph.leaves) node.id: node.position!};
    }
    return _spectralPositions(graph, random);
  }

  /// Landmark graph-distance embedding corresponding to fCoSE's spectral phase.
  Map<String, Offset> _spectralPositions(_WorkingGraph graph, Xorshift32 random) {
    final spectral = graph.spectralGraph;
    final transformed =
        SpectralInitializer(
              sampleSize: options.sampleSize,
              samplingType: options.samplingType,
              nodeSeparation: options.nodeSeparation,
              tolerance: options.powerIterationTolerance,
              seed: random.nextUint32() % 0x7fffffff,
            )
            .run(
              spectral.nodes,
              spectral.adjacency,
              widths: {for (final leaf in graph.leaves) leaf.id: leaf.width},
              initialPositions: {for (final leaf in graph.leaves) leaf.id: ?leaf.position},
              idealEdgeLength: options.idealEdgeLength,
            )
            .positions;
    return {for (final leaf in graph.leaves) leaf.id: transformed[leaf.id]!};
  }

  ({FcoseEdge edge, double idealLength, double elasticity}) _springData(_WorkingGraph graph, FcoseEdge edge) {
    final baseIdeal = edge.idealLength ?? options.idealEdgeLength;
    var idealLength = baseIdeal;
    if (graph.compounds.ownerOf(edge.source) != graph.compounds.ownerOf(edge.target)) {
      final lca = graph.compounds.lowestCommonOwner(edge.source, edge.target);
      final lcaDepth = lca == null ? 1 : graph.compounds.inclusionDepthOf(lca);
      final nestingDepth =
          graph.compounds.inclusionDepthOf(edge.source) + graph.compounds.inclusionDepthOf(edge.target) - 2 * lcaDepth;
      final sourceInLca = graph.compounds.childInOwner(edge.source, lca);
      final targetInLca = graph.compounds.childInOwner(edge.target, lca);
      idealLength += baseIdeal * options.nestingFactor * nestingDepth;
      idealLength +=
          graph.compounds.estimatedSizeOf(sourceInLca) +
          graph.compounds.estimatedSizeOf(targetInLca) -
          2 * _layoutBaseSimpleNodeSize;
    }
    return (edge: edge, idealLength: idealLength, elasticity: edge.elasticity ?? options.edgeElasticity);
  }

  int _runSpringEmbedder(
    _WorkingGraph graph,
    Map<String, Offset> positions,
    ConstraintHandler constraintHandler,
    Xorshift32 random,
  ) {
    if (_hasConstraints) {
      return _runSpringPhase(graph, positions, constraintHandler).iterations;
    }
    final reduction = _TreeReduction.create(graph, positions);
    if (reduction.rounds.isEmpty) {
      return _runSpringPhase(graph, positions, constraintHandler).iterations;
    }

    final activeNodeIds = reduction.coreNodeIds.toSet();
    var activeGraph = _WorkingGraph(reduction.activeGraph(activeNodeIds));
    var phase = _runSpringPhase(activeGraph, positions, constraintHandler);
    var iterations = phase.iterations;
    final coreIterationLimit = phase.iterationLimit;
    final coreOldTotalDisplacement = phase.oldTotalDisplacement;
    final treePlacementEdgeLength = graph.edges.isEmpty
        ? options.idealEdgeLength
        : graph.edges
                  .map((edge) => edge.idealLength ?? options.idealEdgeLength)
                  .reduce((first, second) => first + second) /
              graph.edges.length;

    for (final round in reduction.rounds.reversed) {
      _restorePrunedRound(round, activeGraph, positions, random, treePlacementEdgeLength);
      activeNodeIds.addAll(round.map((pruned) => pruned.nodeId));
      activeGraph = _WorkingGraph(reduction.activeGraph(activeNodeIds));
      phase = _runSpringPhase(
        activeGraph,
        positions,
        constraintHandler,
        forcedTicks: _treeGrowthStepIterations,
        fixedCoolingFactor: options.randomize
            ? options.initialEnergyOnIncremental
            : options.initialEnergyOnIncremental / 2,
        terminateBeforeLimit: false,
        checkConvergence: false,
      );
      iterations += phase.iterations;
    }

    if (phase.totalDisplacement < phase.totalDisplacementThreshold) {
      return iterations;
    }
    final postGrowth = _runSpringPhase(
      activeGraph,
      positions,
      constraintHandler,
      forcedTicks: _postGrowthIterations,
      fixedCoolingFactor: options.randomize
          ? options.initialEnergyOnIncremental
          : options.initialEnergyOnIncremental / 2,
      terminateBeforeLimit: false,
      initialTotalDisplacement: phase.totalDisplacement,
      checkConvergenceEveryTick: true,
      linearCooling: true,
      convergenceReturnsPreviousTick: true,
      initialOldTotalDisplacement: coreOldTotalDisplacement,
      oscillationIterationOffset: iterations,
      oscillationIterationLimit: coreIterationLimit,
    );
    return iterations + postGrowth.iterations;
  }

  _SpringPhaseResult _runSpringPhase(
    _WorkingGraph graph,
    Map<String, Offset> positions,
    ConstraintHandler constraintHandler, {
    int? forcedTicks,
    double? fixedCoolingFactor,
    bool terminateBeforeLimit = true,
    bool checkConvergence = true,
    double? initialTotalDisplacement,
    bool checkConvergenceEveryTick = false,
    bool linearCooling = false,
    bool convergenceReturnsPreviousTick = false,
    double initialOldTotalDisplacement = 0,
    int oscillationIterationOffset = 0,
    int? oscillationIterationLimit,
  }) {
    final fixed = options.fixedNodes.map((constraint) => constraint.nodeId).toSet();
    final layoutNodes = graph.compounds.layoutOrder;
    final compoundIds = {
      for (final node in layoutNodes)
        if (graph.compounds.isCompound(node.id)) node.id,
    };
    final descendantsByNode = {for (final node in layoutNodes) node.id: graph.compounds.descendantLeaves(node.id)};
    final movementWeights = <String, int>{};
    for (final node in layoutNodes) {
      final descendants = descendantsByNode[node.id]!;
      final fixedDescendantCount = descendants.where(fixed.contains).length;
      movementWeights[node.id] = fixedDescendantCount == 0 ? descendants.length : fixedDescendantCount * 100;
    }
    final gravityByOwner = <String?, ({double range, double estimatedSize, double strength})>{};
    final processedOwners = <String?>{};
    for (final node in layoutNodes) {
      final owner = graph.compounds.ownerOf(node.id);
      if (!processedOwners.add(owner) || graph.compounds.isOwnerConnected(owner)) {
        continue;
      }
      gravityByOwner[owner] = (
        range: owner == null ? options.gravityRange : options.compoundGravityRange,
        estimatedSize: graph.compounds.estimatedSizeOfOwner(owner),
        strength: options.gravity * (owner == null ? 1 : options.compoundGravity),
      );
    }
    final springs = [for (final edge in graph.edges) _springData(graph, edge)];
    final forces = {for (final node in graph.graph.nodes) node.id: Offset.zero};
    final leafDisplacements = {for (final leaf in graph.leaves) leaf.id: Offset.zero};
    final ownerBounds = <String?, Rect>{};
    var coolingFactor = fixedCoolingFactor ?? options.initialEnergyOnIncremental;
    var coolingCycle = 0;
    var totalDisplacement = initialTotalDisplacement ?? double.infinity;
    var oldTotalDisplacement = initialOldTotalDisplacement;
    final maxIterations =
        forcedTicks ?? math.max(options.maxIterations, graph.graph.nodes.length * _minimumIterationsPerNode);
    final maxCoolingCycle = maxIterations / _convergenceCheckPeriod;
    final coolingExponent = maxIterations <= _convergenceCheckPeriod
        ? 0.0
        : math.log(100 * (options.initialEnergyOnIncremental - options.minTemperature)) / math.log(maxCoolingCycle);
    var repulsionPairs = <(FcoseNode, FcoseNode)>[];
    final averageIdealLength = graph.edges.isEmpty
        ? options.idealEdgeLength
        : graph.edges
                  .map((edge) => edge.idealLength ?? options.idealEdgeLength)
                  .reduce((first, second) => first + second) /
              graph.edges.length;
    final totalDisplacementThreshold = 0.03 * averageIdealLength * graph.graph.nodes.length;

    for (var iteration = 0; iteration < maxIterations; iteration++) {
      final iterationNumber = iteration + 1;
      if (linearCooling) {
        coolingFactor =
            (fixedCoolingFactor ?? options.initialEnergyOnIncremental) *
            ((_postGrowthIterations - iteration) / _postGrowthIterations);
      }
      // cose-base's tick() increments totalIterations, then terminates at the
      // limit before calculating that tick's forces.
      if (terminateBeforeLimit && iterationNumber == maxIterations) {
        return _SpringPhaseResult(
          iterationNumber,
          totalDisplacement,
          totalDisplacementThreshold,
          oldTotalDisplacement,
          maxIterations,
        );
      }
      if (checkConvergence && (checkConvergenceEveryTick || iterationNumber % _convergenceCheckPeriod == 0)) {
        final converged = totalDisplacement < totalDisplacementThreshold;
        final oscillating =
            oscillationIterationOffset + iterationNumber > (oscillationIterationLimit ?? maxIterations) / 3 &&
            (totalDisplacement - oldTotalDisplacement).abs() < 2;
        oldTotalDisplacement = totalDisplacement;
        if (converged || oscillating) {
          return _SpringPhaseResult(
            convergenceReturnsPreviousTick ? iteration : iterationNumber,
            totalDisplacement,
            totalDisplacementThreshold,
            oldTotalDisplacement,
            maxIterations,
          );
        }
        coolingCycle++;
        if (fixedCoolingFactor == null) {
          final adjuster = switch (options.quality) {
            LayoutQuality.draft || LayoutQuality.defaultQuality => coolingCycle.toDouble(),
            LayoutQuality.proof => 1.0,
          };
          coolingFactor = math.max(
            options.initialEnergyOnIncremental - math.pow(coolingCycle, coolingExponent) / 100 * adjuster,
            options.minTemperature,
          );
        }
      }
      final rectangles = graph.compounds.rectangles(positions, padding: options.compoundPadding);
      for (final node in graph.graph.nodes) {
        forces[node.id] = Offset.zero;
      }
      for (final leaf in graph.leaves) {
        leafDisplacements[leaf.id] = Offset.zero;
      }
      ownerBounds.clear();

      if (iterationNumber % _repulsionGridRefreshPeriod == 1) {
        repulsionPairs = _refreshRepulsionPairs(graph, rectangles, 2 * averageIdealLength);
      }
      for (final (first, second) in repulsionPairs) {
        final firstRect = rectangles[first.id]!;
        final secondRect = rectangles[second.id]!;
        final firstWeight = descendantsByNode[first.id]!.length;
        final secondWeight = descendantsByNode[second.id]!.length;
        if (firstRect.overlaps(secondRect)) {
          final childFactor = firstWeight * secondWeight / (firstWeight + secondWeight);
          final separation = firstRect.separationAmountTo(secondRect, buffer: averageIdealLength / 2);
          final force = separation * (-2 * childFactor);
          forces[first.id] = forces[first.id]! + force;
          forces[second.id] = forces[second.id]! - force;
          continue;
        }
        var delta = firstRect.boundaryDisplacementTo(secondRect);
        final minimumComponentDistance = averageIdealLength / 10;
        delta = Offset(
          delta.x.abs() < minimumComponentDistance ? delta.x.sign * minimumComponentDistance : delta.x,
          delta.y.abs() < minimumComponentDistance ? delta.y.sign * minimumComponentDistance : delta.y,
        );
        final boundaryDistance = delta.length;
        if (boundaryDistance == 0) continue;
        final pairRepulsion =
            (first.nodeRepulsion ?? options.nodeRepulsion) / 2 + (second.nodeRepulsion ?? options.nodeRepulsion) / 2;
        final magnitude = pairRepulsion * firstWeight * secondWeight / (boundaryDistance * boundaryDistance);
        final force = delta.normalized() * magnitude;
        forces[first.id] = forces[first.id]! - force;
        forces[second.id] = forces[second.id]! + force;
      }

      // Hooke springs act on their real endpoints, including compounds.
      for (final (:edge, :idealLength, :elasticity) in springs) {
        final source = edge.source;
        final target = edge.target;
        final sourceRect = rectangles[source]!;
        final targetRect = rectangles[target]!;
        var delta = sourceRect.boundaryDisplacementTo(targetRect);
        if (delta.length < 1e-7) continue;
        delta = Offset(
          delta.x.abs() < _minimumSpringComponentLength ? delta.x.sign : delta.x,
          delta.y.abs() < _minimumSpringComponentLength ? delta.y.sign : delta.y,
        );
        final magnitude = elasticity * (delta.length - idealLength);
        final force = delta.normalized() * magnitude;
        forces[source] = forces[source]! + force;
        forces[target] = forces[target]! - force;
      }

      for (final node in layoutNodes) {
        if (fixed.contains(node.id)) continue;
        final position = rectangles[node.id]!.center;
        final owner = graph.compounds.ownerOf(node.id);
        var gravityForce = Offset.zero;
        final gravity = gravityByOwner[owner];
        if (gravity != null) {
          final bounds = ownerBounds.putIfAbsent(owner, () => graph.compounds.ownerBounds(owner, rectangles));
          final ownerCenter = bounds.center;
          final distance = position - ownerCenter;
          final nodeRect = rectangles[node.id]!;
          if (distance.x.abs() + nodeRect.width / 2 > gravity.estimatedSize * gravity.range ||
              distance.y.abs() + nodeRect.height / 2 > gravity.estimatedSize * gravity.range) {
            gravityForce = (ownerCenter - position) * gravity.strength;
          }
        }
        final descendants = descendantsByNode[node.id]!;
        // cose-base assigns weight 100 to each fixed leaf below a compound so
        // forces on the ancestor only gently move its unfixed descendants.
        var displacement = (forces[node.id]! + gravityForce) * (coolingFactor / movementWeights[node.id]!);
        if (!compoundIds.contains(node.id)) {
          displacement += leafDisplacements[node.id]!;
        }
        final displacementLimit = coolingFactor * 100;
        displacement = Offset(
          displacement.x.clamp(-displacementLimit, displacementLimit),
          displacement.y.clamp(-displacementLimit, displacementLimit),
        );
        // CoSENode visits owner graphs in LGraphManager order. Each compound
        // first contributes to its descendant leaves; when a leaf is reached,
        // its accumulated ancestor and local displacement are clamped together.
        if (compoundIds.contains(node.id)) {
          for (final leaf in descendants) {
            if (!fixed.contains(leaf)) {
              leafDisplacements[leaf] = leafDisplacements[leaf]! + displacement;
            }
          }
        } else {
          leafDisplacements[node.id] = displacement;
        }
      }
      totalDisplacement = 0;
      constraintHandler.constrainDisplacements(positions, leafDisplacements, iteration: iterationNumber);
      for (final entry in leafDisplacements.entries) {
        positions[entry.key] = positions[entry.key]! + entry.value;
        totalDisplacement += entry.value.x.abs() + entry.value.y.abs();
      }
    }
    return _SpringPhaseResult(
      maxIterations,
      totalDisplacement,
      totalDisplacementThreshold,
      oldTotalDisplacement,
      maxIterations,
    );
  }

  void _restorePrunedRound(
    List<_PrunedNode> round,
    _WorkingGraph activeGraph,
    Map<String, Offset> positions,
    Xorshift32 random,
    double treePlacementEdgeLength,
  ) {
    if (!options.randomize) {
      for (final pruned in round) {
        positions[pruned.node.id] = positions[pruned.otherId]! + pruned.relativeOffset;
      }
      return;
    }

    final rectangles = activeGraph.compounds.rectangles(positions, padding: options.compoundPadding);
    final nodes = activeGraph.compounds.layoutOrder;
    final rootNodes = activeGraph.graph.childrenByParent[null]!;
    var rootBounds = rectangles[rootNodes.first.id]!;
    for (final node in rootNodes.skip(1)) {
      rootBounds = rootBounds.union(rectangles[node.id]!);
    }
    rootBounds = rootBounds.inflate(_layoutBaseGraphMargin);
    final repulsionRange = 2 * treePlacementEdgeLength;
    final sizeX = math.max(1, (rootBounds.width / repulsionRange).ceil());
    final sizeY = math.max(1, (rootBounds.height / repulsionRange).ceil());
    final grid = List.generate(sizeX, (_) => List<int>.filled(sizeY, 0));
    final coordinates = <String, ({int startX, int finishX, int startY, int finishY})>{};
    for (final node in nodes) {
      final rectangle = rectangles[node.id]!;
      final coordinate = (
        startX: ((rectangle.left - rootBounds.left) / repulsionRange).floor(),
        finishX: ((rectangle.right - rootBounds.left) / repulsionRange).floor(),
        startY: ((rectangle.top - rootBounds.top) / repulsionRange).floor(),
        finishY: ((rectangle.bottom - rootBounds.top) / repulsionRange).floor(),
      );
      coordinates[node.id] = coordinate;
      for (var x = coordinate.startX; x <= coordinate.finishX; x++) {
        for (var y = coordinate.startY; y <= coordinate.finishY; y++) {
          grid[x][y]++;
        }
      }
    }

    for (final pruned in round) {
      final connector = rectangles[pruned.otherId]!;
      final coordinate = coordinates[pruned.otherId]!;
      final regions = List<int>.filled(4, 0);
      if (coordinate.startY > 0) {
        for (var x = coordinate.startX; x <= coordinate.finishX; x++) {
          regions[0] += grid[x][coordinate.startY - 1] + grid[x][coordinate.startY] - 1;
        }
      }
      if (coordinate.finishX < sizeX - 1) {
        for (var y = coordinate.startY; y <= coordinate.finishY; y++) {
          regions[1] += grid[coordinate.finishX + 1][y] + grid[coordinate.finishX][y] - 1;
        }
      }
      if (coordinate.finishY < sizeY - 1) {
        for (var x = coordinate.startX; x <= coordinate.finishX; x++) {
          regions[2] += grid[x][coordinate.finishY + 1] + grid[x][coordinate.finishY] - 1;
        }
      }
      if (coordinate.startX > 0) {
        for (var y = coordinate.startY; y <= coordinate.finishY; y++) {
          regions[3] += grid[coordinate.startX - 1][y] + grid[coordinate.startX][y] - 1;
        }
      }
      final direction = _sparseTreeDirection(regions, random);
      positions[pruned.node.id] = switch (direction) {
        0 => Offset(connector.center.x, connector.top - treePlacementEdgeLength - pruned.node.height / 2),
        1 => Offset(connector.right + treePlacementEdgeLength + pruned.node.width / 2, connector.center.y),
        2 => Offset(connector.center.x, connector.bottom + treePlacementEdgeLength + pruned.node.height / 2),
        _ => Offset(connector.left - treePlacementEdgeLength - pruned.node.width / 2, connector.center.y),
      };
    }
  }

  int _sparseTreeDirection(List<int> regions, Xorshift32 random) {
    final minimum = regions.reduce(math.min);
    final minima = [
      for (var index = 0; index < regions.length; index++)
        if (regions[index] == minimum) index,
    ];
    if (minimum != 0) return minima.first;
    return switch (minima) {
      [0, 1, 2] => 1,
      [0, 1, 3] => 0,
      [0, 2, 3] => 3,
      [1, 2, 3] => 2,
      [final first, final second] => random.nextInt(2) == 0 ? first : second,
      [0, 1, 2, 3] => random.nextInt(4),
      _ => minima.first,
    };
  }

  List<(FcoseNode, FcoseNode)> _refreshRepulsionPairs(
    _WorkingGraph graph,
    Map<String, Rect> rectangles,
    double repulsionRange,
  ) {
    final nodes = graph.compounds.layoutOrder;
    final rootNodes = graph.graph.childrenByParent[null]!;
    var rootBounds = rectangles[rootNodes.first.id]!;
    for (final node in rootNodes.skip(1)) {
      rootBounds = rootBounds.union(rectangles[node.id]!);
    }
    rootBounds = rootBounds.inflate(_layoutBaseGraphMargin);
    final sizeX = math.max(1, (rootBounds.width / repulsionRange).ceil());
    final sizeY = math.max(1, (rootBounds.height / repulsionRange).ceil());
    final grid = List.generate(sizeX, (_) => List.generate(sizeY, (_) => <FcoseNode>[]));
    final coordinates = <String, ({int startX, int finishX, int startY, int finishY})>{};

    for (final node in nodes) {
      final rectangle = rectangles[node.id]!;
      final startX = ((rectangle.left - rootBounds.left) / repulsionRange).floor();
      final finishX = ((rectangle.right - rootBounds.left) / repulsionRange).floor();
      final startY = ((rectangle.top - rootBounds.top) / repulsionRange).floor();
      final finishY = ((rectangle.bottom - rootBounds.top) / repulsionRange).floor();
      coordinates[node.id] = (startX: startX, finishX: finishX, startY: startY, finishY: finishY);
      for (var x = startX; x <= finishX; x++) {
        for (var y = startY; y <= finishY; y++) {
          grid[x][y].add(node);
        }
      }
    }

    final processed = <String>{};
    final pairs = <(FcoseNode, FcoseNode)>[];
    for (final first in nodes) {
      final coordinate = coordinates[first.id]!;
      final surrounding = <String>{};
      for (var x = coordinate.startX - 1; x < coordinate.finishX + 2; x++) {
        for (var y = coordinate.startY - 1; y < coordinate.finishY + 2; y++) {
          if (x < 0 || y < 0 || x >= sizeX || y >= sizeY) continue;
          for (final second in grid[x][y]) {
            if (first.id == second.id ||
                graph.compounds.ownerOf(first.id) != graph.compounds.ownerOf(second.id) ||
                processed.contains(second.id) ||
                !surrounding.add(second.id)) {
              continue;
            }
            final firstRect = rectangles[first.id]!;
            final secondRect = rectangles[second.id]!;
            final distanceX =
                (firstRect.center.x - secondRect.center.x).abs() - (firstRect.width + secondRect.width) / 2;
            final distanceY =
                (firstRect.center.y - secondRect.center.y).abs() - (firstRect.height + secondRect.height) / 2;
            if (distanceX <= repulsionRange && distanceY <= repulsionRange) {
              pairs.add((first, second));
            }
          }
        }
      }
      processed.add(first.id);
    }
    return pairs;
  }

  bool _shouldTileFlatZeroDegreeNodes(_WorkingGraph graph) =>
      options.tile &&
      !_hasConstraints &&
      graph.edges.isEmpty &&
      graph.graph.nodes.length > 1 &&
      graph.graph.nodes.length == graph.leaves.length;

  void _tileFlatZeroDegreeNodes(_WorkingGraph graph, Map<String, Offset> positions) {
    // cytoscape-fcose relocates every unconstrained component after CoSE so
    // that its geometry bounding-box center remains at the pre-layout center.
    // This differs from tileNodes(), which organizes rows around the average
    // of the input node centers.
    final originalBoundsCenter = _leafBounds(graph.leaves, positions).center;
    final organization = _tileNodes(graph.leaves, positions);
    positions.addAll(organization.positions);

    final tiledBoundsCenter = _leafBounds(graph.leaves, positions).center;
    final relocation = originalBoundsCenter - tiledBoundsCenter;
    for (final node in graph.leaves) {
      positions[node.id] = positions[node.id]! + relocation;
    }
  }

  _TiledOrganization _tileNodes(
    List<FcoseNode> members,
    Map<String, Offset> positions, {
    double horizontalInset = 0,
    double verticalInset = 0,
  }) {
    final indexed = members.indexed.map((entry) => (index: entry.$1, node: entry.$2)).toList()
      ..sort((first, second) {
        final firstArea = first.node.width * first.node.height;
        final secondArea = second.node.width * second.node.height;
        final areaOrder = secondArea.compareTo(firstArea);
        return areaOrder == 0 ? first.index.compareTo(second.index) : areaOrder;
      });
    final nodes = [for (final entry in indexed) entry.node];
    var centerX = 0.0;
    var centerY = 0.0;
    for (final node in nodes) {
      final position = positions[node.id]!;
      centerX += position.x;
      centerY += position.y;
    }
    final center = Offset(centerX / nodes.length, centerY / nodes.length);
    final rows = <List<FcoseNode>>[];
    final rowWidths = <double>[];
    final rowHeights = <double>[];
    var width = horizontalInset * 2;
    var height = verticalInset * 2;

    int shortestRow() {
      var result = 0;
      for (var index = 1; index < rowWidths.length; index++) {
        if (rowWidths[index] < rowWidths[result]) result = index;
      }
      return result;
    }

    bool canAddHorizontal(FcoseNode node) {
      final shortest = shortestRow();
      final minimumWidth = rowWidths[shortest];
      if (minimumWidth + options.tilingPaddingHorizontal + node.width <= width) return true;
      var heightDifference = 0.0;
      if (rowHeights[shortest] < node.height && shortest > 0) {
        heightDifference = node.height + options.tilingPaddingVertical - rowHeights[shortest];
      }
      var addToRowRatio = width - minimumWidth >= node.width + options.tilingPaddingHorizontal
          ? (height + heightDifference) / (minimumWidth + node.width + options.tilingPaddingHorizontal)
          : (height + heightDifference) / width;
      final newRowHeight = node.height + options.tilingPaddingVertical;
      var addNewRowRatio = (height + newRowHeight) / (width < node.width ? node.width : width);
      if (addNewRowRatio < 1) addNewRowRatio = 1 / addNewRowRatio;
      if (addToRowRatio < 1) addToRowRatio = 1 / addToRowRatio;
      return addToRowRatio < addNewRowRatio;
    }

    void insert(FcoseNode node, int rowIndex) {
      if (rowIndex == rows.length) {
        rows.add([]);
        rowWidths.add(horizontalInset * 2);
        rowHeights.add(0);
      }
      var newWidth = rowWidths[rowIndex] + node.width;
      if (rows[rowIndex].isNotEmpty) newWidth += options.tilingPaddingHorizontal;
      rowWidths[rowIndex] = newWidth;
      width = math.max(width, newWidth);
      final newHeight = node.height + (rowIndex > 0 ? options.tilingPaddingVertical : 0);
      if (newHeight > rowHeights[rowIndex]) {
        height += newHeight - rowHeights[rowIndex];
        rowHeights[rowIndex] = newHeight;
      }
      rows[rowIndex].add(node);
    }

    for (final node in nodes) {
      if (rows.isEmpty) {
        insert(node, 0);
      } else if (canAddHorizontal(node)) {
        insert(node, shortestRow());
      } else {
        insert(node, rows.length);
      }
    }

    final tiledPositions = <String, Offset>{};
    final left = center.x - width / 2 + horizontalInset;
    var top = center.y - height / 2 + verticalInset;
    for (final row in rows) {
      var x = left;
      var maximumHeight = 0.0;
      for (final node in row) {
        tiledPositions[node.id] = Offset(x + node.width / 2, top + node.height / 2);
        x += node.width + options.tilingPaddingHorizontal;
        maximumHeight = math.max(maximumHeight, node.height);
      }
      top += maximumHeight + options.tilingPaddingVertical;
    }
    return _TiledOrganization(positions: tiledPositions, center: center, width: width, height: height);
  }

  _TilingPlan? _prepareTiling(FcoseGraph graph, Map<String, Offset> initialPositions) {
    if (!options.tile || options.quality == LayoutQuality.draft || _hasConstraints) return null;

    final directDegree = {for (final node in graph.nodes) node.id: 0};
    for (final edge in graph.edges) {
      if (edge.source == edge.target) continue;
      directDegree[edge.source] = directDegree[edge.source]! + 1;
      directDegree[edge.target] = directDegree[edge.target]! + 1;
    }

    final tiledCompounds = <String, bool>{};
    bool isTiledCompound(String id) {
      final cached = tiledCompounds[id];
      if (cached != null) return cached;
      final children = graph.childrenByParent[id];
      if (children == null || children.isEmpty) return tiledCompounds[id] = false;
      for (final child in children) {
        if (directDegree[child.id]! > 0) return tiledCompounds[id] = false;
        if (graph.childrenByParent[child.id]?.isNotEmpty ?? false) {
          if (!isTiledCompound(child.id)) return tiledCompounds[id] = false;
        }
      }
      return tiledCompounds[id] = true;
    }

    for (final node in graph.nodes) {
      isTiledCompound(node.id);
    }
    final tiledIds = tiledCompounds.entries.where((entry) => entry.value).map((entry) => entry.key).toSet();

    final compoundOrder = <String>[];
    void visitCompounds(String? ownerId) {
      for (final child in graph.childrenByParent[ownerId] ?? const []) {
        if (graph.childrenByParent[child.id]?.isNotEmpty ?? false) {
          visitCompounds(child.id);
          if (tiledIds.contains(child.id)) compoundOrder.add(child.id);
        }
      }
    }

    visitCompounds(null);
    final nodesById = Map<String, FcoseNode>.of(graph.nodeById);
    final positions = Map<String, Offset>.of(initialPositions);
    final groups = <_TiledGroup>[];

    for (final compoundId in compoundOrder) {
      final original = graph.nodeById[compoundId]!;
      final members = [for (final child in graph.childrenByParent[compoundId]!) nodesById[child.id]!];
      final organization = _tileNodes(
        members,
        positions,
        horizontalInset: options.compoundPadding,
        verticalInset: options.compoundPadding,
      );
      final proxy = _tileProxy(original, organization);
      nodesById[compoundId] = proxy.node;
      positions[compoundId] = proxy.node.position!;
      groups.add(
        _TiledGroup(
          proxyId: compoundId,
          members: members,
          organization: organization,
          contentOffset: proxy.contentOffset,
          isDummy: false,
        ),
      );
    }

    final subtreeDegrees = <String, int>{};
    int degreeWithChildren(String id) => subtreeDegrees.putIfAbsent(
      id,
      () =>
          directDegree[id]! +
          (graph.childrenByParent[id] ?? const []).fold(0, (sum, child) => sum + degreeWithChildren(child.id)),
    );
    final zeroDegreeByOwner = <String?, List<FcoseNode>>{};
    for (final node in CompoundGraphManager(graph).layoutOrder) {
      if (degreeWithChildren(node.id) != 0 || (node.parentId != null && tiledIds.contains(node.parentId))) continue;
      (zeroDegreeByOwner[node.parentId] ??= []).add(nodesById[node.id]!);
    }

    final dummyNodes = <FcoseNode>[];
    final zeroDegreeMembers = <String>{};
    Offset? originalBoundsCenter;
    var collisionIndex = 1;
    for (final entry in zeroDegreeByOwner.entries) {
      if (entry.value.length < 2) continue;
      var dummyId = 'DummyCompound_${entry.key ?? 'undefined'}';
      while (graph.nodeById.containsKey(dummyId) || dummyNodes.any((node) => node.id == dummyId)) {
        dummyId = 'DummyCompound_${entry.key ?? 'undefined'}_${collisionIndex++}';
      }
      final inset = entry.key == null ? 0.0 : options.compoundPadding;
      final organization = _tileNodes(entry.value, positions, horizontalInset: inset, verticalInset: inset);
      final dummy = FcoseNode(
        id: dummyId,
        parentId: entry.key,
        width: organization.width,
        height: organization.height,
        position: organization.center,
      );
      dummyNodes.add(dummy);
      positions[dummyId] = organization.center;
      zeroDegreeMembers.addAll(entry.value.map((node) => node.id));
      groups.add(
        _TiledGroup(
          proxyId: dummyId,
          members: entry.value,
          organization: organization,
          contentOffset: Offset.zero,
          isDummy: true,
        ),
      );
      if (entry.key == null && !options.randomize) {
        final initialRectangles = CompoundGraphManager(
          graph,
        ).rectangles(initialPositions, padding: options.compoundPadding);
        var initialBounds = initialRectangles[graph.childrenByParent[null]!.first.id]!;
        for (final root in graph.childrenByParent[null]!.skip(1)) {
          initialBounds = initialBounds.union(initialRectangles[root.id]!);
        }
        originalBoundsCenter = initialBounds.center;
      }
    }

    bool belowTiledCompound(FcoseNode node) {
      var parentId = node.parentId;
      while (parentId != null) {
        if (tiledIds.contains(parentId)) return true;
        parentId = graph.nodeById[parentId]!.parentId;
      }
      return false;
    }

    final retained = <FcoseNode>[];
    for (final node in graph.nodes) {
      if (belowTiledCompound(node) || zeroDegreeMembers.contains(node.id)) continue;
      retained.add(nodesById[node.id]!);
    }
    retained.addAll(dummyNodes);
    if (retained.length == graph.nodes.length && dummyNodes.isEmpty) return null;

    final retainedIds = retained.map((node) => node.id).toSet();
    final transformed = FcoseGraph(
      nodes: retained,
      edges: graph.edges.where((edge) => retainedIds.contains(edge.source) && retainedIds.contains(edge.target)),
    );
    return _TilingPlan(
      graph: transformed,
      positions: {for (final leaf in transformed.leafNodes) leaf.id: positions[leaf.id]!},
      groups: _orderTiledGroups(groups),
      originalBoundsCenter: originalBoundsCenter,
    );
  }

  ({FcoseNode node, Offset contentOffset}) _tileProxy(FcoseNode original, _TiledOrganization organization) {
    var width = organization.width;
    var height = organization.height;
    var center = organization.center;
    var contentOffset = Offset.zero;
    if (original.labelWidth > 0) {
      switch (original.labelHorizontalPosition) {
        case FcoseLabelHorizontalPosition.left:
          width += original.labelWidth;
          center += Offset(-original.labelWidth / 2, 0);
          contentOffset += Offset(original.labelWidth, 0);
        case FcoseLabelHorizontalPosition.center when original.labelWidth > width:
          contentOffset += Offset((original.labelWidth - width) / 2, 0);
          width = original.labelWidth;
        case FcoseLabelHorizontalPosition.center:
          break;
        case FcoseLabelHorizontalPosition.right:
          width += original.labelWidth;
          center += Offset(original.labelWidth / 2, 0);
      }
    }
    if (original.labelHeight > 0) {
      switch (original.labelVerticalPosition) {
        case FcoseLabelVerticalPosition.top:
          height += original.labelHeight;
          center += Offset(0, -original.labelHeight / 2);
          contentOffset += Offset(0, original.labelHeight);
        case FcoseLabelVerticalPosition.center when original.labelHeight > height:
          contentOffset += Offset(0, (original.labelHeight - height) / 2);
          height = original.labelHeight;
        case FcoseLabelVerticalPosition.center:
          break;
        case FcoseLabelVerticalPosition.bottom:
          height += original.labelHeight;
          center += Offset(0, original.labelHeight / 2);
      }
    }
    return (
      node: FcoseNode(
        id: original.id,
        width: width,
        height: height,
        parentId: original.parentId,
        position: center,
        labelWidth: original.labelWidth,
        labelHeight: original.labelHeight,
        labelHorizontalPosition: original.labelHorizontalPosition,
        labelVerticalPosition: original.labelVerticalPosition,
        nodeRepulsion: original.nodeRepulsion,
      ),
      contentOffset: contentOffset,
    );
  }

  List<_TiledGroup> _orderTiledGroups(List<_TiledGroup> groups) {
    final pending = groups.toList();
    final result = <_TiledGroup>[];
    while (pending.isNotEmpty) {
      final next = pending.firstWhere(
        (candidate) => !pending.any(
          (other) => other != candidate && other.members.any((member) => member.id == candidate.proxyId),
        ),
      );
      result.add(next);
      pending.remove(next);
    }
    return result;
  }

  FcoseResult _restoreTiling(FcoseGraph graph, _TilingPlan tiling, FcoseResult result) {
    final positions = Map<String, Offset>.of(result.positions);
    final rectangles = Map<String, Rect>.of(result.rectangles);
    for (final group in tiling.groups) {
      final proxyRect = rectangles[group.proxyId]!;
      final organizationTopLeft = Offset(
        group.organization.center.x - group.organization.width / 2,
        group.organization.center.y - group.organization.height / 2,
      );
      final proxyTopLeft = Offset(proxyRect.left, proxyRect.top) + group.contentOffset;
      for (final member in group.members) {
        final position = proxyTopLeft + (group.organization.positions[member.id]! - organizationTopLeft);
        positions[member.id] = position;
        rectangles[member.id] = Rect.fromCenter(position, member.width, member.height);
      }
      if (group.isDummy) {
        positions.remove(group.proxyId);
        rectangles.remove(group.proxyId);
      }
    }

    final compounds = CompoundGraphManager(graph);
    var restoredRectangles = compounds.rectangles({
      for (final leaf in graph.leafNodes) leaf.id: positions[leaf.id]!,
    }, padding: options.compoundPadding);
    var restoredPositions = <String, Offset>{
      for (final leaf in graph.leafNodes) leaf.id: positions[leaf.id]!,
      for (final node in graph.nodes)
        if (compounds.isCompound(node.id)) node.id: restoredRectangles[node.id]!.center,
    };
    if (tiling.originalBoundsCenter case final originalCenter?) {
      var bounds = restoredRectangles.values.first;
      for (final rectangle in restoredRectangles.values.skip(1)) {
        bounds = bounds.union(rectangle);
      }
      final relocation = originalCenter - bounds.center;
      restoredPositions = {for (final entry in restoredPositions.entries) entry.key: entry.value + relocation};
      restoredRectangles = {
        for (final entry in restoredRectangles.entries)
          entry.key: Rect(
            entry.value.left + relocation.x,
            entry.value.top + relocation.y,
            entry.value.width,
            entry.value.height,
          ),
      };
    }
    return FcoseResult(positions: restoredPositions, rectangles: restoredRectangles, iterations: result.iterations);
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

  List<Offset> _componentCenters(_WorkingGraph graph, Map<String, Offset> positions) {
    final rectangles = graph.compounds.rectangles(positions, padding: options.compoundPadding);
    return [
      for (final component in graph.packingComponents)
        component.roots.skip(1).fold(rectangles[component.roots.first]!, (bounds, root) {
          return bounds.union(rectangles[root]!);
        }).center,
    ];
  }

  void _relocateComponentsToOriginalCenters(
    _WorkingGraph graph,
    Map<String, Offset> positions,
    List<Offset> originalCenters,
  ) {
    final currentCenters = _componentCenters(graph, positions);
    for (final (index, component) in graph.packingComponents.indexed) {
      final shift = originalCenters[index] - currentCenters[index];
      for (final id in component.leaves) {
        positions[id] = positions[id]! + shift;
      }
    }
  }

  void _packComponents(_WorkingGraph graph, Map<String, Offset> positions) {
    if (!options.packComponents || graph.packingComponents.length < 2 || options.fixedNodes.isNotEmpty) return;
    final rectangles = graph.compounds.rectangles(positions, padding: options.compoundPadding);
    final packingInput = [
      for (final component in graph.packingComponents)
        PackingComponent(
          nodes: [for (final id in component.nodes) rectangles[id]!],
          edges: [
            for (final edge in graph.edges)
              if (component.nodes.contains(edge.source) && component.nodes.contains(edge.target))
                (start: rectangles[edge.source]!.center, end: rectangles[edge.target]!.center),
          ],
        ),
    ];
    final shifts = options.randomize
        ? RandomizedComponentPacker(
            componentSpacing: options.componentSeparation,
            desiredAspectRatio: options.desiredPackingAspectRatio,
            gridSizeFactor: options.polyominoGridSizeFactor,
            utility: options.packingUtility,
          ).pack(packingInput)
        : IncrementalComponentPacker(componentSpacing: options.componentSeparation).pack(packingInput);
    for (final (index, component) in graph.packingComponents.indexed) {
      for (final id in component.leaves) {
        positions[id] = positions[id]! + shifts[index];
      }
    }
  }

  void _validateConstraints(FcoseGraph graph) {
    final constrained = <String>[
      ...options.fixedNodes.map((constraint) => constraint.nodeId),
      ...options.alignment.vertical.expand((group) => group),
      ...options.alignment.horizontal.expand((group) => group),
      ...options.relativePlacements.expand((constraint) => [constraint.first, constraint.second]),
    ];
    final unknown = constrained.where((id) => !graph.nodeById.containsKey(id)).toSet();
    if (unknown.isNotEmpty) throw ArgumentError.value(unknown, 'constraints', 'unknown node IDs');

    final compoundIds = graph.childrenByParent.entries
        .where((entry) => entry.key != null && entry.value.isNotEmpty)
        .map((entry) => entry.key!)
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
        final isNewEdge = outgoing.putIfAbsent(edge.first, () => {}).add(edge.second);
        indegree.putIfAbsent(edge.first, () => 0);
        if (isNewEdge) {
          indegree[edge.second] = (indegree[edge.second] ?? 0) + 1;
        }
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

  Rect _leafBounds(Iterable<FcoseNode> nodes, Map<String, Offset> positions) {
    final iterator = nodes.iterator..moveNext();
    final first = iterator.current;
    var bounds = Rect.fromCenter(positions[first.id]!, first.width, first.height);
    while (iterator.moveNext()) {
      final node = iterator.current;
      bounds = bounds.union(Rect.fromCenter(positions[node.id]!, node.width, node.height));
    }
    return bounds;
  }

  void _validateOptions() {
    if (options.maxIterations < 1 || options.sampleSize < 1) {
      throw ArgumentError('maxIterations and sampleSize must be positive');
    }
    if (options.idealEdgeLength <= 0 || options.nodeSeparation <= 0) {
      throw ArgumentError('layout lengths must be positive');
    }
    if (options.tilingPaddingHorizontal < 0 || options.tilingPaddingVertical < 0) {
      throw ArgumentError('tiling padding must not be negative');
    }
    if (options.componentSeparation < 0 ||
        options.desiredPackingAspectRatio <= 0 ||
        options.polyominoGridSizeFactor <= 0) {
      throw ArgumentError('packing spacing must not be negative and packing ratios must be positive');
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

/// layout-base's FR grid rebuilds each node's surrounding set every ten ticks.
const _repulsionGridRefreshPeriod = 10;

/// cose-base restores one tree-pruning layer every ten spring ticks.
const _treeGrowthStepIterations = 10;

/// cose-base linearly cools for at most one hundred ticks after tree regrowth.
const _postGrowthIterations = 100;

/// layout-base `FDLayoutConstants.CONVERGENCE_CHECK_PERIOD`, in iterations.
const _convergenceCheckPeriod = 100;

/// layout-base `LayoutConstants.DEFAULT_GRAPH_MARGIN`, in pixels.
const _layoutBaseGraphMargin = 15.0;

/// layout-base `FDLayout.initSpringEmbedder()` runs at least five iterations
/// per CoSE node, even when the configured maximum is smaller.
const _minimumIterationsPerNode = 5;

final class _SpringPhaseResult {
  const _SpringPhaseResult(
    this.iterations,
    this.totalDisplacement,
    this.totalDisplacementThreshold,
    this.oldTotalDisplacement,
    this.iterationLimit,
  );

  final int iterations;
  final double totalDisplacement;
  final double totalDisplacementThreshold;
  final double oldTotalDisplacement;
  final int iterationLimit;
}

final class _PrunedNode {
  const _PrunedNode({required this.node, required this.edge, required this.otherId, required this.relativeOffset});

  final FcoseNode node;
  final FcoseEdge edge;
  final String otherId;
  final Offset relativeOffset;

  String get nodeId => node.id;
}

final class _TreeReduction {
  const _TreeReduction._(this.source, this.coreNodeIds, this.rounds);

  factory _TreeReduction.create(_WorkingGraph source, Map<String, Offset> positions) {
    final active = source.graph.nodes.map((node) => node.id).toSet();
    final incidentEdges = <String, List<FcoseEdge>>{for (final id in active) id: []};
    for (final edge in source.edges) {
      incidentEdges[edge.source]!.add(edge);
      incidentEdges[edge.target]!.add(edge);
    }
    final leafIds = source.leaves.map((node) => node.id).toSet();
    final rectangles = source.compounds.rectangles(positions, padding: 0);
    final rounds = <List<_PrunedNode>>[];

    while (true) {
      final candidates = <FcoseNode>[];
      for (final node in source.graph.nodes) {
        if (!active.contains(node.id) || !leafIds.contains(node.id)) continue;
        final edges = incidentEdges[node.id]!;
        if (edges.length != 1) continue;
        final edge = edges.single;
        if (source.compounds.ownerOf(edge.source) == source.compounds.ownerOf(edge.target)) {
          candidates.add(node);
        }
      }
      if (candidates.isEmpty) break;

      final round = <_PrunedNode>[];
      for (final node in candidates) {
        final edges = incidentEdges[node.id]!;
        if (edges.length != 1) continue;
        final edge = edges.single;
        final otherId = edge.source == node.id ? edge.target : edge.source;
        round.add(
          _PrunedNode(
            node: node,
            edge: edge,
            otherId: otherId,
            relativeOffset: rectangles[node.id]!.center - rectangles[otherId]!.center,
          ),
        );
        active.remove(node.id);
        incidentEdges[node.id]!.clear();
        incidentEdges[otherId]!.remove(edge);
      }
      if (round.isEmpty) break;
      rounds.add(List.unmodifiable(round));
    }

    return _TreeReduction._(source, Set.unmodifiable(active), List.unmodifiable(rounds));
  }

  final _WorkingGraph source;
  final Set<String> coreNodeIds;
  final List<List<_PrunedNode>> rounds;

  FcoseGraph activeGraph(Set<String> activeNodeIds) => FcoseGraph(
    nodes: source.graph.nodes.where((node) => activeNodeIds.contains(node.id)),
    edges: source.edges.where((edge) => activeNodeIds.contains(edge.source) && activeNodeIds.contains(edge.target)),
  );
}

final class _TiledOrganization {
  const _TiledOrganization({required this.positions, required this.center, required this.width, required this.height});

  final Map<String, Offset> positions;
  final Offset center;
  final double width;
  final double height;
}

final class _TilingPlan {
  const _TilingPlan({
    required this.graph,
    required this.positions,
    required this.groups,
    required this.originalBoundsCenter,
  });

  final FcoseGraph graph;
  final Map<String, Offset> positions;
  final List<_TiledGroup> groups;
  final Offset? originalBoundsCenter;
}

final class _TiledGroup {
  const _TiledGroup({
    required this.proxyId,
    required this.members,
    required this.organization,
    required this.contentOffset,
    required this.isDummy,
  });

  final String proxyId;
  final List<FcoseNode> members;
  final _TiledOrganization organization;
  final Offset contentOffset;
  final bool isDummy;
}

final class _SpectralGraph {
  const _SpectralGraph(this.nodes, this.adjacency);

  final List<String> nodes;
  final Map<String, Set<String>> adjacency;
}

final class _WorkingGraph {
  _WorkingGraph(this.graph)
    : nodeById = graph.nodeById,
      leaves = graph.leafNodes,
      compounds = CompoundGraphManager(graph) {
    final seenPairs = <(String, String)>{};
    edges = List.unmodifiable([
      for (final edge in graph.edges)
        if (edge.source != edge.target &&
            seenPairs.add(
              edge.source.compareTo(edge.target) <= 0 ? (edge.source, edge.target) : (edge.target, edge.source),
            ))
          edge,
    ]);
    adjacency = {for (final node in leaves) node.id: <String>{}};
    for (final edge in edges) {
      final source = representative(edge.source);
      final target = representative(edge.target);
      if (source != target) {
        adjacency[source]!.add(target);
        adjacency[target]!.add(source);
      }
    }
    spectralGraph = _buildSpectralGraph();
    packingComponents = _findPackingComponents();
  }

  final FcoseGraph graph;
  final CompoundGraphManager compounds;
  final Map<String, FcoseNode> nodeById;
  final List<FcoseNode> leaves;
  late final List<FcoseEdge> edges;
  late final Map<String, Set<String>> adjacency;
  late final _SpectralGraph spectralGraph;
  late final List<({List<String> roots, List<String> nodes, List<String> leaves})> packingComponents;
  final Map<String, String> _representatives = {};

  String representative(String id) => _representatives.putIfAbsent(id, () => compounds.spectralRepresentative(id));

  _SpectralGraph _buildSpectralGraph() {
    final transformedAdjacency = {for (final entry in adjacency.entries) entry.key: entry.value.toSet()};
    final transformedNodes = leaves.map((node) => node.id).toList();
    final incidentEdgeCounts = {for (final node in graph.nodes) node.id: 0};
    for (final edge in graph.edges) {
      incidentEdgeCounts[edge.source] = incidentEdgeCounts[edge.source]! + 1;
      if (edge.target != edge.source) {
        incidentEdgeCounts[edge.target] = incidentEdgeCounts[edge.target]! + 1;
      }
    }

    var dummyIndex = 1;
    for (final ownerId in <String?>[
      null,
      ...graph.nodes.where((node) => compounds.isCompound(node.id)).map((node) => node.id),
    ]) {
      final directChildren = graph.childrenByParent[ownerId] ?? const [];
      if (directChildren.length < 2) continue;
      final directIds = directChildren.map((node) => node.id).toSet();

      String? directChildOf(String nodeId) {
        var current = nodeId;
        while (!directIds.contains(current)) {
          final parent = graph.nodeById[current]?.parentId;
          if (parent == null || parent == ownerId) return null;
          current = parent;
        }
        return current;
      }

      final ownerAdjacency = {for (final child in directChildren) child.id: <String>{}};
      for (final edge in graph.edges) {
        final source = directChildOf(edge.source);
        final target = directChildOf(edge.target);
        if (source == null || target == null || source == target) continue;
        ownerAdjacency[source]!.add(target);
        ownerAdjacency[target]!.add(source);
      }

      final unseen = directIds.toSet();
      final representatives = <String>[];
      while (unseen.isNotEmpty) {
        final component = <String>[];
        final queue = Queue<String>()..add(unseen.first);
        unseen.remove(queue.first);
        while (queue.isNotEmpty) {
          final current = queue.removeFirst();
          component.add(current);
          for (final neighbor in ownerAdjacency[current]!) {
            if (unseen.remove(neighbor)) queue.add(neighbor);
          }
        }
        var selected = component.first;
        for (final candidate in component.skip(1)) {
          if (incidentEdgeCounts[candidate]! < incidentEdgeCounts[selected]!) {
            selected = candidate;
          }
        }
        representatives.add(representative(selected));
      }
      if (representatives.length < 2) continue;

      var dummyId = '\u0000fcose-dummy-${dummyIndex++}';
      while (transformedAdjacency.containsKey(dummyId) || graph.nodeById.containsKey(dummyId)) {
        dummyId = '\u0000fcose-dummy-${dummyIndex++}';
      }
      transformedNodes.add(dummyId);
      transformedAdjacency[dummyId] = representatives.toSet();
      for (final representativeId in representatives) {
        transformedAdjacency[representativeId]!.add(dummyId);
      }
    }

    return _SpectralGraph(
      List.unmodifiable(transformedNodes),
      Map.unmodifiable({for (final entry in transformedAdjacency.entries) entry.key: Set.unmodifiable(entry.value)}),
    );
  }

  List<({List<String> roots, List<String> nodes, List<String> leaves})> _findPackingComponents() {
    final rootNodes = graph.childrenByParent[null]!;
    final rootAdjacency = {for (final node in rootNodes) node.id: <String>{}};
    for (final edge in edges) {
      final source = compounds.childInOwner(edge.source, null);
      final target = compounds.childInOwner(edge.target, null);
      if (source == target) continue;
      rootAdjacency[source]!.add(target);
      rootAdjacency[target]!.add(source);
    }

    final unseen = rootAdjacency.keys.toSet();
    final result = <({List<String> roots, List<String> nodes, List<String> leaves})>[];
    while (unseen.isNotEmpty) {
      final roots = <String>[];
      final queue = Queue<String>()..add(unseen.first);
      unseen.remove(queue.first);
      while (queue.isNotEmpty) {
        final current = queue.removeFirst();
        roots.add(current);
        for (final next in rootAdjacency[current]!) {
          if (unseen.remove(next)) queue.add(next);
        }
      }
      final rootIds = roots.toSet();
      result.add((
        roots: List.unmodifiable(roots),
        nodes: List.unmodifiable(
          graph.nodes.where((node) => rootIds.contains(compounds.childInOwner(node.id, null))).map((node) => node.id),
        ),
        leaves: List.unmodifiable([for (final root in roots) ...compounds.descendantLeaves(root)]),
      ));
    }
    return List.unmodifiable(result);
  }
}
