import 'constraints.dart';

enum LayoutQuality { draft, defaultQuality, proof }

enum SamplingType { greedy, random }

enum PackingUtility { adjustedFullness, weighted }

typedef TilingComparator = int Function(String firstNodeId, String secondNodeId);

/// Configuration corresponding to the public options of cytoscape-fcose 2.2.0.
final class FcoseOptions {
  const FcoseOptions({
    this.quality = LayoutQuality.defaultQuality,
    this.randomize = true,
    this.seed = 1,
    this.maxIterations = 2500,
    this.sampleSize = 25,
    this.samplingType = SamplingType.greedy,
    this.nodeSeparation = 75,
    this.powerIterationTolerance = 1e-7,
    this.idealEdgeLength = 50,
    this.edgeElasticity = 0.45,
    this.nodeRepulsion = 4500,
    this.gravity = 0.25,
    this.gravityRange = 3.8,
    this.compoundGravity = 1,
    this.compoundGravityRange = 1.5,
    this.nestingFactor = 0.1,
    this.compoundPadding = 10,
    this.uniformNodeDimensions = false,
    this.packComponents = true,
    this.componentSeparation = 80,
    this.desiredPackingAspectRatio = 1,
    this.polyominoGridSizeFactor = 1,
    this.packingUtility = PackingUtility.adjustedFullness,
    this.tile = true,
    this.tilingCompareBy,
    this.tilingPaddingVertical = 10,
    this.tilingPaddingHorizontal = 10,
    this.initialEnergyOnIncremental = 0.3,
    this.minTemperature = 0.04,
    this.fixedNodes = const [],
    this.alignment = const AlignmentConstraint(),
    this.relativePlacements = const [],
  });

  final LayoutQuality quality;
  final bool randomize;
  final int seed;
  final int maxIterations;
  final int sampleSize;
  final SamplingType samplingType;
  final double nodeSeparation;
  final double powerIterationTolerance;
  final double idealEdgeLength;
  final double edgeElasticity;
  final double nodeRepulsion;
  final double gravity;
  final double gravityRange;
  final double compoundGravity;
  final double compoundGravityRange;
  final double nestingFactor;
  final double compoundPadding;

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
  final double polyominoGridSizeFactor;
  final PackingUtility packingUtility;
  final bool tile;

  /// Orders tiled siblings by node ID, using JavaScript `Array.sort` semantics.
  final TilingComparator? tilingCompareBy;

  final double tilingPaddingVertical;
  final double tilingPaddingHorizontal;
  final double initialEnergyOnIncremental;
  final double minTemperature;
  final List<FixedNodeConstraint> fixedNodes;
  final AlignmentConstraint alignment;
  final List<RelativePlacementConstraint> relativePlacements;
}
