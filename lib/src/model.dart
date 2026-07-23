import 'geometry.dart';

enum FcoseLabelHorizontalPosition { left, center, right }

enum FcoseLabelVerticalPosition { top, center, bottom }

/// A node accepted by the framework-neutral fCoSE layout API.
final class FcoseNode {
  const FcoseNode({
    required this.id,
    this.width = 30,
    this.height = 30,
    this.parentId,
    this.position,
    this.labelWidth = 0,
    this.labelHeight = 0,
    this.labelHorizontalPosition = FcoseLabelHorizontalPosition.center,
    this.labelVerticalPosition = FcoseLabelVerticalPosition.center,
    this.nodeRepulsion,
  });

  final String id;
  final double width;
  final double height;
  final String? parentId;

  /// Initial center position. It is respected when [FcoseOptions.randomize] is false.
  final Offset? position;

  /// Measured label dimensions used by layout-base when updating compound
  /// bounds. Leaf [width] and [height] should already include labels when the
  /// consuming renderer enables `nodeDimensionsIncludeLabels`.
  final double labelWidth;
  final double labelHeight;
  final FcoseLabelHorizontalPosition labelHorizontalPosition;
  final FcoseLabelVerticalPosition labelVerticalPosition;

  /// Per-node fCoSE repulsion strength. When absent, the layout-wide option is
  /// used, matching cytoscape-fCoSE's `nodeRepulsion(node)` callback.
  final double? nodeRepulsion;
}

/// An undirected graph edge.
final class FcoseEdge {
  const FcoseEdge({required this.id, required this.source, required this.target, this.idealLength, this.elasticity});

  final String id;
  final String source;
  final String target;
  final double? idealLength;
  final double? elasticity;
}

/// A validated compound graph suitable for layout.
final class FcoseGraph {
  FcoseGraph({required Iterable<FcoseNode> nodes, Iterable<FcoseEdge> edges = const []})
    : nodes = List.unmodifiable(nodes),
      edges = List.unmodifiable(edges) {
    _validate();
  }

  final List<FcoseNode> nodes;
  final List<FcoseEdge> edges;

  late final Map<String, FcoseNode> nodeById = {for (final node in nodes) node.id: node};

  late final Map<String?, List<FcoseNode>> childrenByParent = () {
    final result = <String?, List<FcoseNode>>{};
    for (final node in nodes) {
      (result[node.parentId] ??= []).add(node);
    }
    return result;
  }();

  Iterable<FcoseNode> get leafNodes => nodes.where((node) => !(childrenByParent[node.id]?.isNotEmpty ?? false));

  void _validate() {
    final ids = <String>{};
    for (final node in nodes) {
      if (node.id.isEmpty) throw ArgumentError.value(node.id, 'node.id', 'must not be empty');
      if (!ids.add(node.id)) throw ArgumentError.value(node.id, 'nodes', 'duplicate node ID');
      if (node.width <= 0 || node.height <= 0) {
        throw ArgumentError.value(node.id, 'nodes', 'node dimensions must be positive');
      }
      if (node.labelWidth < 0 || node.labelHeight < 0) {
        throw ArgumentError.value(node.id, 'nodes', 'label dimensions must not be negative');
      }
    }
    for (final node in nodes) {
      if (node.parentId case final parent? when !ids.contains(parent)) {
        throw ArgumentError.value(parent, 'node.parentId', 'unknown parent');
      }
      final ancestors = <String>{node.id};
      var current = node.parentId;
      while (current != null) {
        if (!ancestors.add(current)) {
          throw ArgumentError.value(node.id, 'nodes', 'compound parent cycle');
        }
        current = nodes.firstWhere((candidate) => candidate.id == current).parentId;
      }
    }
    final edgeIds = <String>{};
    for (final edge in edges) {
      if (!edgeIds.add(edge.id)) throw ArgumentError.value(edge.id, 'edges', 'duplicate edge ID');
      if (!ids.contains(edge.source) || !ids.contains(edge.target)) {
        throw ArgumentError.value(edge.id, 'edges', 'unknown edge endpoint');
      }
    }
  }
}
