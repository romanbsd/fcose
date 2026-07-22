import 'package:fcose/fcose.dart';

void main() {
  // A Mermaid renderer measures labels/icons first, then supplies their sizes.
  final graph = FcoseGraph(
    nodes: const [
      FcoseNode(id: 'cloud', width: 140, height: 90),
      FcoseNode(id: 'api', width: 72, height: 48, parentId: 'cloud'),
      FcoseNode(id: 'db', width: 72, height: 48, parentId: 'cloud'),
      FcoseNode(id: 'client', width: 72, height: 48),
    ],
    edges: const [
      FcoseEdge(id: 'request', source: 'client', target: 'api'),
      FcoseEdge(id: 'query', source: 'api', target: 'db'),
    ],
  );

  final result = FcoseLayout(
    options: FcoseOptions.mermaid(randomize: false, nodeSeparation: 80, idealEdgeLengthMultiplier: 1.2, numIter: 1000),
  ).run(graph);

  for (final node in graph.nodes) {
    print('${node.id}: ${result.rectOf(node.id)}');
  }
}
