import 'dart:math' as math;

import 'geometry.dart';
import 'model.dart';

/// layout-base-style owner graph and inclusion-tree operations.
final class CompoundGraphManager {
  CompoundGraphManager(this.graph);

  final FcoseGraph graph;

  final Map<String, int> _inclusionDepths = {};
  final Map<(String, String), String?> _lowestCommonOwners = {};
  final Map<(String, String?), String> _childrenInOwner = {};
  final Map<String, List<String>> _descendantLeaves = {};
  final Map<String, double> _estimatedSizes = {};
  final Map<String?, double> _estimatedOwnerSizes = {};
  final Map<String?, bool> _ownerConnectivity = {};

  late final Map<String, int> _connectedEdgeCounts = _buildConnectedEdgeCounts();
  late final List<FcoseNode> _orderedNodes = List.unmodifiable(_buildLayoutOrder());
  late final List<FcoseNode> _compoundBoundsOrder = List.unmodifiable(_buildCompoundBoundsOrder());

  String? ownerOf(String nodeId) => graph.nodeById[nodeId]!.parentId;

  Iterable<FcoseNode> siblings(String nodeId) => graph.childrenByParent[ownerOf(nodeId)] ?? const [];

  int inclusionDepthOf(String nodeId) => _inclusionDepths.putIfAbsent(nodeId, () {
    var depth = 1;
    var owner = ownerOf(nodeId);
    while (owner != null) {
      depth++;
      owner = ownerOf(owner);
    }
    return depth;
  });

  /// The compound node whose child graph contains both endpoints, or `null`
  /// for the root graph.
  String? lowestCommonOwner(String first, String second) {
    final key = (first, second);
    if (_lowestCommonOwners.containsKey(key)) return _lowestCommonOwners[key];
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
    _lowestCommonOwners[key] = current;
    return current;
  }

  /// Direct child of [ownerId]'s graph containing [nodeId].
  String childInOwner(String nodeId, String? ownerId) {
    final key = (nodeId, ownerId);
    final cached = _childrenInOwner[key];
    if (cached != null) return cached;
    var current = nodeId;
    while (ownerOf(current) != ownerId) {
      current = ownerOf(current)!;
    }
    _childrenInOwner[key] = current;
    return current;
  }

  bool isCompound(String nodeId) => graph.childrenByParent[nodeId]?.isNotEmpty ?? false;

  /// Leaf used for a compound endpoint in fCoSE's spectral graph.
  ///
  /// Upstream follows the first child while a level contains only compounds,
  /// then chooses the first direct leaf with the fewest original incident
  /// edges. Ties therefore preserve Cytoscape node order.
  String spectralRepresentative(String nodeId) {
    final initialChildren = graph.childrenByParent[nodeId];
    if (initialChildren == null || initialChildren.isEmpty) return nodeId;
    var children = initialChildren;
    while (children.every((node) => isCompound(node.id))) {
      children = graph.childrenByParent[children.first.id]!;
    }
    final leaves = children.where((node) => !isCompound(node.id));
    var representative = leaves.first;
    var minimumDegree = _connectedEdgeCount(representative.id);
    for (final leaf in leaves.skip(1)) {
      final degree = _connectedEdgeCount(leaf.id);
      if (degree < minimumDegree) {
        representative = leaf;
        minimumDegree = degree;
      }
    }
    return representative.id;
  }

  int _connectedEdgeCount(String nodeId) => _connectedEdgeCounts[nodeId]!;

  /// Nodes in layout-base `LGraphManager.getAllNodes()` order.
  ///
  /// Each owner graph contributes all of its direct children before child
  /// graphs are visited in compound-node order.
  List<FcoseNode> get layoutOrder => _orderedNodes;

  List<FcoseNode> _buildLayoutOrder() {
    final result = <FcoseNode>[];

    void visit(String? ownerId) {
      final children = graph.childrenByParent[ownerId] ?? const [];
      result.addAll(children);
      for (final child in children.where((node) => isCompound(node.id))) {
        visit(child.id);
      }
    }

    visit(null);
    return result;
  }

  Map<String, int> _buildConnectedEdgeCounts() {
    final result = {for (final node in graph.nodes) node.id: 0};
    for (final edge in graph.edges) {
      result[edge.source] = result[edge.source]! + 1;
      if (edge.target != edge.source) {
        result[edge.target] = result[edge.target]! + 1;
      }
    }
    return result;
  }

  List<FcoseNode> _buildCompoundBoundsOrder() {
    final resolved = graph.leafNodes.map((node) => node.id).toSet();
    final pending = graph.nodes.where((node) => isCompound(node.id)).toSet();
    final result = <FcoseNode>[];
    while (pending.isNotEmpty) {
      final node = pending.firstWhere(
        (candidate) => graph.childrenByParent[candidate.id]!.every((child) => resolved.contains(child.id)),
      );
      pending.remove(node);
      resolved.add(node.id);
      result.add(node);
    }
    return result;
  }

  List<String> _descendantLeafList(String nodeId) {
    final cached = _descendantLeaves[nodeId];
    if (cached != null) return cached;
    final children = graph.childrenByParent[nodeId];
    final leaves = children == null || children.isEmpty
        ? <String>[nodeId]
        : <String>[for (final child in children) ..._descendantLeafList(child.id)];
    return _descendantLeaves[nodeId] = List.unmodifiable(leaves);
  }

  /// Static size estimate used by layout-base's smart inter-graph edge
  /// lengths. Leaf size is mean width/height; a compound is the sum of its
  /// children's estimates divided by the square root of its child count.
  double estimatedSizeOf(String nodeId) {
    final cached = _estimatedSizes[nodeId];
    if (cached != null) return cached;
    final children = graph.childrenByParent[nodeId];
    if (children == null || children.isEmpty) {
      final node = graph.nodeById[nodeId]!;
      return _estimatedSizes[nodeId] = (node.width + node.height) / 2;
    }
    final sum = children.fold(0.0, (value, child) => value + estimatedSizeOf(child.id));
    return _estimatedSizes[nodeId] = sum / math.sqrt(children.length);
  }

  /// Static size estimate of an owner graph, matching
  /// layout-base's `LGraph.calcEstimatedSize`.
  double estimatedSizeOfOwner(String? ownerId) {
    if (_estimatedOwnerSizes.containsKey(ownerId)) {
      return _estimatedOwnerSizes[ownerId]!;
    }
    final children = graph.childrenByParent[ownerId] ?? const [];
    if (children.isEmpty) {
      return _estimatedOwnerSizes[ownerId] = _emptyCompoundNodeSize;
    }
    final sum = children.fold(0.0, (value, child) => value + estimatedSizeOf(child.id));
    return _estimatedOwnerSizes[ownerId] = sum == 0 ? _emptyCompoundNodeSize : sum / math.sqrt(children.length);
  }

  bool isOwnerConnected(String? ownerId) {
    if (_ownerConnectivity.containsKey(ownerId)) {
      return _ownerConnectivity[ownerId]!;
    }
    final children = graph.childrenByParent[ownerId] ?? const [];
    if (children.length < 2) {
      return _ownerConnectivity[ownerId] = true;
    }
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
    return _ownerConnectivity[ownerId] = visited.length == childIds.length;
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

  List<String> descendantLeaves(String nodeId) => _descendantLeafList(nodeId);

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
    for (final node in _compoundBoundsOrder) {
      final children = graph.childrenByParent[node.id]!;
      var bounds = result[children.first.id]!;
      for (final child in children.skip(1)) {
        bounds = bounds.union(result[child.id]!);
      }
      final padded = bounds.inflate(node.padding ?? padding);
      var left = padded.left;
      var top = padded.top;
      var width = padded.width;
      var height = padded.height;

      if (node.labelWidth > 0) {
        switch (node.labelHorizontalPosition) {
          case FcoseLabelHorizontalPosition.left:
            left -= node.labelWidth;
            width += node.labelWidth;
          case FcoseLabelHorizontalPosition.center when node.labelWidth > width:
            left -= (node.labelWidth - width) / 2;
            width = node.labelWidth;
          case FcoseLabelHorizontalPosition.center:
            break;
          case FcoseLabelHorizontalPosition.right:
            width += node.labelWidth;
        }
      }
      if (node.labelHeight > 0) {
        switch (node.labelVerticalPosition) {
          case FcoseLabelVerticalPosition.top:
            top -= node.labelHeight;
            height += node.labelHeight;
          case FcoseLabelVerticalPosition.center when node.labelHeight > height:
            top -= (node.labelHeight - height) / 2;
            height = node.labelHeight;
          case FcoseLabelVerticalPosition.center:
            break;
          case FcoseLabelVerticalPosition.bottom:
            height += node.labelHeight;
        }
      }
      result[node.id] = Rect(left, top, width, height);
    }
    return result;
  }
}

/// layout-base `LayoutConstants.EMPTY_COMPOUND_NODE_SIZE`, in pixels.
const _emptyCompoundNodeSize = 40.0;
