import 'package:fcose/fcose.dart';
import 'package:test/test.dart';

void main() {
  group('graph model', () {
    test('rejects duplicate nodes and unknown edge endpoints', () {
      expect(
        () => FcoseGraph(
          nodes: const [
            FcoseNode(id: 'a'),
            FcoseNode(id: 'a'),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => FcoseGraph(
          nodes: const [FcoseNode(id: 'a')],
          edges: const [FcoseEdge(id: 'e', source: 'a', target: 'b')],
        ),
        throwsArgumentError,
      );
    });

    test('rejects missing and cyclic compound parents', () {
      expect(
        () => FcoseGraph(
          nodes: const [FcoseNode(id: 'a', parentId: 'x')],
        ),
        throwsArgumentError,
      );
      expect(
        () => FcoseGraph(
          nodes: const [
            FcoseNode(id: 'a', parentId: 'b'),
            FcoseNode(id: 'b', parentId: 'a'),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('fCoSE layout', () {
    test('is deterministic and separates a connected chain', () {
      final graph = FcoseGraph(
        nodes: const [
          FcoseNode(id: 'a'),
          FcoseNode(id: 'b'),
          FcoseNode(id: 'c'),
        ],
        edges: const [
          FcoseEdge(id: 'ab', source: 'a', target: 'b'),
          FcoseEdge(id: 'bc', source: 'b', target: 'c'),
        ],
      );
      const options = FcoseOptions(seed: 7, maxIterations: 300);
      final first = FcoseLayout(options: options).run(graph);
      final second = FcoseLayout(options: options).run(graph);

      expect(first.positions, second.positions);
      expect(first.positionOf('a').distanceTo(first.positionOf('b')), greaterThan(1));
      expect(first.positionOf('a').isFinite, isTrue);
      expect(first.iterations, inInclusiveRange(1, options.maxIterations));
    });

    test('packs disconnected components without overlap', () {
      final result = FcoseLayout(options: const FcoseOptions(seed: 3, maxIterations: 200)).run(
        FcoseGraph(
          nodes: const [
            FcoseNode(id: 'a'),
            FcoseNode(id: 'b'),
            FcoseNode(id: 'x'),
            FcoseNode(id: 'y'),
          ],
          edges: const [
            FcoseEdge(id: 'ab', source: 'a', target: 'b'),
            FcoseEdge(id: 'xy', source: 'x', target: 'y'),
          ],
        ),
      );
      expect(result.boundsOf({'a', 'b'}).overlaps(result.boundsOf({'x', 'y'})), isFalse);
    });

    test('computes compound bounds around descendants', () {
      final graph = FcoseGraph(
        nodes: const [
          FcoseNode(id: 'p', width: 20, height: 20),
          FcoseNode(id: 'a', parentId: 'p'),
          FcoseNode(id: 'b', parentId: 'p'),
        ],
        edges: const [FcoseEdge(id: 'ab', source: 'a', target: 'b')],
      );
      final result = FcoseLayout().run(graph);
      final parent = result.rectOf('p');
      expect(parent.containsRect(result.rectOf('a')), isTrue);
      expect(parent.containsRect(result.rectOf('b')), isTrue);
    });

    test('enforces fixed, alignment, and relative placement constraints', () {
      final graph = FcoseGraph(
        nodes: const [
          FcoseNode(id: 'a'),
          FcoseNode(id: 'b'),
          FcoseNode(id: 'c'),
        ],
        edges: const [
          FcoseEdge(id: 'ab', source: 'a', target: 'b'),
          FcoseEdge(id: 'bc', source: 'b', target: 'c'),
        ],
      );
      final result = FcoseLayout(
        options: const FcoseOptions(
          seed: 9,
          fixedNodes: [FixedNodeConstraint('a', Offset(10, 20))],
          alignment: AlignmentConstraint(
            vertical: [
              ['a', 'b'],
            ],
          ),
          relativePlacements: [RelativePlacementConstraint.horizontal('b', 'c', gap: 80)],
        ),
      ).run(graph);

      expect(result.positionOf('a'), const Offset(10, 20));
      expect(result.positionOf('b').x, closeTo(10, 1e-8));
      expect(result.positionOf('c').x - result.positionOf('b').x, greaterThanOrEqualTo(80));
    });

    test('draft quality performs spectral-only layout', () {
      final graph = FcoseGraph(
        nodes: List.generate(6, (i) => FcoseNode(id: '$i')),
        edges: List.generate(5, (i) => FcoseEdge(id: 'e$i', source: '$i', target: '${i + 1}')),
      );
      final result = FcoseLayout(options: const FcoseOptions(quality: LayoutQuality.draft, seed: 1)).run(graph);
      expect(result.iterations, 0);
      expect(result.positions.values.every((position) => position.isFinite), isTrue);
    });

    test('preserves supplied geometry when randomization is disabled', () {
      final graph = FcoseGraph(
        nodes: const [
          FcoseNode(id: 'a', position: Offset(5, 7)),
          FcoseNode(id: 'b', position: Offset(105, 7)),
        ],
        edges: const [FcoseEdge(id: 'ab', source: 'a', target: 'b')],
      );
      final result = FcoseLayout(
        options: const FcoseOptions(quality: LayoutQuality.draft, randomize: false),
      ).run(graph);
      expect(result.positionOf('b').x - result.positionOf('a').x, 100);
      expect(result.positionOf('b').y - result.positionOf('a').y, 0);
    });

    test('maps Mermaid architecture layout knobs', () {
      final options = FcoseOptions.mermaid(
        nodeSeparation: 90,
        idealEdgeLengthMultiplier: 1.5,
        baseIdealEdgeLength: 40,
        edgeElasticity: 0.7,
        numIter: 321,
      );
      expect(options.randomize, isFalse);
      expect(options.nodeSeparation, 90);
      expect(options.idealEdgeLength, 60);
      expect(options.edgeElasticity, 0.7);
      expect(options.maxIterations, 321);
    });
  });
}
