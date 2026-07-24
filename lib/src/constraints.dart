import 'geometry.dart';

final class FixedNodeConstraint {
  const FixedNodeConstraint(this.nodeId, this.position);
  final String nodeId;
  final Offset position;
}

/// IDs sharing an entry in [vertical] get the same x coordinate; IDs sharing
/// an entry in [horizontal] get the same y coordinate.
final class AlignmentConstraint {
  const AlignmentConstraint({this.vertical = const [], this.horizontal = const []});
  final List<List<String>> vertical;
  final List<List<String>> horizontal;
}

enum RelativePlacementAxis { horizontal, vertical }

final class RelativePlacementConstraint {
  const RelativePlacementConstraint.horizontal(this.first, this.second, {this.gap})
    : axis = RelativePlacementAxis.horizontal;

  const RelativePlacementConstraint.vertical(this.first, this.second, {this.gap})
    : axis = RelativePlacementAxis.vertical;

  /// Left node for horizontal constraints, or top node for vertical constraints.
  final String first;

  /// Right node for horizontal constraints, or bottom node for vertical constraints.
  final String second;
  final RelativePlacementAxis axis;

  /// Required center-to-center separation on [axis].
  ///
  /// When omitted, fCoSE uses the average resolved ideal edge length plus half
  /// of each endpoint's size on the constrained axis.
  final double? gap;
}
