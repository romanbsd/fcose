import 'constraints.dart';
import 'model.dart';

enum LayoutQuality { draft, defaultQuality, proof }

/// Constraint-pipeline stage exposed by fCoSE for debugging.
enum LayoutStep { all, transformed, enforced, cose }

enum SamplingType { greedy, random }

enum PackingUtility { adjustedFullness, weighted }

typedef TilingComparator = int Function(String firstNodeId, String secondNodeId);
typedef NodeRepulsionResolver = double Function(FcoseNode node);
typedef IdealEdgeLengthResolver = double Function(FcoseEdge edge);
typedef EdgeElasticityResolver = double Function(FcoseEdge edge);
typedef TilingPaddingResolver = double Function();

/// Configuration corresponding to the public options of cytoscape-fcose 2.2.0.
final class FcoseOptions {
  const FcoseOptions({
    this.quality = LayoutQuality.defaultQuality,
    this.step = LayoutStep.all,
    this.randomize = true,
    this.seed = 1,
    this.maxIterations = 2500,
    this.sampleSize = 25,
    this.samplingType = SamplingType.greedy,
    this.nodeSeparation = 75,
    this.powerIterationTolerance = 1e-7,
    this.idealEdgeLength = 50,
    this.idealEdgeLengthFor,
    this.edgeElasticity = 0.45,
    this.edgeElasticityFor,
    this.nodeRepulsion = 4500,
    this.nodeRepulsionFor,
    this.gravity = 0.25,
    this.gravityRange = 3.8,
    this.compoundGravity = 1,
    this.compoundGravityRange = 1.5,
    this.nestingFactor = 0.1,
    this.compoundPadding = 10,
    this.compoundBorderWidth = 1,
    this.uniformNodeDimensions = false,
    this.packComponents = true,
    this.componentSeparation = 80,
    this.desiredPackingAspectRatio = 1,
    this.polyominoGridSizeFactor = 1,
    this.packingUtility = PackingUtility.adjustedFullness,
    this.tile = true,
    this.tilingCompareBy,
    this.tilingPaddingVertical = 10,
    this.tilingPaddingVerticalFor,
    this.tilingPaddingHorizontal = 10,
    this.tilingPaddingHorizontalFor,
    this.initialEnergyOnIncremental = 0.3,
    this.minTemperature = 0.04,
    this.fixedNodes = const [],
    this.alignment = const AlignmentConstraint(),
    this.relativePlacements = const [],
  });

  final LayoutQuality quality;

  /// Selects how far the constraint and CoSE pipeline runs.
  ///
  /// Non-[LayoutStep.all] values are upstream-compatible debugging stages.
  final LayoutStep step;
  final bool randomize;
  final int seed;
  final int maxIterations;
  final int sampleSize;
  final SamplingType samplingType;
  final double nodeSeparation;
  final double powerIterationTolerance;
  final double idealEdgeLength;

  /// Resolves fCoSE's function-valued `idealEdgeLength(edge)` option.
  ///
  /// An edge's explicit [FcoseEdge.idealLength] takes precedence.
  final IdealEdgeLengthResolver? idealEdgeLengthFor;

  final double edgeElasticity;

  /// Resolves fCoSE's function-valued `edgeElasticity(edge)` option.
  ///
  /// An edge's explicit [FcoseEdge.elasticity] takes precedence.
  final EdgeElasticityResolver? edgeElasticityFor;

  final double nodeRepulsion;

  /// Resolves fCoSE's function-valued `nodeRepulsion(node)` option.
  ///
  /// A node's explicit [FcoseNode.nodeRepulsion] takes precedence.
  final NodeRepulsionResolver? nodeRepulsionFor;

  final double gravity;
  final double gravityRange;
  final double compoundGravity;
  final double compoundGravityRange;
  final double nestingFactor;

  /// Fallback padding for compound nodes without [FcoseNode.padding].
  final double compoundPadding;

  /// Border drawn around a compound node, in logical pixels.
  ///
  /// The default is the width Cytoscape's `:parent` rule uses. fCoSE never
  /// applies a force to it, but it asks the host for the bounding box of the
  /// graph before the run and puts the result back on that box's center, and
  /// the host measures a compound's border there. Half of it lies outside the
  /// compound, so a graph mixing compounds with plain nodes settles half a
  /// border away from where it would otherwise.
  final double compoundBorderWidth;

  /// Uses center-to-center spring and repulsion distances for leaf pairs.
  ///
  /// This matches fCoSE's performance hint and assumes leaf dimensions are
  /// sufficiently uniform; it does not resize nodes.
  final bool uniformNodeDimensions;

  /// Enables layout-utilities-style packing of disconnected components.
  final bool packComponents;

  /// `componentSpacing` passed to the component packer, in logical pixels.
  final double componentSeparation;

  /// Target width/height ratio for randomized polyomino packing.
  final double desiredPackingAspectRatio;

  /// Multiplier for the average-node-dimension polyomino grid size.
  ///
  /// layout-utilities measures its packing grid in cells of
  /// `averageNodeDimension * polyominoGridSizeFactor` pixels, and makes the
  /// grid twice as wide and twice as tall as every component laid end to end.
  /// The cell count therefore grows with the square of the component count and
  /// shrinks only with the node size, so a graph of many small components far
  /// apart asks for a grid orders of magnitude larger than the packing it ends
  /// up producing. Raising this factor is the way out: it costs packing
  /// tightness and buys back cells quadratically. A request too large to
  /// allocate is refused with an [ArgumentError] rather than attempted.
  final double polyominoGridSizeFactor;
  final PackingUtility packingUtility;
  final bool tile;

  /// Orders tiled siblings by node ID, using JavaScript `Array.sort` semantics.
  final TilingComparator? tilingCompareBy;

  final double tilingPaddingVertical;

  /// Resolves upstream's function-valued vertical tiling padding option.
  ///
  /// The callback overrides [tilingPaddingVertical] and is evaluated once per
  /// non-draft layout run.
  final TilingPaddingResolver? tilingPaddingVerticalFor;
  final double tilingPaddingHorizontal;

  /// Resolves upstream's function-valued horizontal tiling padding option.
  ///
  /// The callback overrides [tilingPaddingHorizontal] and is evaluated once
  /// per non-draft layout run.
  final TilingPaddingResolver? tilingPaddingHorizontalFor;
  final double initialEnergyOnIncremental;
  final double minTemperature;
  final List<FixedNodeConstraint> fixedNodes;
  final AlignmentConstraint alignment;
  final List<RelativePlacementConstraint> relativePlacements;
}
