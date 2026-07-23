import 'dart:math' as math;

import 'constraints.dart';
import 'geometry.dart';

/// DAG-based enforcement for fCoSE fixed, alignment, and relative constraints.
final class ConstraintHandler {
  ConstraintHandler({
    required this.fixedNodes,
    required this.alignment,
    required this.relativePlacements,
    required this.defaultGap,
    this.seed = 1,
  });

  final List<FixedNodeConstraint> fixedNodes;
  final AlignmentConstraint alignment;
  final List<RelativePlacementConstraint> relativePlacements;
  final double defaultGap;
  final int seed;
  Map<String, double>? _horizontalTemporary;
  Map<String, double>? _verticalTemporary;

  /// Rotates and, when beneficial, reflects a randomized spectral draft toward
  /// its fixed or alignment constraints before those constraints are enforced.
  ///
  /// This is the two-dimensional orthogonal Procrustes step used by cose-base's
  /// `ConstraintHandler`. The transform is applied about the origin to every
  /// node; centering is used only while solving the transformation matrix.
  void transformInitial(Map<String, Offset> positions) {
    final source = <Offset>[];
    final target = <Offset>[];

    if (fixedNodes.length > 1) {
      for (final fixed in fixedNodes) {
        source.add(positions[fixed.nodeId]!);
        target.add(fixed.position);
      }
    } else if (alignment.vertical.isNotEmpty || alignment.horizontal.isNotEmpty) {
      final fixed = fixedNodes.map((item) => item.nodeId).toSet();
      _addAlignmentTargets(positions, alignment.vertical, fixed, source, target, horizontal: true);
      _addAlignmentTargets(positions, alignment.horizontal, fixed, source, target, horizontal: false);
    } else {
      if (!_addRelativePlacementTargets(positions, source, target)) return;
    }

    if (source.length < 2) return;
    final transform = _orthogonalProcrustes(source, target);
    for (final entry in positions.entries.toList()) {
      final point = entry.value;
      positions[entry.key] = Offset(
        point.x * transform.m00 + point.y * transform.m10,
        point.x * transform.m01 + point.y * transform.m11,
      );
    }
    if (alignment.vertical.isNotEmpty || alignment.horizontal.isNotEmpty) {
      _reflectForRelativePlacements(positions);
    }
  }

  bool _addRelativePlacementTargets(Map<String, Offset> positions, List<Offset> source, List<Offset> target) {
    if (relativePlacements.isEmpty) return false;
    final neighbors = <String, Set<String>>{};
    for (final constraint in relativePlacements) {
      (neighbors[constraint.first] ??= {}).add(constraint.second);
      (neighbors[constraint.second] ??= {}).add(constraint.first);
    }
    final components = <List<String>>[];
    final visited = <String>{};
    for (final start in neighbors.keys) {
      if (!visited.add(start)) continue;
      final component = <String>[];
      final queue = <String>[start];
      for (var index = 0; index < queue.length; index++) {
        final node = queue[index];
        component.add(node);
        for (final neighbor in neighbors[node]!) {
          if (visited.add(neighbor)) queue.add(neighbor);
        }
      }
      components.add(component);
    }
    final largest = components.reduce((first, second) => second.length > first.length ? second : first);
    if (largest.length < neighbors.length / 2) {
      _reflectForRelativePlacements(positions);
      return false;
    }

    final memberSet = largest.toSet();
    final constraints = relativePlacements
        .where((constraint) => memberSet.contains(constraint.first) && memberSet.contains(constraint.second))
        .toList();
    _reflectForRelativePlacements(positions, constraints);
    final horizontal = _relativeTargetPositions(
      positions,
      constraints.where((constraint) => constraint.axis == RelativePlacementAxis.horizontal),
      horizontal: true,
    );
    final vertical = _relativeTargetPositions(
      positions,
      constraints.where((constraint) => constraint.axis == RelativePlacementAxis.vertical),
      horizontal: false,
    );
    for (final node in largest) {
      final point = positions[node]!;
      source.add(point);
      target.add(Offset(horizontal[node] ?? point.x, vertical[node] ?? point.y));
    }
    return true;
  }

  Map<String, double> _relativeTargetPositions(
    Map<String, Offset> positions,
    Iterable<RelativePlacementConstraint> constraints, {
    required bool horizontal,
  }) {
    final outgoing = <String, List<({String target, double gap})>>{};
    final indegree = <String, int>{};
    for (final constraint in constraints) {
      indegree.putIfAbsent(constraint.first, () => 0);
      indegree[constraint.second] = (indegree[constraint.second] ?? 0) + 1;
      (outgoing[constraint.first] ??= []).add((target: constraint.second, gap: constraint.gap ?? defaultGap));
    }
    if (indegree.isEmpty) return const {};
    double coordinate(String node) => horizontal ? positions[node]!.x : positions[node]!.y;
    final result = <String, double>{
      for (final entry in indegree.entries)
        entry.key: entry.value == 0 ? coordinate(entry.key) : double.negativeInfinity,
    };
    final queue = <String>[...indegree.keys.where((node) => indegree[node] == 0)];
    for (var index = 0; index < queue.length; index++) {
      final current = queue[index];
      for (final edge in outgoing[current] ?? const []) {
        result[edge.target] = math.max(result[edge.target]!, result[current]! + edge.gap);
        indegree[edge.target] = indegree[edge.target]! - 1;
        if (indegree[edge.target] == 0) queue.add(edge.target);
      }
    }
    return result;
  }

  void enforce(Map<String, Offset> positions) {
    final fixed = {for (final item in fixedNodes) item.nodeId: item.position};
    if (fixed.isNotEmpty) {
      var translation = Offset.zero;
      for (final item in fixedNodes) {
        translation += item.position - positions[item.nodeId]!;
      }
      translation /= fixed.length.toDouble();
      for (final entry in positions.entries.toList()) {
        positions[entry.key] = entry.value + translation;
      }
    }
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

  void _addAlignmentTargets(
    Map<String, Offset> positions,
    List<List<String>> groups,
    Set<String> fixed,
    List<Offset> source,
    List<Offset> target, {
    required bool horizontal,
  }) {
    for (final group in groups) {
      final fixedMember = group.where(fixed.contains).firstOrNull;
      final coordinate = fixedMember == null
          ? group
                    .map((node) => horizontal ? positions[node]!.x : positions[node]!.y)
                    .reduce((first, second) => first + second) /
                group.length
          : horizontal
          ? positions[fixedMember]!.x
          : positions[fixedMember]!.y;
      for (final node in group) {
        final point = positions[node]!;
        source.add(point);
        target.add(horizontal ? Offset(coordinate, point.y) : Offset(point.x, coordinate));
      }
    }
  }

  ({double m00, double m01, double m10, double m11}) _orthogonalProcrustes(List<Offset> source, List<Offset> target) {
    final sourceCenter = source.reduce((first, second) => first + second) / source.length.toDouble();
    final targetCenter = target.reduce((first, second) => first + second) / target.length.toDouble();
    var a = 0.0;
    var b = 0.0;
    var c = 0.0;
    var d = 0.0;
    for (var index = 0; index < source.length; index++) {
      final sourcePoint = source[index] - sourceCenter;
      final targetPoint = target[index] - targetCenter;
      a += targetPoint.x * sourcePoint.x;
      b += targetPoint.x * sourcePoint.y;
      c += targetPoint.y * sourcePoint.x;
      d += targetPoint.y * sourcePoint.y;
    }

    final rotationX = a + d;
    final rotationY = b - c;
    final rotationNorm = math.sqrt(rotationX * rotationX + rotationY * rotationY);
    final reflectionX = a - d;
    final reflectionY = b + c;
    final reflectionNorm = math.sqrt(reflectionX * reflectionX + reflectionY * reflectionY);
    if (reflectionNorm > rotationNorm && reflectionNorm > 0) {
      final cosine = reflectionX / reflectionNorm;
      final sine = reflectionY / reflectionNorm;
      return (m00: cosine, m01: sine, m10: sine, m11: -cosine);
    }
    if (rotationNorm > 0) {
      final cosine = rotationX / rotationNorm;
      final sine = rotationY / rotationNorm;
      return (m00: cosine, m01: -sine, m10: sine, m11: cosine);
    }
    return (m00: 1, m01: 0, m10: 0, m11: 1);
  }

  void _reflectForRelativePlacements(Map<String, Offset> positions, [Iterable<RelativePlacementConstraint>? selected]) {
    var reflectHorizontal = 0;
    var keepHorizontal = 0;
    var reflectVertical = 0;
    var keepVertical = 0;
    for (final constraint in selected ?? relativePlacements) {
      final first = positions[constraint.first]!;
      final second = positions[constraint.second]!;
      final reversed = switch (constraint.axis) {
        RelativePlacementAxis.horizontal => first.x >= second.x,
        RelativePlacementAxis.vertical => first.y >= second.y,
      };
      if (constraint.axis == RelativePlacementAxis.horizontal) {
        reversed ? reflectHorizontal++ : keepHorizontal++;
      } else {
        reversed ? reflectVertical++ : keepVertical++;
      }
    }
    final flipX = reflectHorizontal > keepHorizontal;
    final flipY = reflectVertical > keepVertical;
    if (!flipX && !flipY) return;
    for (final entry in positions.entries.toList()) {
      positions[entry.key] = Offset(flipX ? -entry.value.x : entry.value.x, flipY ? -entry.value.y : entry.value.y);
    }
  }

  /// Rewrites one iteration's pending leaf displacements using CoSE's
  /// constraint-aware movement rules. Alignment is applied first, followed by
  /// ordered relaxation of relative-placement groups.
  void constrainDisplacements(
    Map<String, Offset> positions,
    Map<String, Offset> displacements, {
    required int iteration,
  }) {
    final fixed = fixedNodes.map((item) => item.nodeId).toSet();
    final horizontalConstraints = relativePlacements
        .where((constraint) => constraint.axis == RelativePlacementAxis.horizontal)
        .toList();
    final verticalConstraints = relativePlacements
        .where((constraint) => constraint.axis == RelativePlacementAxis.vertical)
        .toList();
    final horizontalOrderLength = _relativeGroupCount(alignment.vertical, horizontalConstraints);
    final verticalOrderLength = _relativeGroupCount(alignment.horizontal, verticalConstraints);
    for (final node in fixed) {
      displacements[node] = Offset.zero;
    }
    _averageAlignedDisplacements(displacements, alignment.vertical, fixed, horizontal: true);
    _averageAlignedDisplacements(displacements, alignment.horizontal, fixed, horizontal: false);
    _relaxDisplacements(
      positions,
      displacements,
      alignment.vertical,
      horizontalConstraints,
      fixed,
      horizontal: true,
      iteration: iteration,
      followingShuffleLength: verticalOrderLength,
    );
    _relaxDisplacements(
      positions,
      displacements,
      alignment.horizontal,
      verticalConstraints,
      fixed,
      horizontal: false,
      iteration: iteration,
      precedingShuffleLength: horizontalOrderLength,
    );
  }

  int _relativeGroupCount(List<List<String>> alignments, List<RelativePlacementConstraint> constraints) {
    final nodeToGroup = <String, String>{};
    for (var index = 0; index < alignments.length; index++) {
      for (final node in alignments[index]) {
        nodeToGroup[node] = '@alignment:$index';
      }
    }
    return {
      for (final constraint in constraints) ...[
        nodeToGroup[constraint.first] ?? constraint.first,
        nodeToGroup[constraint.second] ?? constraint.second,
      ],
    }.length;
  }

  void _averageAlignedDisplacements(
    Map<String, Offset> displacements,
    List<List<String>> alignments,
    Set<String> fixed, {
    required bool horizontal,
  }) {
    for (final group in alignments) {
      final value = group.any(fixed.contains)
          ? 0.0
          : group.map((node) => horizontal ? displacements[node]!.x : displacements[node]!.y).reduce((a, b) => a + b) /
                group.length;
      for (final node in group) {
        final old = displacements[node]!;
        displacements[node] = horizontal ? Offset(value, old.y) : Offset(old.x, value);
      }
    }
  }

  void _relaxDisplacements(
    Map<String, Offset> positions,
    Map<String, Offset> displacements,
    List<List<String>> alignments,
    Iterable<RelativePlacementConstraint> constraints,
    Set<String> fixed, {
    required bool horizontal,
    required int iteration,
    int precedingShuffleLength = 0,
    int followingShuffleLength = 0,
  }) {
    final relevant = constraints.toList();
    if (relevant.isEmpty) return;
    final nodeToGroup = <String, String>{};
    final members = <String, List<String>>{};
    for (var index = 0; index < alignments.length; index++) {
      final group = '@alignment:$index';
      members[group] = alignments[index];
      for (final node in alignments[index]) {
        nodeToGroup[node] = group;
      }
    }
    String groupOf(String node) => nodeToGroup[node] ?? node;

    final order = <String>[];
    final edges = <String, List<({String other, double gap, bool outgoing})>>{};
    for (final constraint in relevant) {
      final source = groupOf(constraint.first);
      final target = groupOf(constraint.second);
      members.putIfAbsent(source, () => [constraint.first]);
      members.putIfAbsent(target, () => [constraint.second]);
      if (!order.contains(source)) order.add(source);
      if (!order.contains(target)) order.add(target);
      final gap = constraint.gap ?? defaultGap;
      (edges[source] ??= []).add((other: target, gap: gap, outgoing: true));
      (edges[target] ??= []).add((other: source, gap: gap, outgoing: false));
    }
    _applyUpstreamShuffle(
      order,
      iteration,
      precedingLength: precedingShuffleLength,
      followingLength: followingShuffleLength,
    );
    double coordinate(Offset value) => horizontal ? value.x : value.y;
    final temporary =
        (horizontal ? _horizontalTemporary : _verticalTemporary) ??
        {for (final group in order) group: coordinate(positions[members[group]!.first]!)};
    if (horizontal) {
      _horizontalTemporary ??= temporary;
    } else {
      _verticalTemporary ??= temporary;
    }
    final fixedGroups = {
      for (final entry in members.entries)
        if (entry.value.any(fixed.contains)) entry.key,
    };

    for (final group in order) {
      var displacement = fixedGroups.contains(group) ? 0.0 : coordinate(displacements[members[group]!.first]!);
      if (!fixedGroups.contains(group)) {
        for (final edge in edges[group] ?? const []) {
          final difference = edge.outgoing
              ? temporary[edge.other]! - temporary[group]! - displacement
              : temporary[group]! - temporary[edge.other]! + displacement;
          if (difference < edge.gap) {
            final correction = edge.gap - difference;
            displacement += edge.outgoing ? -correction : correction;
          }
        }
      }
      temporary[group] = temporary[group]! + displacement;
      for (final node in members[group]!) {
        final old = displacements[node]!;
        displacements[node] = horizontal ? Offset(displacement, old.y) : Offset(old.x, displacement);
      }
    }
  }

  void _applyUpstreamShuffle(
    List<String> order,
    int iteration, {
    required int precedingLength,
    required int followingLength,
  }) {
    if (iteration < 10 || order.length < 2) return;
    final random = _Mulberry32(seed);
    for (var checkpoint = 10; checkpoint <= iteration; checkpoint += 10) {
      _consumeShuffle(random, precedingLength);
      for (var index = order.length - 1; index >= 2 * order.length / 3; index--) {
        final swapWith = (random.nextDouble() * (index + 1)).floor();
        final value = order[index];
        order[index] = order[swapWith];
        order[swapWith] = value;
      }
      _consumeShuffle(random, followingLength);
    }
  }

  void _consumeShuffle(_Mulberry32 random, int length) {
    for (var index = length - 1; index >= 2 * length / 3; index--) {
      random.nextDouble();
    }
  }

  void _enforceAxis(
    Map<String, Offset> positions,
    Map<String, Offset> fixed,
    List<List<String>> alignments,
    Iterable<RelativePlacementConstraint> constraints, {
    required bool horizontal,
  }) {
    final relevantConstraints = constraints.toList();
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
    final undirected = <String, Set<String>>{};
    for (final constraint in relevantConstraints) {
      final source = groupOf(constraint.first);
      final target = groupOf(constraint.second);
      final gap = constraint.gap ?? defaultGap;
      if (source == target) {
        throw ArgumentError.value(constraint, 'relativePlacements', 'positive gap inside an alignment set');
      }
      (outgoing[source] ??= []).add((target: target, gap: gap));
      indegree[target] = (indegree[target] ?? 0) + 1;
      (undirected[source] ??= {}).add(target);
      (undirected[target] ??= {}).add(source);
    }
    final components = <Set<String>>[];
    final visited = <String>{};
    for (final start in undirected.keys) {
      if (!visited.add(start)) continue;
      final component = <String>{start};
      final pending = <String>[start];
      for (var index = 0; index < pending.length; index++) {
        for (final neighbor in undirected[pending[index]]!) {
          if (visited.add(neighbor)) {
            component.add(neighbor);
            pending.add(neighbor);
          }
        }
      }
      components.add(component);
    }
    final originalIndegree = Map<String, int>.of(indegree);
    for (final component in components) {
      final sources = component.where((group) => originalIndegree[group] == 0).toList();
      for (final group in component) {
        values[group] = double.negativeInfinity;
      }
      final fixedSources = sources.where(fixedGroups.containsKey).toList();
      if (fixedSources.isNotEmpty) {
        final sourceCenter =
            fixedSources.map((source) => fixedGroups[source]!).reduce((a, b) => a + b) / fixedSources.length;
        for (final source in sources) {
          values[source] = fixedGroups[source] ?? sourceCenter;
        }
      } else {
        final sourceCenter = sources.map((source) => initial[source]!).reduce((a, b) => a + b) / sources.length;
        for (final source in sources) {
          values[source] = sourceCenter;
        }
      }
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

    final past = {
      for (final group in members.keys) group: <String>{group},
    };
    for (final source in order) {
      for (final edge in outgoing[source] ?? const []) {
        final required = values[source]! + edge.gap;
        if (fixedGroups.containsKey(edge.target)) {
          final fixedPosition = fixedGroups[edge.target]!;
          values[edge.target] = fixedPosition;
          if (fixedPosition < required) {
            final shift = required - fixedPosition;
            for (final predecessor in past[source]!) {
              values[predecessor] = values[predecessor]! - shift;
            }
          }
        } else if (values[edge.target]! < required) {
          values[edge.target] = required;
        }
        past[edge.target] = {...past[source]!, ...past[edge.target]!};
      }
    }

    // cose-base readjusts each fixed-free sink predecessor set around its
    // pre-enforcement midpoint. Sets with a common earliest predecessor are
    // merged, including fixed and fixed-free branches in the same weak DAG.
    final adjustableComponents = <Set<String>>[];
    for (final sink in members.keys.where((group) => (outgoing[group] ?? const []).isEmpty)) {
      final predecessors = past[sink]!;
      if (predecessors.any(fixedGroups.containsKey)) continue;
      final existing = adjustableComponents.indexWhere((component) => component.contains(predecessors.first));
      if (existing == -1) {
        adjustableComponents.add({...predecessors});
      } else {
        adjustableComponents[existing].addAll(predecessors);
      }
    }
    for (final component in adjustableComponents) {
      final before = component.map((group) => initial[group]!);
      final after = component.map((group) => values[group]!);
      final shift =
          (before.reduce(math.min) + before.reduce(math.max) - after.reduce(math.min) - after.reduce(math.max)) / 2;
      for (final group in component) {
        values[group] = values[group]! + shift;
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

/// Mermaid's seeded `Math.random` replacement from `architectureSeed.ts`.
final class _Mulberry32 {
  _Mulberry32(int seed) : _state = seed & _mask;

  static const _mask = 0xffffffff;
  int _state;

  double nextDouble() {
    _state = (_state + 0x6d2b79f5) & _mask;
    var value = _state;
    value = _multiply32(value ^ (value >>> 15), value | 1);
    value ^= (value + _multiply32(value ^ (value >>> 7), value | 61)) & _mask;
    return ((value ^ (value >>> 14)) & _mask) / 0x100000000;
  }

  int _multiply32(int first, int second) => (first * second) & _mask;
}
