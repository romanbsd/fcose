import 'dart:collection';

import 'constraints.dart';
import 'layout.dart';
import 'model.dart';
import 'options.dart';

/// Mermaid architecture uses half an icon as the boundary distance for edges
/// that cross compound parents.
const _crossParentIdealLengthFactor = 0.5;

/// Mermaid's weak elasticity for edges that cross compound parents.
const _crossParentElasticity = 0.001;

enum MermaidAlignmentDirection { row, column }

enum MermaidArchitectureDirection { left, right, top, bottom }

typedef MermaidSpatialMap = Map<String, ({int x, int y})>;
typedef MermaidGroupAlignments = Map<String, Map<String, MermaidAlignmentDirection>>;

final class MermaidAlignmentHint {
  const MermaidAlignmentHint(this.direction, this.members);

  final MermaidAlignmentDirection direction;
  final List<String> members;
}

final class MermaidDirectionalEdge {
  const MermaidDirectionalEdge({
    required this.source,
    required this.sourceDirection,
    required this.target,
    required this.targetDirection,
  });

  final String source;
  final MermaidArchitectureDirection sourceDirection;
  final String target;
  final MermaidArchitectureDirection targetDirection;
}

final class MermaidArchitectureData {
  const MermaidArchitectureData({required this.spatialMaps, required this.groupAlignments});

  final List<MermaidSpatialMap> spatialMaps;
  final MermaidGroupAlignments groupAlignments;
}

final class MermaidFcoseConfiguration {
  const MermaidFcoseConfiguration({required this.graph, required this.options});

  final FcoseGraph graph;
  final FcoseOptions options;

  /// Runs the two fCoSE passes used by Mermaid's architecture renderer.
  ///
  /// Mermaid invokes the configured layout once, then invokes it again from
  /// its one-shot `layoutstop` callback after updating edge rendering. With
  /// `randomize: false`, the second pass starts from the first pass positions.
  FcoseResult runMermaidArchitecture() {
    final first = FcoseLayout(options: options).run(graph);
    final secondPassGraph = FcoseGraph(
      nodes: graph.nodes.map(
        (node) => FcoseNode(
          id: node.id,
          width: node.width,
          height: node.height,
          parentId: node.parentId,
          position: first.positionOf(node.id),
          labelWidth: node.labelWidth,
          labelHeight: node.labelHeight,
          labelHorizontalPosition: node.labelHorizontalPosition,
          labelVerticalPosition: node.labelVerticalPosition,
          nodeRepulsion: node.nodeRepulsion,
        ),
      ),
      edges: graph.edges,
    );
    return FcoseLayout(options: options).run(secondPassGraph);
  }
}

/// Converts Mermaid architecture measurements and topology into fCoSE input.
///
/// Mermaid uses different spring parameters for edges crossing a compound
/// boundary. Keeping this policy outside the solver mirrors the JavaScript
/// renderer's per-edge callbacks.
final class MermaidFcoseAdapter {
  const MermaidFcoseAdapter({
    required this.iconSize,
    required this.idealEdgeLengthMultiplier,
    required this.edgeElasticity,
    this.padding = 40,
    this.nodeSeparation = 75,
    this.numIter = 2500,
    this.randomize = false,
    this.seed = 1,
  });

  final double iconSize;
  final double idealEdgeLengthMultiplier;
  final double edgeElasticity;
  final double padding;
  final double nodeSeparation;
  final int numIter;
  final bool randomize;
  final int seed;

  double get _sameParentIdealLength => idealEdgeLengthMultiplier * iconSize;

  double get _crossParentIdealLength => _crossParentIdealLengthFactor * iconSize;

  FcoseOptions _options({
    AlignmentConstraint alignment = const AlignmentConstraint(),
    List<RelativePlacementConstraint> relativePlacements = const [],
  }) => FcoseOptions(
    quality: LayoutQuality.proof,
    randomize: randomize,
    seed: seed,
    maxIterations: numIter,
    nodeSeparation: nodeSeparation,
    idealEdgeLength: _sameParentIdealLength,
    edgeElasticity: edgeElasticity,
    compoundPadding: padding,
    alignment: alignment,
    relativePlacements: relativePlacements,
  );

  FcoseOptions get options => _options();

  FcoseGraph configureGraph(FcoseGraph graph) {
    final nodes = graph.nodeById;
    return FcoseGraph(
      nodes: graph.nodes,
      edges: graph.edges.map((edge) {
        final sameParent = nodes[edge.source]!.parentId == nodes[edge.target]!.parentId;
        return FcoseEdge(
          id: edge.id,
          source: edge.source,
          target: edge.target,
          idealLength: edge.idealLength ?? (sameParent ? _sameParentIdealLength : _crossParentIdealLength),
          elasticity: edge.elasticity ?? (sameParent ? edgeElasticity : _crossParentElasticity),
        );
      }),
    );
  }

  /// Converts Mermaid architecture spatial maps and declared `align` hints to
  /// the exact fCoSE constraint shapes used by `architectureRenderer.ts`.
  MermaidFcoseConfiguration configureLayout(
    FcoseGraph graph, {
    List<MermaidSpatialMap> spatialMaps = const [],
    MermaidGroupAlignments groupAlignments = const {},
    List<MermaidAlignmentHint> layoutHints = const [],
  }) {
    final alignment = _alignmentConstraints(graph, spatialMaps, groupAlignments, layoutHints);
    final relative = _relativeConstraints(spatialMaps, layoutHints);
    return MermaidFcoseConfiguration(
      graph: configureGraph(graph),
      options: _options(alignment: alignment, relativePlacements: relative),
    );
  }

  /// Full Mermaid architecture adapter entry point. It ports
  /// `ArchitectureDB.getDataStructures()` before converting the resulting
  /// spatial maps to fCoSE constraints.
  MermaidFcoseConfiguration configureArchitecture(
    FcoseGraph graph, {
    required List<MermaidDirectionalEdge> directionalEdges,
    List<MermaidAlignmentHint> layoutHints = const [],
  }) {
    final data = buildArchitectureData(graph, directionalEdges);
    return configureLayout(
      graph,
      spatialMaps: data.spatialMaps,
      groupAlignments: data.groupAlignments,
      layoutHints: layoutHints,
    );
  }

  MermaidArchitectureData buildArchitectureData(FcoseGraph graph, List<MermaidDirectionalEdge> directionalEdges) {
    final leaves = graph.leafNodes.map((node) => node.id).toList();
    final adjacency = {for (final id in leaves) id: <_DirectionPair, String>{}};
    final groupAlignments = <String, Map<String, MermaidAlignmentDirection>>{};
    for (final edge in directionalEdges) {
      if (!adjacency.containsKey(edge.source) || !adjacency.containsKey(edge.target)) {
        throw ArgumentError.value(edge, 'directionalEdges', 'endpoints must be leaf nodes');
      }
      final forward = _DirectionPair(edge.sourceDirection, edge.targetDirection);
      final reverse = _DirectionPair(edge.targetDirection, edge.sourceDirection);
      if (!forward.isValid) {
        throw ArgumentError.value(edge, 'directionalEdges', 'matching port directions cannot form an edge');
      }
      adjacency[edge.source]![forward] = edge.target;
      adjacency[edge.target]![reverse] = edge.source;

      final sourceGroup = graph.nodeById[edge.source]!.parentId;
      final targetGroup = graph.nodeById[edge.target]!.parentId;
      final alignment = forward.alignment;
      if (sourceGroup != null && targetGroup != null && sourceGroup != targetGroup && alignment != null) {
        (groupAlignments[sourceGroup] ??= {})[targetGroup] = alignment;
        (groupAlignments[targetGroup] ??= {})[sourceGroup] = alignment;
      }
    }
    if (leaves.isEmpty) {
      return const MermaidArchitectureData(spatialMaps: [], groupAlignments: {});
    }

    final visited = <String>{leaves.first};
    final notVisited = leaves.skip(1).toSet();
    MermaidSpatialMap breadthFirst(String start) {
      final result = <String, ({int x, int y})>{start: (x: 0, y: 0)};
      final queue = Queue<String>()..add(start);
      while (queue.isNotEmpty) {
        final current = queue.removeFirst();
        visited.add(current);
        notVisited.remove(current);
        final position = result[current]!;
        for (final MapEntry(key: pair, value: neighbor) in adjacency[current]!.entries) {
          if (visited.contains(neighbor)) continue;
          result[neighbor] = pair.shift(position);
          queue.add(neighbor);
        }
      }
      return result;
    }

    final spatialMaps = <MermaidSpatialMap>[breadthFirst(leaves.first)];
    while (notVisited.isNotEmpty) {
      spatialMaps.add(breadthFirst(notVisited.first));
    }
    return MermaidArchitectureData(spatialMaps: spatialMaps, groupAlignments: groupAlignments);
  }

  AlignmentConstraint _alignmentConstraints(
    FcoseGraph graph,
    List<MermaidSpatialMap> spatialMaps,
    MermaidGroupAlignments groupAlignments,
    List<MermaidAlignmentHint> hints,
  ) {
    final horizontal = <List<String>>[];
    final vertical = <List<String>>[];
    for (final spatialMap in spatialMaps) {
      final horizontalByCoordinate = <int, Map<String, List<String>>>{};
      final verticalByCoordinate = <int, Map<String, List<String>>>{};
      for (final MapEntry(key: id, value: position) in spatialMap.entries) {
        final group = graph.nodeById[id]?.parentId ?? _defaultGroup;
        ((horizontalByCoordinate[position.y] ??= {})[group] ??= []).add(id);
        ((verticalByCoordinate[position.x] ??= {})[group] ??= []).add(id);
      }
      horizontal.addAll(_flattenAlignments(horizontalByCoordinate, MermaidAlignmentDirection.row, groupAlignments));
      vertical.addAll(_flattenAlignments(verticalByCoordinate, MermaidAlignmentDirection.column, groupAlignments));
    }

    final declaredMembers = hints.expand((hint) => hint.members).toSet();
    horizontal.removeWhere((group) => group.any(declaredMembers.contains));
    vertical.removeWhere((group) => group.any(declaredMembers.contains));
    for (final hint in hints.where((hint) => hint.members.length > 1)) {
      (hint.direction == MermaidAlignmentDirection.row ? horizontal : vertical).add(List.of(hint.members));
    }
    return AlignmentConstraint(horizontal: horizontal, vertical: vertical);
  }

  List<List<String>> _flattenAlignments(
    Map<int, Map<String, List<String>>> byCoordinate,
    MermaidAlignmentDirection direction,
    MermaidGroupAlignments groupAlignments,
  ) {
    // Mermaid accumulates these in a plain JavaScript object. Preserve both
    // replacement/insertion semantics and Object.values() key ordering: array
    // index coordinates first in ascending order, then all other keys in
    // insertion order.
    final flattened = <String, List<String>>{};
    for (final MapEntry(key: coordinate, value: groups) in byCoordinate.entries) {
      final coordinateKey = '$coordinate';
      final entries = groups.entries.toList();
      if (entries.length == 1) {
        flattened[coordinateKey] = List.of(entries.single.value);
        continue;
      }
      var count = 0;
      for (var first = 0; first < entries.length - 1; first++) {
        for (var second = first + 1; second < entries.length; second++) {
          final a = entries[first];
          final b = entries[second];
          final compatible =
              a.key == _defaultGroup || b.key == _defaultGroup || groupAlignments[a.key]?[b.key] == direction;
          if (compatible) {
            flattened[coordinateKey] = [...?flattened[coordinateKey], ...a.value, ...b.value];
          } else {
            flattened['$coordinate-$count'] = List.of(a.value);
            count++;
            flattened['$coordinate-$count'] = List.of(b.value);
            count++;
          }
        }
      }
    }

    final arrayIndexes = <({int index, List<String> value})>[];
    final otherValues = <List<String>>[];
    for (final MapEntry(key: key, value: value) in flattened.entries) {
      final index = int.tryParse(key);
      if (index != null && index >= 0 && index <= _maximumJavaScriptArrayIndex && '$index' == key) {
        arrayIndexes.add((index: index, value: value));
      } else {
        otherValues.add(value);
      }
    }
    arrayIndexes.sort((first, second) => first.index.compareTo(second.index));
    return [...arrayIndexes.map((entry) => entry.value), ...otherValues].where((group) => group.length > 1).toList();
  }

  List<RelativePlacementConstraint> _relativeConstraints(
    List<MermaidSpatialMap> spatialMaps,
    List<MermaidAlignmentHint> hints,
  ) {
    final result = <RelativePlacementConstraint>[];
    final declaredPairs = <(String, String)>{};
    final gap = _sameParentIdealLength;
    for (final hint in hints) {
      for (var index = 0; index < hint.members.length - 1; index++) {
        final first = hint.members[index];
        final second = hint.members[index + 1];
        declaredPairs
          ..add((first, second))
          ..add((second, first));
        result.add(
          hint.direction == MermaidAlignmentDirection.row
              ? RelativePlacementConstraint.horizontal(first, second, gap: gap)
              : RelativePlacementConstraint.vertical(first, second, gap: gap),
        );
      }
    }

    const shifts = [(-1, 0), (1, 0), (0, 1), (0, -1)];
    for (final spatialMap in spatialMaps) {
      final inverse = {for (final MapEntry(key: id, value: position) in spatialMap.entries) position: id};
      final queue = Queue<({int x, int y})>()..add((x: 0, y: 0));
      final visited = <({int x, int y})>{};
      while (queue.isNotEmpty) {
        final current = queue.removeFirst();
        // Mermaid processes duplicate queue entries again. The visited map
        // prevents new back-edges from being queued, but does not skip an
        // already-queued coordinate when it is later removed.
        visited.add(current);
        final currentId = inverse[current];
        if (currentId == null) continue;
        for (final (dx, dy) in shifts) {
          final next = (x: current.x + dx, y: current.y + dy);
          final nextId = inverse[next];
          if (nextId == null || visited.contains(next)) continue;
          queue.add(next);
          if (declaredPairs.contains((currentId, nextId))) continue;
          result.add(switch ((dx, dy)) {
            (-1, 0) => RelativePlacementConstraint.horizontal(nextId, currentId, gap: gap),
            (1, 0) => RelativePlacementConstraint.horizontal(currentId, nextId, gap: gap),
            (0, 1) => RelativePlacementConstraint.vertical(nextId, currentId, gap: gap),
            (0, -1) => RelativePlacementConstraint.vertical(currentId, nextId, gap: gap),
            _ => throw StateError('unknown spatial-map direction'),
          });
        }
      }
    }
    return result;
  }
}

const _defaultGroup = 'default';

/// Largest key ordered as an array index by JavaScript's Object.values().
const _maximumJavaScriptArrayIndex = 0xfffffffe;

final class _DirectionPair {
  const _DirectionPair(this.source, this.target);

  final MermaidArchitectureDirection source;
  final MermaidArchitectureDirection target;

  bool get isValid => source != target;
  bool get _sourceIsHorizontal =>
      source == MermaidArchitectureDirection.left || source == MermaidArchitectureDirection.right;
  bool get _targetIsHorizontal =>
      target == MermaidArchitectureDirection.left || target == MermaidArchitectureDirection.right;

  MermaidAlignmentDirection? get alignment {
    if (_sourceIsHorizontal != _targetIsHorizontal) return null;
    return _sourceIsHorizontal ? MermaidAlignmentDirection.row : MermaidAlignmentDirection.column;
  }

  ({int x, int y}) shift(({int x, int y}) position) {
    if (_sourceIsHorizontal) {
      final x = position.x + (source == MermaidArchitectureDirection.left ? -1 : 1);
      if (_targetIsHorizontal) return (x: x, y: position.y);
      return (x: x, y: position.y + (target == MermaidArchitectureDirection.top ? 1 : -1));
    }
    final y = position.y + (source == MermaidArchitectureDirection.top ? 1 : -1);
    if (!_targetIsHorizontal) return (x: position.x, y: y);
    return (x: position.x + (target == MermaidArchitectureDirection.left ? 1 : -1), y: y);
  }

  @override
  bool operator ==(Object other) => other is _DirectionPair && source == other.source && target == other.target;

  @override
  int get hashCode => Object.hash(source, target);
}
