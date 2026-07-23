import 'package:fcose/fcose.dart';

void main() {
  final graph = FcoseGraph(
    nodes: const [
      FcoseNode(id: 'cluster'),
      FcoseNode(id: 'api', width: 72, height: 48, parentId: 'cluster'),
      FcoseNode(id: 'database', width: 72, height: 48, parentId: 'cluster'),
      FcoseNode(id: 'client', width: 72, height: 48),
    ],
    edges: const [
      FcoseEdge(id: 'request', source: 'client', target: 'api', idealLength: 80),
      FcoseEdge(id: 'query', source: 'api', target: 'database', idealLength: 80),
    ],
  );

  final result = FcoseLayout(
    options: const FcoseOptions(quality: LayoutQuality.proof, seed: 7, idealEdgeLength: 80, maxIterations: 1000),
  ).run(graph);

  for (final node in graph.nodes) {
    print('${node.id}: ${result.rectOf(node.id)}');
  }
}
