import 'dart:math' as math;

import 'geometry.dart';
import 'model.dart';

/// layout-base-style owner graph and inclusion-tree operations.
final class CompoundGraphManager {
  CompoundGraphManager(this.graph);

  final FcoseGraph graph;

  String? ownerOf(String nodeId) => graph.nodeById[nodeId]!.parentId;

  Iterable<FcoseNode> siblings(String nodeId) => graph.childrenByParent[ownerOf(nodeId)] ?? const [];

  int inclusionDepthOf(String nodeId) {
    var depth = 1;
    var owner = ownerOf(nodeId);
    while (owner != null) {
      depth++;
      owner = ownerOf(owner);
    }
    return depth;
  }

  /// The compound node whose child graph contains both endpoints, or `null`
  /// for the root graph.
  String? lowestCommonOwner(String first, String second) {
    final firstOwners = <String?>{};
    String? current = ownerOf(first);
    while (true) {
      firstOwners.add(current);
      if (current == null) break;
      current = ownerOf(current);
    }
    current = ownerOf(second);
    while (!firstOwners.contains(current)) {
      current = ownerOf(current!);
    }
    return current;
  }

  /// Direct child of [ownerId]'s graph containing [nodeId].
  String childInOwner(String nodeId, String? ownerId) {
    var current = nodeId;
    while (ownerOf(current) != ownerId) {
      current = ownerOf(current)!;
    }
    return current;
  }

  bool isCompound(String nodeId) => graph.childrenByParent[nodeId]?.isNotEmpty ?? false;

  /// Nodes in layout-base `LGraphManager.getAllNodes()` order.
  ///
  /// Each owner graph contributes all of its direct children before child
  /// graphs are visited in compound-node order.
  Iterable<FcoseNode> get layoutOrder sync* {
    Iterable<FcoseNode> visit(String? ownerId) sync* {
      final children = graph.childrenByParent[ownerId] ?? const [];
      yield* children;
      for (final child in children.where((node) => isCompound(node.id))) {
        yield* visit(child.id);
      }
    }

    yield* visit(null);
  }

  /// Static size estimate used by layout-base's smart inter-graph edge
  /// lengths. Leaf size is mean width/height; a compound is the sum of its
  /// children's estimates divided by the square root of its child count.
  double estimatedSizeOf(String nodeId) {
    final children = graph.childrenByParent[nodeId];
    if (children == null || children.isEmpty) {
      final node = graph.nodeById[nodeId]!;
      return (node.width + node.height) / 2;
    }
    final sum = children.fold(0.0, (value, child) => value + estimatedSizeOf(child.id));
    return sum / math.sqrt(children.length);
  }

  /// Static size estimate of an owner graph, matching
  /// layout-base's `LGraph.calcEstimatedSize`.
  double estimatedSizeOfOwner(String? ownerId) {
    final children = graph.childrenByParent[ownerId] ?? const [];
    if (children.isEmpty) return _emptyCompoundNodeSize;
    final sum = children.fold(0.0, (value, child) => value + estimatedSizeOf(child.id));
    return sum == 0 ? _emptyCompoundNodeSize : sum / math.sqrt(children.length);
  }

  bool isOwnerConnected(String? ownerId) {
    final children = graph.childrenByParent[ownerId] ?? const [];
    if (children.length < 2) return true;
    final childIds = children.map((node) => node.id).toSet();
    final adjacency = {for (final id in childIds) id: <String>{}};
    for (final edge in graph.edges) {
      if (lowestCommonOwner(edge.source, edge.target) != ownerId) continue;
      final source = childInOwner(edge.source, ownerId);
      final target = childInOwner(edge.target, ownerId);
      if (source == target) continue;
      adjacency[source]!.add(target);
      adjacency[target]!.add(source);
    }
    final visited = <String>{};
    final pending = <String>[childIds.first];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!visited.add(current)) continue;
      pending.addAll(adjacency[current]!.where((id) => !visited.contains(id)));
    }
    return visited.length == childIds.length;
  }

  Rect ownerBounds(String? ownerId, Map<String, Rect> rectangles) {
    final children = graph.childrenByParent[ownerId] ?? const [];
    if (children.isEmpty) throw StateError('Owner graph has no nodes: $ownerId');
    var bounds = rectangles[children.first.id]!;
    for (final child in children.skip(1)) {
      bounds = bounds.union(rectangles[child.id]!);
    }
    return bounds;
  }

  Iterable<String> descendantLeaves(String nodeId) sync* {
    final children = graph.childrenByParent[nodeId];
    if (children == null || children.isEmpty) {
      yield nodeId;
      return;
    }
    for (final child in children) {
      yield* descendantLeaves(child.id);
    }
  }

  void translate(String nodeId, Offset displacement, Map<String, Offset> leafPositions) {
    for (final leaf in descendantLeaves(nodeId)) {
      leafPositions[leaf] = leafPositions[leaf]! + displacement;
    }
  }

  /// Recomputes all rectangles bottom-up, just as LGraph.updateBounds(true).
  Map<String, Rect> rectangles(Map<String, Offset> leafPositions, {required double padding}) {
    final result = <String, Rect>{};
    for (final node in graph.leafNodes) {
      result[node.id] = Rect.fromCenter(leafPositions[node.id]!, node.width, node.height);
    }
    final pending = graph.nodes.where((node) => isCompound(node.id)).toSet();
    while (pending.isNotEmpty) {
      final node = pending.firstWhere(
        (candidate) => graph.childrenByParent[candidate.id]!.every((child) => result.containsKey(child.id)),
      );
      final children = graph.childrenByParent[node.id]!;
      var bounds = result[children.first.id]!;
      for (final child in children.skip(1)) {
        bounds = bounds.union(result[child.id]!);
      }
      final padded = bounds.inflate(padding);
      result[node.id] = Rect.fromCenter(
        padded.center,
        padded.width < node.width ? node.width : padded.width,
        padded.height < node.height ? node.height : padded.height,
      );
      pending.remove(node);
    }
    return result;
  }
}

/// layout-base `LayoutConstants.EMPTY_COMPOUND_NODE_SIZE`, in pixels.
const _emptyCompoundNodeSize = 40.0;
