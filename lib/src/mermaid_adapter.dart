import 'model.dart';
import 'options.dart';

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
    this.nodeSeparation = 75,
    this.numIter = 2500,
    this.randomize = false,
    this.seed = 1,
  });

  final double iconSize;
  final double idealEdgeLengthMultiplier;
  final double edgeElasticity;
  final double nodeSeparation;
  final int numIter;
  final bool randomize;
  final int seed;

  FcoseOptions get options => FcoseOptions(
    quality: LayoutQuality.proof,
    randomize: randomize,
    seed: seed,
    maxIterations: numIter,
    nodeSeparation: nodeSeparation,
    idealEdgeLength: idealEdgeLengthMultiplier * iconSize,
    edgeElasticity: edgeElasticity,
  );

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
          idealLength: edge.idealLength ?? (sameParent ? idealEdgeLengthMultiplier * iconSize : 0.5 * iconSize),
          elasticity: edge.elasticity ?? (sameParent ? edgeElasticity : 0.001),
        );
      }),
    );
  }
}
