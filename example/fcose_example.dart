import 'package:fcose/fcose.dart';

void main() {
  // A Mermaid renderer measures labels/icons first, then supplies their sizes.
  final graph = FcoseGraph(
    nodes: const [
      FcoseNode(id: 'cloud', width: 140, height: 90),
      FcoseNode(id: 'api', width: 72, height: 48, parentId: 'cloud', position: Offset(50, 50)),
      FcoseNode(id: 'db', width: 72, height: 48, parentId: 'cloud', position: Offset(150, 50)),
      FcoseNode(id: 'client', width: 72, height: 48, position: Offset(50, 150)),
    ],
    edges: const [
      FcoseEdge(id: 'request', source: 'client', target: 'api'),
      FcoseEdge(id: 'query', source: 'api', target: 'db'),
    ],
  );

  final configuration =
      const MermaidFcoseAdapter(
        iconSize: 72,
        nodeSeparation: 80,
        idealEdgeLengthMultiplier: 1.2,
        edgeElasticity: 0.45,
        numIter: 1000,
      ).configureArchitecture(
        graph,
        directionalEdges: const [
          MermaidDirectionalEdge(
            source: 'client',
            sourceDirection: MermaidArchitectureDirection.top,
            target: 'api',
            targetDirection: MermaidArchitectureDirection.bottom,
          ),
          MermaidDirectionalEdge(
            source: 'api',
            sourceDirection: MermaidArchitectureDirection.right,
            target: 'db',
            targetDirection: MermaidArchitectureDirection.left,
          ),
        ],
      );
  final result = configuration.runMermaidArchitecture();

  for (final node in graph.nodes) {
    print('${node.id}: ${result.rectOf(node.id)}');
  }
}
