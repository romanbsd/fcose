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

  group('layout-base geometry', () {
    test('clips the center line against both node rectangles', () {
      final source = Rect.fromCenter(const Offset(0, 0), 80, 80);
      final target = Rect.fromCenter(const Offset(200, 0), 80, 80);

      expect(source.boundaryDisplacementTo(target).x, closeTo(120, 1e-12));
      expect(source.boundaryDisplacementTo(target).y, 0);
      expect(source.boundaryDistanceTo(target), closeTo(120, 1e-12));
    });

    test('returns zero boundary distance for overlapping rectangles', () {
      final source = Rect.fromCenter(const Offset(0, 0), 80, 80);
      final target = Rect.fromCenter(const Offset(20, 10), 80, 80);
      expect(source.boundaryDisplacementTo(target), Offset.zero);
    });

    test('calculates layout-base overlap separation with an edge-length buffer', () {
      final source = Rect.fromCenter(const Offset(0, 0), 80, 80);
      final target = Rect.fromCenter(const Offset(20, 0), 80, 80);
      expect(source.separationAmountTo(target, buffer: 25), const Offset(55, -25));
    });
  });

  group('compound graph manager', () {
    final graph = FcoseGraph(
      nodes: const [
        FcoseNode(id: 'root'),
        FcoseNode(id: 'left', parentId: 'root'),
        FcoseNode(id: 'right', parentId: 'root'),
        FcoseNode(id: 'a', parentId: 'left', width: 20, height: 20),
        FcoseNode(id: 'b', parentId: 'right', width: 20, height: 20),
      ],
    );
    final manager = CompoundGraphManager(graph);

    test('tracks owners, depths, and lowest common owner', () {
      expect(manager.ownerOf('a'), 'left');
      expect(manager.inclusionDepthOf('a'), 3);
      expect(manager.lowestCommonOwner('a', 'b'), 'root');
      expect(manager.childInOwner('a', 'root'), 'left');
      expect(manager.childInOwner('b', 'root'), 'right');
      expect(manager.siblings('left').map((node) => node.id), ['left', 'right']);
      expect(manager.isOwnerConnected('root'), isFalse);
      expect(manager.estimatedSizeOf('a'), 20);
      expect(manager.estimatedSizeOf('left'), 20);

      final connected = CompoundGraphManager(
        FcoseGraph(
          nodes: graph.nodes,
          edges: const [FcoseEdge(id: 'ab', source: 'a', target: 'b')],
        ),
      );
      expect(connected.isOwnerConnected('root'), isTrue);
    });

    test('updates compound bounds and propagates displacement', () {
      final positions = <String, Offset>{'a': const Offset(0, 0), 'b': const Offset(100, 0)};
      final rectangles = manager.rectangles(positions, padding: 10);
      expect(rectangles['left']!.containsRect(rectangles['a']!), isTrue);
      expect(rectangles['root']!.containsRect(rectangles['right']!), isTrue);

      manager.translate('left', const Offset(25, 5), positions);
      expect(positions['a'], const Offset(25, 5));
      expect(positions['b'], const Offset(100, 0));
    });
  });

  group('sampled spectral initialization', () {
    final nodes = ['a', 'b', 'c', 'd', 'e', 'f'];
    final adjacency = <String, Set<String>>{
      'a': {'b'},
      'b': {'a', 'c'},
      'c': {'b', 'd'},
      'd': {'c', 'e'},
      'e': {'d', 'f'},
      'f': {'e'},
    };

    test('honors greedy sample size and produces finite coordinates', () {
      final result = SpectralInitializer(
        sampleSize: 3,
        samplingType: SamplingType.greedy,
        nodeSeparation: 75,
        seed: 4,
      ).run(nodes, adjacency);
      expect(result.samples, hasLength(3));
      expect(result.samples.toSet(), hasLength(3));
      expect(result.positions.values.every((point) => point.isFinite), isTrue);
    });

    test('random sampling is seeded and consumes sampleSize', () {
      SpectralResult run() => SpectralInitializer(
        sampleSize: 4,
        samplingType: SamplingType.random,
        nodeSeparation: 75,
        seed: 11,
      ).run(nodes, adjacency);
      expect(run().samples, run().samples);
      expect(run().samples, hasLength(4));
      expect(run().positions, run().positions);
    });
  });

  group('constraint handler', () {
    test('solves combined row and column dummy groups from a fixed anchor', () {
      final positions = <String, Offset>{
        'a': const Offset(0, 0),
        'b': const Offset(5, 20),
        'c': const Offset(40, 3),
        'd': const Offset(50, 25),
      };

      const ConstraintHandler(
        fixedNodes: [FixedNodeConstraint('a', Offset(10, 20))],
        alignment: AlignmentConstraint(
          vertical: [
            ['a', 'b'],
            ['c', 'd'],
          ],
          horizontal: [
            ['a', 'c'],
            ['b', 'd'],
          ],
        ),
        relativePlacements: [
          RelativePlacementConstraint.horizontal('a', 'c', gap: 100),
          RelativePlacementConstraint.vertical('a', 'b', gap: 60),
        ],
        defaultGap: 50,
      ).enforce(positions);

      expect(positions['a'], const Offset(10, 20));
      expect(positions['b'], const Offset(10, 80));
      expect(positions['c'], const Offset(110, 20));
      expect(positions['d'], const Offset(110, 80));
    });

    test('rejects overlapping alignment sets on one axis', () {
      expect(
        () => const ConstraintHandler(
          fixedNodes: [],
          alignment: AlignmentConstraint(
            vertical: [
              ['a', 'b'],
              ['b', 'c'],
            ],
          ),
          relativePlacements: [],
          defaultGap: 50,
        ).enforce(<String, Offset>{'a': const Offset(0, 0), 'b': const Offset(10, 0), 'c': const Offset(20, 0)}),
        throwsArgumentError,
      );
    });

    test('rejects a positive relative gap inside an alignment group', () {
      expect(
        () => const ConstraintHandler(
          fixedNodes: [],
          alignment: AlignmentConstraint(
            vertical: [
              ['a', 'b'],
            ],
          ),
          relativePlacements: [RelativePlacementConstraint.horizontal('a', 'b', gap: 10)],
          defaultGap: 50,
        ).enforce(<String, Offset>{'a': const Offset(0, 0), 'b': const Offset(10, 0)}),
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

    test('moves sibling compounds as live force participants', () {
      final graph = FcoseGraph(
        nodes: const [
          FcoseNode(id: 'left'),
          FcoseNode(id: 'right'),
          FcoseNode(id: 'a', parentId: 'left', width: 80, height: 80, position: Offset(0, 0)),
          FcoseNode(id: 'b', parentId: 'right', width: 80, height: 80, position: Offset(20, 0)),
        ],
        edges: const [FcoseEdge(id: 'groups', source: 'left', target: 'right', idealLength: 80)],
      );
      final result = FcoseLayout(
        options: const FcoseOptions(quality: LayoutQuality.proof, randomize: false, maxIterations: 500),
      ).run(graph);

      expect(result.rectOf('left').overlaps(result.rectOf('right')), isFalse);
      expect(result.rectOf('left').boundaryDistanceTo(result.rectOf('right')), greaterThan(60));
      expect(result.rectOf('left').containsRect(result.rectOf('a')), isTrue);
      expect(result.rectOf('right').containsRect(result.rectOf('b')), isTrue);
    });

    test('adds layout-base smart size to cross-compound edge lengths', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              idealEdgeLength: 40,
              maxIterations: 1000,
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'left'),
                FcoseNode(id: 'right'),
                FcoseNode(id: 'a', parentId: 'left', width: 80, height: 80, position: Offset(0, 0)),
                FcoseNode(id: 'b', parentId: 'right', width: 80, height: 80, position: Offset(100, 0)),
              ],
              edges: const [FcoseEdge(id: 'ab', source: 'a', target: 'b', idealLength: 40)],
            ),
          );

      expect(result.rectOf('a').boundaryDistanceTo(result.rectOf('b')), greaterThan(100));
      expect(result.rectOf('left').overlaps(result.rectOf('right')), isFalse);
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
      expect(options.initialEnergyOnIncremental, 0.3);
      expect(options.powerIterationTolerance, 1e-7);
    });

    test('Mermaid adapter assigns topology-specific edge parameters', () {
      final graph = FcoseGraph(
        nodes: const [
          FcoseNode(id: 'root'),
          FcoseNode(id: 'a', parentId: 'root'),
          FcoseNode(id: 'b', parentId: 'root'),
          FcoseNode(id: 'outside'),
        ],
        edges: const [
          FcoseEdge(id: 'same', source: 'a', target: 'b'),
          FcoseEdge(id: 'cross', source: 'b', target: 'outside'),
        ],
      );
      const adapter = MermaidFcoseAdapter(iconSize: 80, idealEdgeLengthMultiplier: 1.5, edgeElasticity: 0.45);
      final configured = adapter.configureGraph(graph);

      expect(adapter.options.quality, LayoutQuality.proof);
      expect(adapter.options.randomize, isFalse);
      expect(configured.edges[0].idealLength, 120);
      expect(configured.edges[0].elasticity, 0.45);
      expect(configured.edges[1].idealLength, 40);
      expect(configured.edges[1].elasticity, 0.001);
    });

    test('treats ideal edge length as boundary-to-boundary distance', () {
      final result = FcoseLayout(options: const FcoseOptions(seed: 7, idealEdgeLength: 120, maxIterations: 1000)).run(
        FcoseGraph(
          nodes: const [
            FcoseNode(id: 'a', width: 80, height: 80),
            FcoseNode(id: 'b', width: 80, height: 80),
          ],
          edges: const [FcoseEdge(id: 'ab', source: 'a', target: 'b')],
        ),
      );
      final centerDistance = result.positionOf('a').distanceTo(result.positionOf('b'));
      expect(centerDistance, greaterThan(190));
      expect(result.rectOf('a').boundaryDistanceTo(result.rectOf('b')), closeTo(120, 12));
    });

    test('tracks Mermaid 11.16 three-service chain spacing', () {
      FcoseResult layout(double multiplier) {
        final ideal = 80 * multiplier;
        return FcoseLayout(
          options: FcoseOptions(
            quality: LayoutQuality.proof,
            randomize: false,
            seed: 1,
            maxIterations: 2500,
            idealEdgeLength: ideal,
            edgeElasticity: 0.45,
            relativePlacements: [
              RelativePlacementConstraint.horizontal('a', 'b', gap: ideal),
              RelativePlacementConstraint.horizontal('b', 'c', gap: ideal),
            ],
          ),
        ).run(
          FcoseGraph(
            nodes: const [
              FcoseNode(id: 'a', width: 80, height: 80, position: Offset(0, 50)),
              FcoseNode(id: 'b', width: 80, height: 80, position: Offset(50, 50)),
              FcoseNode(id: 'c', width: 80, height: 80, position: Offset(100, 50)),
            ],
            edges: [
              FcoseEdge(id: 'ab', source: 'a', target: 'b', idealLength: ideal),
              FcoseEdge(id: 'bc', source: 'b', target: 'c', idealLength: ideal),
            ],
          ),
        );
      }

      final defaults = layout(1.5);
      final stretched = layout(3);
      expect(defaults.positionOf('b').x - defaults.positionOf('a').x, closeTo(200.68652784647548, 1e-4));
      expect(stretched.positionOf('b').x - stretched.positionOf('a').x, closeTo(320.17331510624684, 1e-4));
    });

    test('requires complete initial positions when randomize is false', () {
      expect(
        () => FcoseLayout(options: const FcoseOptions(quality: LayoutQuality.draft, randomize: false)).run(
          FcoseGraph(
            nodes: const [
              FcoseNode(id: 'a', position: Offset.zero),
              FcoseNode(id: 'b'),
            ],
          ),
        ),
        throwsStateError,
      );
    });

    test('rejects cyclic relative placement constraints', () {
      final graph = FcoseGraph(
        nodes: const [
          FcoseNode(id: 'a'),
          FcoseNode(id: 'b'),
        ],
      );
      expect(
        () => FcoseLayout(
          options: const FcoseOptions(
            relativePlacements: [
              RelativePlacementConstraint.horizontal('a', 'b'),
              RelativePlacementConstraint.horizontal('b', 'a'),
            ],
          ),
        ).run(graph),
        throwsArgumentError,
      );
    });

    test('rejects impossible constraints between fixed nodes', () {
      final graph = FcoseGraph(
        nodes: const [
          FcoseNode(id: 'a'),
          FcoseNode(id: 'b'),
        ],
      );
      expect(
        () => FcoseLayout(
          options: const FcoseOptions(
            fixedNodes: [FixedNodeConstraint('a', Offset.zero), FixedNodeConstraint('b', Offset(10, 0))],
            relativePlacements: [RelativePlacementConstraint.horizontal('a', 'b', gap: 50)],
          ),
        ).run(graph),
        throwsArgumentError,
      );
    });
  });
}
