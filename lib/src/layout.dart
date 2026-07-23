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

    final rootTiling = _prepareRootZeroDegreeTiling(graph);
    final working = _WorkingGraph(rootTiling?.graph ?? graph);
    final random = _Random(options.seed);
    final positions = _initialPositions(working, random);
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

    var iterations = 0;
    if (options.quality != LayoutQuality.draft) {
      iterations = _runSpringEmbedder(working, positions, constraintHandler);
    }
    if (!_hasConstraints && rootTiling == null) {
      _packComponents(working, positions);
    }

    final rectangles = working.compounds.rectangles(positions, padding: options.compoundPadding);
    final allPositions = <String, Offset>{
      ...positions,
      for (final node in graph.nodes)
        if (working.compounds.isCompound(node.id)) node.id: rectangles[node.id]!.center,
    };
    final result = FcoseResult(positions: allPositions, rectangles: rectangles, iterations: iterations);
    return rootTiling == null ? result : _restoreRootZeroDegreeMembers(rootTiling, result);
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
        )
        .run(
          component,
          graph.adjacency,
          widths: {for (final id in component) id: graph.graph.nodeById[id]!.width},
          initialPositions: {for (final id in component) id: ?graph.graph.nodeById[id]!.position},
          idealEdgeLength: options.idealEdgeLength,
        )
        .positions;
  }

  int _runSpringEmbedder(_WorkingGraph graph, Map<String, Offset> positions, ConstraintHandler constraintHandler) {
    final forces = <String, Offset>{};
    final fixed = options.fixedNodes.map((constraint) => constraint.nodeId).toSet();
    var coolingFactor = options.initialEnergyOnIncremental;
    var coolingCycle = 0;
    var totalDisplacement = double.infinity;
    var oldTotalDisplacement = 0.0;
    final maxIterations = math.max(options.maxIterations, graph.graph.nodes.length * _minimumIterationsPerNode);
    final maxCoolingCycle = maxIterations / _convergenceCheckPeriod;
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
      if (iterationNumber == maxIterations) return iterationNumber;
      if (iterationNumber % _convergenceCheckPeriod == 0) {
        final converged = totalDisplacement < totalDisplacementThreshold;
        final oscillating = iterationNumber > maxIterations / 3 && (totalDisplacement - oldTotalDisplacement).abs() < 2;
        oldTotalDisplacement = totalDisplacement;
        if (converged || oscillating) return iterationNumber;
        coolingCycle++;
        final adjuster = switch (options.quality) {
          LayoutQuality.draft || LayoutQuality.defaultQuality => coolingCycle.toDouble(),
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

      if (iterationNumber % _repulsionGridRefreshPeriod == 1) {
        repulsionPairs = _refreshRepulsionPairs(graph, rectangles, 2 * averageIdealLength);
      }
      for (final (first, second) in repulsionPairs) {
        final firstRect = rectangles[first.id]!;
        final secondRect = rectangles[second.id]!;
        final firstWeight = graph.compounds.descendantLeaves(first.id).length;
        final secondWeight = graph.compounds.descendantLeaves(second.id).length;
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
      for (final node in graph.compounds.layoutOrder) {
        if (fixed.contains(node.id)) continue;
        final position = rectangles[node.id]!.center;
        final owner = graph.compounds.ownerOf(node.id);
        var gravityForce = Offset.zero;
        if (!graph.compounds.isOwnerConnected(owner)) {
          final ownerBounds = graph.compounds.ownerBounds(owner, rectangles);
          final ownerCenter = ownerBounds.center;
          final distance = position - ownerCenter;
          final rangeFactor = owner == null ? options.gravityRange : options.compoundGravityRange;
          final estimatedSize = graph.compounds.estimatedSizeOfOwner(owner);
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
        if (!graph.compounds.isCompound(node.id)) {
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
        if (graph.compounds.isCompound(node.id)) {
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
    return maxIterations;
  }

  List<(FcoseNode, FcoseNode)> _refreshRepulsionPairs(
    _WorkingGraph graph,
    Map<String, Rect> rectangles,
    double repulsionRange,
  ) {
    final nodes = graph.compounds.layoutOrder.toList();
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

  _TiledOrganization _tileNodes(List<FcoseNode> members, Map<String, Offset> positions) {
    final indexed = members.indexed.map((entry) => (index: entry.$1, node: entry.$2)).toList()
      ..sort((first, second) {
        final firstArea = first.node.width * first.node.height;
        final secondArea = second.node.width * second.node.height;
        final areaOrder = secondArea.compareTo(firstArea);
        return areaOrder == 0 ? first.index.compareTo(second.index) : areaOrder;
      });
    final nodes = [for (final entry in indexed) entry.node];
    final center = Offset(
      nodes.fold(0.0, (sum, node) => sum + positions[node.id]!.x) / nodes.length,
      nodes.fold(0.0, (sum, node) => sum + positions[node.id]!.y) / nodes.length,
    );
    final rows = <List<FcoseNode>>[];
    final rowWidths = <double>[];
    final rowHeights = <double>[];
    var width = 0.0;
    var height = 0.0;

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
        rowWidths.add(0);
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
    final left = center.x - width / 2;
    var top = center.y - height / 2;
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

  _RootZeroDegreeTiling? _prepareRootZeroDegreeTiling(FcoseGraph graph) {
    // This is the exact root-level subset of groupZeroDegreeMembers(). The
    // randomized path must group after spectral initialization, while compound
    // owners also require clearCompounds()/repopulateCompounds(); both remain
    // separate follow-up stages rather than being approximated here.
    if (!options.tile ||
        options.randomize ||
        _hasConstraints ||
        graph.nodes.length != graph.leafNodes.length ||
        graph.leafNodes.any((node) => node.position == null)) {
      return null;
    }
    final incident = <String>{};
    for (final edge in graph.edges) {
      if (edge.source == edge.target) continue;
      incident
        ..add(edge.source)
        ..add(edge.target);
    }
    final members = graph.leafNodes.where((node) => !incident.contains(node.id)).toList();
    if (members.length < 2) return null;

    const dummyId = 'DummyCompound_undefined';
    if (graph.nodeById.containsKey(dummyId)) return null;
    final initialPositions = {for (final node in graph.leafNodes) node.id: node.position!};
    final organization = _tileNodes(members, initialPositions);
    final retainedNodes = graph.nodes.where((node) => !organization.positions.containsKey(node.id));
    final dummy = FcoseNode(
      id: dummyId,
      width: organization.width,
      height: organization.height,
      position: organization.center,
    );
    return _RootZeroDegreeTiling(
      graph: FcoseGraph(nodes: [...retainedNodes, dummy], edges: graph.edges),
      members: members,
      organization: organization,
      originalBoundsCenter: _leafBounds(graph.leafNodes, initialPositions).center,
      dummyId: dummyId,
    );
  }

  FcoseResult _restoreRootZeroDegreeMembers(_RootZeroDegreeTiling tiling, FcoseResult result) {
    final dummyRect = result.rectangles[tiling.dummyId]!;
    final organizationTopLeft = Offset(
      tiling.organization.center.x - tiling.organization.width / 2,
      tiling.organization.center.y - tiling.organization.height / 2,
    );
    final dummyTopLeft = Offset(dummyRect.left, dummyRect.top);
    final positions = <String, Offset>{
      for (final entry in result.positions.entries)
        if (entry.key != tiling.dummyId) entry.key: entry.value,
      for (final member in tiling.members)
        member.id: dummyTopLeft + (tiling.organization.positions[member.id]! - organizationTopLeft),
    };
    final rectangles = <String, Rect>{
      for (final entry in result.rectangles.entries)
        if (entry.key != tiling.dummyId) entry.key: entry.value,
      for (final member in tiling.members)
        member.id: Rect.fromCenter(positions[member.id]!, member.width, member.height),
    };

    var bounds = rectangles.values.first;
    for (final rectangle in rectangles.values.skip(1)) {
      bounds = bounds.union(rectangle);
    }
    final relocation = tiling.originalBoundsCenter - bounds.center;
    return FcoseResult(
      positions: {for (final entry in positions.entries) entry.key: entry.value + relocation},
      rectangles: {
        for (final entry in rectangles.entries)
          entry.key: Rect(
            entry.value.left + relocation.x,
            entry.value.top + relocation.y,
            entry.value.width,
            entry.value.height,
          ),
      },
      iterations: result.iterations,
    );
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

/// layout-base `FDLayoutConstants.CONVERGENCE_CHECK_PERIOD`, in iterations.
const _convergenceCheckPeriod = 100;

/// layout-base `LayoutConstants.DEFAULT_GRAPH_MARGIN`, in pixels.
const _layoutBaseGraphMargin = 15.0;

/// layout-base `FDLayout.initSpringEmbedder()` runs at least five iterations
/// per CoSE node, even when the configured maximum is smaller.
const _minimumIterationsPerNode = 5;

final class _TiledOrganization {
  const _TiledOrganization({required this.positions, required this.center, required this.width, required this.height});

  final Map<String, Offset> positions;
  final Offset center;
  final double width;
  final double height;
}

final class _RootZeroDegreeTiling {
  const _RootZeroDegreeTiling({
    required this.graph,
    required this.members,
    required this.organization,
    required this.originalBoundsCenter,
    required this.dummyId,
  });

  final FcoseGraph graph;
  final List<FcoseNode> members;
  final _TiledOrganization organization;
  final Offset originalBoundsCenter;
  final String dummyId;
}

final class _WorkingGraph {
  _WorkingGraph(this.graph)
    : nodeById = graph.nodeById,
      leaves = List.unmodifiable(graph.leafNodes),
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
    components = _findComponents();
  }

  final FcoseGraph graph;
  final CompoundGraphManager compounds;
  final Map<String, FcoseNode> nodeById;
  final List<FcoseNode> leaves;
  late final List<FcoseEdge> edges;
  late final Map<String, Set<String>> adjacency;
  late final List<List<String>> components;
  final Map<String, String> _representatives = {};

  String representative(String id) => _representatives.putIfAbsent(id, () => compounds.spectralRepresentative(id));

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
