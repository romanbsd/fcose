import 'constraints.dart';
import 'geometry.dart';

/// DAG-based enforcement for fCoSE fixed, alignment, and relative constraints.
final class ConstraintHandler {
  const ConstraintHandler({
    required this.fixedNodes,
    required this.alignment,
    required this.relativePlacements,
    required this.defaultGap,
  });

  final List<FixedNodeConstraint> fixedNodes;
  final AlignmentConstraint alignment;
  final List<RelativePlacementConstraint> relativePlacements;
  final double defaultGap;

  void enforce(Map<String, Offset> positions) {
    final fixed = {for (final item in fixedNodes) item.nodeId: item.position};
    _enforceAxis(
      positions,
      fixed,
      alignment.vertical,
      relativePlacements.where((constraint) => constraint.axis == RelativePlacementAxis.horizontal),
      horizontal: true,
    );
    _enforceAxis(
      positions,
      fixed,
      alignment.horizontal,
      relativePlacements.where((constraint) => constraint.axis == RelativePlacementAxis.vertical),
      horizontal: false,
    );
    for (final item in fixedNodes) {
      positions[item.nodeId] = item.position;
    }
  }

  void _enforceAxis(
    Map<String, Offset> positions,
    Map<String, Offset> fixed,
    List<List<String>> alignments,
    Iterable<RelativePlacementConstraint> constraints, {
    required bool horizontal,
  }) {
    final nodeToGroup = <String, String>{};
    final members = <String, Set<String>>{};
    for (var i = 0; i < alignments.length; i++) {
      final group = '@alignment:$i';
      members[group] = alignments[i].toSet();
      for (final node in alignments[i]) {
        final previous = nodeToGroup[node];
        if (previous != null && previous != group) {
          throw ArgumentError.value(node, 'alignment', 'node appears in overlapping alignment sets');
        }
        nodeToGroup[node] = group;
      }
    }
    String groupOf(String node) => nodeToGroup[node] ?? node;
    for (final node in positions.keys) {
      members.putIfAbsent(groupOf(node), () => {node});
    }

    double coordinate(Offset point) => horizontal ? point.x : point.y;
    final initial = <String, double>{};
    final values = <String, double>{};
    final fixedGroups = <String, double>{};
    for (final entry in members.entries) {
      final fixedCoordinates = entry.value.where(fixed.containsKey).map((node) => coordinate(fixed[node]!)).toSet();
      if (fixedCoordinates.length > 1) {
        throw ArgumentError.value(entry.value, 'fixedNodes', 'aligned fixed nodes disagree');
      }
      final value =
          fixedCoordinates.firstOrNull ??
          entry.value.map((node) => coordinate(positions[node]!)).reduce((a, b) => a + b) / entry.value.length;
      initial[entry.key] = value;
      values[entry.key] = value;
      if (fixedCoordinates.isNotEmpty) fixedGroups[entry.key] = value;
    }

    final outgoing = <String, List<({String target, double gap})>>{};
    final indegree = {for (final group in members.keys) group: 0};
    for (final constraint in constraints) {
      final source = groupOf(constraint.first);
      final target = groupOf(constraint.second);
      final gap = constraint.gap ?? defaultGap;
      if (source == target) {
        throw ArgumentError.value(constraint, 'relativePlacements', 'positive gap inside an alignment set');
      }
      (outgoing[source] ??= []).add((target: target, gap: gap));
      indegree[target] = (indegree[target] ?? 0) + 1;
    }
    final queue = <String>[...indegree.keys.where((group) => indegree[group] == 0)];
    final order = <String>[];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      order.add(current);
      for (final edge in outgoing[current] ?? const []) {
        indegree[edge.target] = indegree[edge.target]! - 1;
        if (indegree[edge.target] == 0) queue.add(edge.target);
      }
    }
    if (order.length != indegree.length) {
      throw ArgumentError('relative placement constraints must form a DAG');
    }

    // Pull predecessors back from fixed targets, then push successors forward.
    for (final source in order.reversed) {
      for (final edge in outgoing[source] ?? const []) {
        if (fixedGroups.containsKey(edge.target) && !fixedGroups.containsKey(source)) {
          values[source] = values[source]!.clamp(double.negativeInfinity, values[edge.target]! - edge.gap);
        }
      }
    }
    for (final source in order) {
      for (final edge in outgoing[source] ?? const []) {
        final required = values[source]! + edge.gap;
        if (fixedGroups.containsKey(edge.target)) {
          if (values[edge.target]! < required) {
            throw ArgumentError.value(edge, 'relativePlacements', 'fixed target violates required gap');
          }
        } else if (values[edge.target]! < required) {
          values[edge.target] = required;
        }
      }
    }

    for (final entry in members.entries) {
      final value = values[entry.key] ?? initial[entry.key]!;
      for (final node in entry.value) {
        final old = positions[node]!;
        positions[node] = horizontal ? Offset(value, old.y) : Offset(old.x, value);
      }
    }
  }
}
