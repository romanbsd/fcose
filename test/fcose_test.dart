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

    test('rejects negative node padding', () {
      expect(() => FcoseGraph(nodes: const [FcoseNode(id: 'a', padding: -1)]), throwsArgumentError);
    });

    test('keeps derived graph indexes deeply immutable', () {
      final graph = FcoseGraph(
        nodes: const [
          FcoseNode(id: 'parent'),
          FcoseNode(id: 'child', parentId: 'parent'),
        ],
      );

      expect(() => graph.nodeById['other'] = const FcoseNode(id: 'other'), throwsUnsupportedError);
      expect(() => graph.childrenByParent['parent'] = const [], throwsUnsupportedError);
      expect(() => graph.childrenByParent['parent']!.add(const FcoseNode(id: 'other')), throwsUnsupportedError);
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

    test('treats edge-touching rectangles as intersecting like layout-base', () {
      const source = Rect(0, 0, 40, 40);
      const target = Rect(40, 0, 40, 40);

      expect(source.overlaps(target), isTrue);
      expect(source.boundaryDistanceTo(target), 0);
      expect(source.separationAmountTo(target, buffer: 25), const Offset(25, -25));
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
      expect(manager.layoutOrder.map((node) => node.id), ['root', 'left', 'right', 'a', 'b']);

      final connected = CompoundGraphManager(
        FcoseGraph(
          nodes: graph.nodes,
          edges: const [FcoseEdge(id: 'ab', source: 'a', target: 'b')],
        ),
      );
      expect(connected.isOwnerConnected('root'), isTrue);
      expect(manager.estimatedSizeOfOwner('left'), 20);
      expect(manager.estimatedSizeOfOwner('root'), closeTo(20 * 2 / 1.4142135623730951, 1e-12));
    });

    test('preserves nested graph order when enumerating descendant leaves', () {
      final manager = CompoundGraphManager(
        FcoseGraph(
          nodes: const [
            FcoseNode(id: 'parent'),
            FcoseNode(id: 'branch', parentId: 'parent'),
            FcoseNode(id: 'first', parentId: 'branch'),
            FcoseNode(id: 'second', parentId: 'parent'),
            FcoseNode(id: 'third', parentId: 'branch'),
          ],
        ),
      );

      expect(manager.descendantLeaves('parent'), ['first', 'third', 'second']);
      expect(manager.descendantLeaves('parent'), ['first', 'third', 'second']);
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

    test('ports layout-base compound label bounds and ignores stale parent size', () {
      final manager = CompoundGraphManager(
        FcoseGraph(
          nodes: const [
            FcoseNode(
              id: 'parent',
              width: 500,
              height: 400,
              labelWidth: 30,
              labelHeight: 10,
              labelHorizontalPosition: FcoseLabelHorizontalPosition.left,
              labelVerticalPosition: FcoseLabelVerticalPosition.top,
            ),
            FcoseNode(id: 'child', parentId: 'parent', width: 20, height: 20),
          ],
        ),
      );

      final rectangles = manager.rectangles({'child': Offset.zero}, padding: 10);

      final parent = rectangles['parent']!;
      expect([parent.left, parent.top, parent.width, parent.height], [-50, -30, 70, 50]);
    });

    test('uses per-compound padding with a fallback at each nesting level', () {
      final manager = CompoundGraphManager(
        FcoseGraph(
          nodes: const [
            FcoseNode(id: 'outer', padding: 30),
            FcoseNode(id: 'inner', parentId: 'outer', padding: 5),
            FcoseNode(id: 'child', parentId: 'inner', width: 20, height: 20),
          ],
        ),
      );

      final rectangles = manager.rectangles({'child': Offset.zero}, padding: 10);

      final inner = rectangles['inner']!;
      final outer = rectangles['outer']!;
      expect([inner.left, inner.top, inner.width, inner.height], [-15, -15, 30, 30]);
      expect([outer.left, outer.top, outer.width, outer.height], [-45, -45, 90, 90]);
    });

    test('expands centered compound labels symmetrically only when necessary', () {
      Rect bounds(double labelWidth, double labelHeight) {
        final manager = CompoundGraphManager(
          FcoseGraph(
            nodes: [
              FcoseNode(
                id: 'parent',
                labelWidth: labelWidth,
                labelHeight: labelHeight,
                labelHorizontalPosition: FcoseLabelHorizontalPosition.center,
                labelVerticalPosition: FcoseLabelVerticalPosition.center,
              ),
              const FcoseNode(id: 'child', parentId: 'parent', width: 20, height: 20),
            ],
          ),
        );
        return manager.rectangles({'child': Offset.zero}, padding: 10)['parent']!;
      }

      final expanded = bounds(60, 80);
      final unchanged = bounds(30, 20);
      expect([expanded.left, expanded.top, expanded.width, expanded.height], [-30, -40, 60, 80]);
      expect([unchanged.left, unchanged.top, unchanged.width, unchanged.height], [-20, -20, 40, 40]);
    });

    test('selects the least-connected direct leaf as a spectral representative', () {
      final manager = CompoundGraphManager(
        FcoseGraph(
          nodes: const [
            FcoseNode(id: 'parent'),
            FcoseNode(id: 'busy', parentId: 'parent'),
            FcoseNode(id: 'quiet', parentId: 'parent'),
            FcoseNode(id: 'outside'),
          ],
          edges: const [
            FcoseEdge(id: 'first', source: 'busy', target: 'outside'),
            FcoseEdge(id: 'second', source: 'busy', target: 'outside'),
          ],
        ),
      );

      expect(manager.spectralRepresentative('parent'), 'quiet');
      expect(manager.spectralRepresentative('outside'), 'outside');
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
        random: Xorshift32(4),
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
        random: Xorshift32(11),
      ).run(nodes, adjacency);
      expect(run().samples, run().samples);
      expect(run().samples, hasLength(4));
      expect(run().samples, ['a', 'b', 'f', 'c']);
      expect(run().positions, run().positions);
      final positions = run().positions;
      expect(
        [for (final node in nodes) positions[node]!.x.abs()],
        [
          closeTo(187.0141863310327, 1e-6),
          closeTo(112.54133928374488, 1e-6),
          closeTo(37.81887162261311, 1e-6),
          closeTo(37.15321665236261, 1e-6),
          closeTo(112.37492554118225, 1e-6),
          closeTo(187.84625504384584, 1e-6),
        ],
      );
      expect(
        [for (final node in nodes) positions[node]!.y.abs()],
        [
          closeTo(15.499863346637966, 1e-6),
          closeTo(3.0670306943618226, 1e-6),
          closeTo(12.35871320860305, 1e-6),
          closeTo(12.375184196085973, 1e-6),
          closeTo(3.1164436568103366, 1e-6),
          closeTo(15.417508409223476, 1e-6),
        ],
      );
    });

    test('uses the upstream one/two-node CoSE shortcut', () {
      final initializer = SpectralInitializer(
        sampleSize: 25,
        samplingType: SamplingType.greedy,
        nodeSeparation: 75,
        random: Xorshift32(1),
      );
      final result = initializer.run(
        ['a', 'b'],
        const {
          'a': {'b'},
          'b': {'a'},
        },
        widths: const {'a': 80, 'b': 40},
        initialPositions: const {'a': Offset(25, 35)},
        idealEdgeLength: 120,
      );

      expect(result.samples, isEmpty);
      expect(result.positions['a'], const Offset(25, 35));
      expect(result.positions['b'], const Offset(205, 35));
    });
  });

  group('constraint handler', () {
    test('snapshots mutable constraint collections deeply', () {
      final fixed = <FixedNodeConstraint>[const FixedNodeConstraint('a', Offset.zero)];
      final vertical = <List<String>>[
        ['a', 'b'],
      ];
      final relative = <RelativePlacementConstraint>[const RelativePlacementConstraint.horizontal('a', 'b')];
      final handler = ConstraintHandler(
        fixedNodes: fixed,
        alignment: AlignmentConstraint(vertical: vertical),
        relativePlacements: relative,
        defaultGap: 50,
      );

      fixed.clear();
      vertical.single.add('c');
      relative.clear();

      expect(handler.fixedNodes, hasLength(1));
      expect(handler.alignment.vertical, [
        ['a', 'b'],
      ]);
      expect(handler.relativePlacements, hasLength(1));
      expect(() => handler.alignment.vertical.single.add('c'), throwsUnsupportedError);
    });

    test('rotates the randomized draft toward an alignment constraint', () {
      final positions = <String, Offset>{
        'a': const Offset(0, 0),
        'b': const Offset(100, 100),
        'free': const Offset(100, 0),
      };

      ConstraintHandler(
        fixedNodes: [],
        alignment: AlignmentConstraint(
          vertical: [
            ['a', 'b'],
          ],
        ),
        relativePlacements: [],
        defaultGap: 50,
      ).transformInitial(positions);

      expect(positions['a']!.x, closeTo(positions['b']!.x, 1e-9));
      expect(positions['a']!.distanceTo(positions['b']!), closeTo(100 * 1.4142135623730951, 1e-9));
      expect(positions['free']!.distanceTo(Offset.zero), closeTo(100, 1e-9));
    });

    test('rotates the dominant relative-placement DAG toward its axis', () {
      final positions = <String, Offset>{
        'a': const Offset(0, 0),
        'b': const Offset(0, 100),
        'c': const Offset(0, 200),
        'free': const Offset(50, 0),
      };

      ConstraintHandler(
        fixedNodes: [],
        alignment: AlignmentConstraint(),
        relativePlacements: [
          RelativePlacementConstraint.horizontal('a', 'b', gap: 100),
          RelativePlacementConstraint.horizontal('b', 'c', gap: 100),
        ],
        defaultGap: 50,
      ).transformInitial(positions);

      final firstStep = positions['b']! - positions['a']!;
      final secondStep = positions['c']! - positions['b']!;
      expect(firstStep.x, closeTo(100 / 1.4142135623730951, 1e-9));
      expect(firstStep.y, closeTo(firstStep.x, 1e-9));
      expect(secondStep.x, closeTo(firstStep.x, 1e-9));
      expect(secondStep.y, closeTo(firstStep.y, 1e-9));
      expect(positions['a']!.x, lessThan(positions['b']!.x));
      expect(positions['b']!.x, lessThan(positions['c']!.x));
      expect(positions['a']!.distanceTo(positions['c']!), closeTo(200, 1e-9));
      expect(positions['free']!.distanceTo(Offset.zero), closeTo(50, 1e-9));
    });

    test('solves combined row and column dummy groups from a fixed anchor', () {
      final positions = <String, Offset>{
        'a': const Offset(0, 0),
        'b': const Offset(5, 20),
        'c': const Offset(40, 3),
        'd': const Offset(50, 25),
      };

      ConstraintHandler(
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

    test('shifts a predecessor chain behind a fixed target', () {
      final positions = <String, Offset>{'a': const Offset(0, 0), 'b': const Offset(50, 0), 'c': const Offset(100, 0)};

      ConstraintHandler(
        fixedNodes: [FixedNodeConstraint('c', Offset(100, 0))],
        alignment: AlignmentConstraint(),
        relativePlacements: [
          RelativePlacementConstraint.horizontal('a', 'b', gap: 80),
          RelativePlacementConstraint.horizontal('b', 'c', gap: 80),
        ],
        defaultGap: 50,
      ).enforce(positions);

      expect(positions['a'], const Offset(-60, 0));
      expect(positions['b'], const Offset(20, 0));
      expect(positions['c'], const Offset(100, 0));
    });

    test('collapses excess spacing after a fixed source', () {
      final positions = <String, Offset>{'a': const Offset(0, 0), 'b': const Offset(100, 0), 'c': const Offset(200, 0)};

      ConstraintHandler(
        fixedNodes: [FixedNodeConstraint('a', Offset.zero)],
        alignment: AlignmentConstraint(),
        relativePlacements: [
          RelativePlacementConstraint.horizontal('a', 'b', gap: 80),
          RelativePlacementConstraint.horizontal('b', 'c', gap: 80),
        ],
        defaultGap: 50,
      ).enforce(positions);

      expect(positions['a'], Offset.zero);
      expect(positions['b'], const Offset(80, 0));
      expect(positions['c'], const Offset(160, 0));
    });

    test('recenters a fixed-free sink predecessor set independently', () {
      final positions = <String, Offset>{
        'a': const Offset(0, 0),
        'fixed': const Offset(100, 0),
        'free': const Offset(300, 0),
      };

      ConstraintHandler(
        fixedNodes: [FixedNodeConstraint('fixed', const Offset(100, 0))],
        alignment: AlignmentConstraint(),
        relativePlacements: [
          RelativePlacementConstraint.horizontal('a', 'fixed', gap: 80),
          RelativePlacementConstraint.horizontal('a', 'free', gap: 80),
        ],
        defaultGap: 50,
      ).enforce(positions);

      expect(positions['a'], const Offset(110, 0));
      expect(positions['fixed'], const Offset(100, 0));
      expect(positions['free'], const Offset(190, 0));
    });

    test('enforces overlapping alignment sets sequentially like cose-base', () {
      final positions = <String, Offset>{'a': const Offset(0, 0), 'b': const Offset(10, 0), 'c': const Offset(20, 0)};

      ConstraintHandler(
        fixedNodes: [],
        alignment: AlignmentConstraint(
          vertical: [
            ['a', 'b'],
            ['b', 'c'],
          ],
        ),
        relativePlacements: [],
        defaultGap: 50,
      ).enforce(positions);

      expect(positions['a']!.x, 5);
      expect(positions['b']!.x, 12.5);
      expect(positions['c']!.x, 12.5);
    });

    test('deduplicates alignment members while calculating their coordinate', () {
      final positions = <String, Offset>{'a': const Offset(0, 0), 'b': const Offset(12, 0), 'c': const Offset(30, 0)};

      ConstraintHandler(
        fixedNodes: [],
        alignment: AlignmentConstraint(
          vertical: [
            ['a', 'b', 'b', 'c'],
          ],
        ),
        relativePlacements: [],
        defaultGap: 50,
      ).enforce(positions);

      expect(positions.values.map((position) => position.x), everyElement(14));
    });

    test('rejects a positive relative gap inside an alignment group', () {
      expect(
        () => ConstraintHandler(
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

    test('rejects relative cycles introduced by alignment groups', () {
      final handler = ConstraintHandler(
        fixedNodes: const [],
        alignment: const AlignmentConstraint(
          vertical: [
            ['a', 'b'],
            ['c', 'd'],
          ],
        ),
        relativePlacements: const [
          RelativePlacementConstraint.horizontal('a', 'c', gap: 10),
          RelativePlacementConstraint.horizontal('d', 'b', gap: 10),
        ],
        defaultGap: 50,
      );

      expect(
        () => handler.enforce({
          'a': const Offset(0, 0),
          'b': const Offset(0, 10),
          'c': const Offset(100, 0),
          'd': const Offset(100, 10),
        }),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'relative placement constraints must form a DAG',
          ),
        ),
      );
    });

    test('rewrites pending displacements before relative nodes move', () {
      final positions = <String, Offset>{'a': const Offset(0, 0), 'b': const Offset(100, 0)};
      final displacements = <String, Offset>{'a': const Offset(10, 0), 'b': const Offset(-10, 0)};

      ConstraintHandler(
        fixedNodes: [],
        alignment: AlignmentConstraint(),
        relativePlacements: [RelativePlacementConstraint.horizontal('a', 'b', gap: 120)],
        defaultGap: 50,
      ).constrainDisplacements(positions, displacements, iteration: 1);

      expect(displacements['a'], const Offset(-20, 0));
      expect(displacements['b'], Offset.zero);
    });

    test('matches cose-base cross-axis alignment dummy collisions', () {
      final positions = <String, Offset>{
        'a1': Offset.zero,
        'b1': const Offset(0, 10),
        'a2': const Offset(120, 130),
        'b2': const Offset(400, 130),
        'free': const Offset(200, 250),
      };
      final displacements = <String, Offset>{
        'a1': const Offset(0, 100),
        'b1': const Offset(0, 5),
        'a2': const Offset(0, 10),
        'b2': const Offset(0, 20),
        'free': const Offset(0, -5),
      };

      ConstraintHandler(
        fixedNodes: const [FixedNodeConstraint('a1', Offset.zero)],
        alignment: const AlignmentConstraint(
          vertical: [
            ['a1', 'b1'],
          ],
          horizontal: [
            ['a2', 'b2'],
          ],
        ),
        relativePlacements: const [
          RelativePlacementConstraint.vertical('b1', 'b2', gap: 120),
          RelativePlacementConstraint.vertical('a2', 'free', gap: 120),
        ],
        defaultGap: 50,
      ).constrainDisplacements(positions, displacements, iteration: 1);

      expect(displacements['a1'], Offset.zero);
      expect(displacements['a2']!.y, 15);
      expect(displacements['b2']!.y, 15);
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

    test('uses only the first spring between a node pair like cytoscape-fcose', () {
      FcoseResult run(List<FcoseEdge> edges) =>
          FcoseLayout(
            options: const FcoseOptions(quality: LayoutQuality.proof, randomize: false, maxIterations: 1000),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 80, height: 80, position: Offset.zero),
                FcoseNode(id: 'b', width: 80, height: 80, position: Offset(300, 0)),
              ],
              edges: edges,
            ),
          );

      final firstEdge = const FcoseEdge(id: 'first', source: 'a', target: 'b', idealLength: 120, elasticity: 0.45);
      final single = run([firstEdge]);
      final parallel = run([
        firstEdge,
        const FcoseEdge(id: 'ignored', source: 'b', target: 'a', idealLength: 400, elasticity: 2),
        const FcoseEdge(id: 'self-loop', source: 'a', target: 'a', idealLength: 1000, elasticity: 10),
      ]);

      expect(parallel.positions, single.positions);
      expect(parallel.iterations, single.iterations);
    });

    test('honors upstream five-iterations-per-node floor', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 2,
              idealEdgeLength: 120,
              edgeElasticity: 0.45,
              nodeRepulsion: 4500,
              gravity: 0.25,
              gravityRange: 3.8,
              initialEnergyOnIncremental: 0.3,
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 80, height: 80, position: Offset(50, 50)),
                FcoseNode(id: 'b', width: 80, height: 80, position: Offset(350, 50)),
                FcoseNode(id: 'c', width: 80, height: 80, position: Offset(200, 300)),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b'),
                FcoseEdge(id: 'bc', source: 'b', target: 'c'),
                FcoseEdge(id: 'ca', source: 'c', target: 'a'),
              ],
            ),
          );

      expect(result.iterations, 15);
      // Repeated JS and Dart floating-point evaluation differs slightly after
      // fourteen nonlinear spring ticks; the completed geometry stays sub-pixel.
      expect(result.positionOf('a').x, closeTo(99.42754483305279, 0.1));
      expect(result.positionOf('a').y, closeTo(81.93735033222076, 0.1));
      expect(result.positionOf('b').x, closeTo(300.5724551669472, 0.1));
      expect(result.positionOf('b').y, closeTo(81.93735033222075, 0.1));
      expect(result.positionOf('c').x, closeTo(200.00000000000003, 0.1));
      expect(result.positionOf('c').y, closeTo(268.0626496677792, 0.1));
    });

    test('matches the upstream overlap-separation force branch', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 2,
              idealEdgeLength: 120,
              edgeElasticity: 0.45,
              nodeRepulsion: 4500,
              gravity: 0.25,
              gravityRange: 3.8,
              initialEnergyOnIncremental: 0.3,
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 80, height: 80, position: Offset(50, 50)),
                FcoseNode(id: 'b', width: 80, height: 80, position: Offset(70, 60)),
                FcoseNode(id: 'c', width: 80, height: 80, position: Offset(200, 300)),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b'),
                FcoseEdge(id: 'bc', source: 'b', target: 'c'),
                FcoseEdge(id: 'ca', source: 'c', target: 'a'),
              ],
            ),
          );

      expect(result.iterations, 15);
      expect(result.positionOf('a').x, closeTo(32.97059903596177, 1e-9));
      expect(result.positionOf('a').y, closeTo(75.28859494877061, 1e-9));
      expect(result.positionOf('b').x, closeTo(217.02940096403825, 1e-9));
      expect(result.positionOf('b').y, closeTo(96.46461219225121, 1e-9));
      expect(result.positionOf('c').x, closeTo(173.1819469038681, 1e-9));
      expect(result.positionOf('c').y, closeTo(274.71140505122935, 1e-9));
    });

    test('matches upstream repulsion range when ideal edges are shorter than ten pixels', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 15,
              idealEdgeLength: 1,
              edgeElasticity: 0.45,
              nodeRepulsion: 50,
              gravity: 0,
              initialEnergyOnIncremental: 0.03,
              minTemperature: 0.01,
              packComponents: false,
              tile: false,
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 2, height: 2, position: Offset(0, 0)),
                FcoseNode(id: 'b', width: 2, height: 2, position: Offset(10, 0)),
                FcoseNode(id: 'c', width: 2, height: 2, position: Offset(6, 10)),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b'),
                FcoseEdge(id: 'bc', source: 'b', target: 'c'),
                FcoseEdge(id: 'ca', source: 'c', target: 'a'),
              ],
            ),
          );

      expect(result.iterations, 15);
      expect(result.positionOf('a').x, closeTo(1.0470410494352982, 1e-9));
      expect(result.positionOf('a').y, closeTo(1.175617510509638, 1e-9));
      expect(result.positionOf('b').x, closeTo(8.952958950564701, 1e-9));
      expect(result.positionOf('b').y, closeTo(1.15280696169748, 1e-9));
      expect(result.positionOf('c').x, closeTo(5.706311675255573, 1e-9));
      expect(result.positionOf('c').y, closeTo(8.847193038302521, 1e-9));
    });

    test('matches upstream per-node repulsion averaging', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 2,
              idealEdgeLength: 120,
              edgeElasticity: 0,
              gravity: 0,
              initialEnergyOnIncremental: 0.3,
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 80, height: 80, position: Offset(50, 50), nodeRepulsion: 1000),
                FcoseNode(id: 'b', width: 80, height: 80, position: Offset(350, 50), nodeRepulsion: 9000),
                FcoseNode(id: 'c', width: 80, height: 80, position: Offset(200, 300), nodeRepulsion: 4500),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b'),
                FcoseEdge(id: 'bc', source: 'b', target: 'c'),
                FcoseEdge(id: 'ca', source: 'c', target: 'a'),
              ],
            ),
          );

      expect(result.iterations, 15);
      expect(result.positionOf('a').x, closeTo(49.31121062868377, 1e-9));
      expect(result.positionOf('a').y, closeTo(49.65651334898722, 1e-9));
      expect(result.positionOf('b').x, closeTo(350.68878937131626, 1e-9));
      expect(result.positionOf('b').y, closeTo(49.250526717782904, 1e-9));
      expect(result.positionOf('c').x, closeTo(199.673221096314, 1e-9));
      expect(result.positionOf('c').y, closeTo(300.7494732822171, 1e-9));
    });

    test('resolves upstream per-element force callbacks once per layout run', () {
      final nodeCalls = <String>[];
      final idealLengthCalls = <String>[];
      final elasticityCalls = <String>[];
      final result =
          FcoseLayout(
            options: FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 2,
              idealEdgeLength: 120,
              edgeElasticity: 0.45,
              gravity: 0,
              initialEnergyOnIncremental: 0.3,
              nodeRepulsionFor: (node) {
                nodeCalls.add(node.id);
                return switch (node.id) {
                  'a' => 1000,
                  'b' => 9000,
                  _ => 4500,
                };
              },
              idealEdgeLengthFor: (edge) {
                idealLengthCalls.add(edge.id);
                return 120;
              },
              edgeElasticityFor: (edge) {
                elasticityCalls.add(edge.id);
                return 0;
              },
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 80, height: 80, position: Offset(50, 50)),
                FcoseNode(id: 'b', width: 80, height: 80, position: Offset(350, 50)),
                FcoseNode(id: 'c', width: 80, height: 80, position: Offset(200, 300)),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b'),
                FcoseEdge(id: 'bc', source: 'b', target: 'c'),
                FcoseEdge(id: 'ca', source: 'c', target: 'a'),
              ],
            ),
          );

      expect(nodeCalls, ['a', 'b', 'c']);
      expect(idealLengthCalls, ['ab', 'bc', 'ca']);
      expect(elasticityCalls, ['ab', 'bc', 'ca']);
      expect(result.positionOf('a').x, closeTo(49.31121062868377, 1e-9));
      expect(result.positionOf('a').y, closeTo(49.65651334898722, 1e-9));
      expect(result.positionOf('b').x, closeTo(350.68878937131626, 1e-9));
      expect(result.positionOf('b').y, closeTo(49.250526717782904, 1e-9));
      expect(result.positionOf('c').x, closeTo(199.673221096314, 1e-9));
      expect(result.positionOf('c').y, closeTo(300.7494732822171, 1e-9));
    });

    test('matches upstream tree reduction, regrowth, and post-growth cooling', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 20,
              tile: false,
              idealEdgeLength: 120,
              edgeElasticity: 0.45,
              nodeRepulsion: 4500,
              gravity: 0.25,
              gravityRange: 3.8,
              initialEnergyOnIncremental: 0.3,
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 80, height: 80, position: Offset(0, 0)),
                FcoseNode(id: 'b', width: 80, height: 80, position: Offset(200, 0)),
                FcoseNode(id: 'c', width: 80, height: 80, position: Offset(100, 180)),
                FcoseNode(id: 'd', width: 80, height: 80, position: Offset(300, 0)),
                FcoseNode(id: 'e', width: 80, height: 80, position: Offset(400, 0)),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b'),
                FcoseEdge(id: 'bc', source: 'b', target: 'c'),
                FcoseEdge(id: 'ca', source: 'c', target: 'a'),
                FcoseEdge(id: 'bd', source: 'b', target: 'd'),
                FcoseEdge(id: 'de', source: 'd', target: 'e'),
              ],
            ),
          );

      expect(result.iterations, 40);
      // Repeated nonlinear ticks differ slightly between JavaScript and Dart,
      // and the closing relocation adds the drift of the two extreme nodes to
      // every center, so half a logical pixel is the tightest honest bound.
      expect(result.positionOf('a').x, closeTo(-54.990515153603525, 0.5));
      expect(result.positionOf('a').y, closeTo(1.6113426774648687, 0.5));
      expect(result.positionOf('b').x, closeTo(126.06699215220351, 0.5));
      expect(result.positionOf('b').y, closeTo(-6.2007164526216485, 0.5));
      expect(result.positionOf('c').x, closeTo(63.855454184212874, 0.5));
      expect(result.positionOf('c').y, closeTo(186.20071645262163, 0.5));
      expect(result.positionOf('d').x, closeTo(290.5966434162613, 0.5));
      expect(result.positionOf('d').y, closeTo(-0.9022147688306887, 0.5));
      expect(result.positionOf('e').x, closeTo(454.99051515360355, 0.5));
      expect(result.positionOf('e').y, closeTo(-3.5524319658540904, 0.5));
    });

    test('runs upstream post-growth cooling until the regrown tree converges', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 20,
              tile: false,
              idealEdgeLength: 120,
              edgeElasticity: 0.45,
              nodeRepulsion: 4500,
              gravity: 0.25,
              gravityRange: 3.8,
              initialEnergyOnIncremental: 0.3,
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 80, height: 80, position: Offset(0, 0)),
                FcoseNode(id: 'b', width: 80, height: 80, position: Offset(200, 0)),
                FcoseNode(id: 'c', width: 80, height: 80, position: Offset(100, 180)),
                FcoseNode(id: 'd', width: 80, height: 80, position: Offset(1000, 0)),
                FcoseNode(id: 'e', width: 80, height: 80, position: Offset(2000, 0)),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b'),
                FcoseEdge(id: 'bc', source: 'b', target: 'c'),
                FcoseEdge(id: 'ca', source: 'c', target: 'a'),
                FcoseEdge(id: 'bd', source: 'b', target: 'd'),
                FcoseEdge(id: 'de', source: 'd', target: 'e'),
              ],
            ),
          );

      expect(result.iterations, 41);
      expect(result.positionOf('d').x, closeTo(1103.444519478348, 0.5));
      expect(result.positionOf('e').x, closeTo(1782.2081558139598, 0.5));
    });

    test('default quality uses cytoscape-fcose fast cooling', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(randomize: false, maxIterations: 202, idealEdgeLength: 1, edgeElasticity: 0.01),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 80, height: 80, position: Offset(50, 50)),
                FcoseNode(id: 'b', width: 80, height: 80, position: Offset(1050, 50)),
                FcoseNode(id: 'c', width: 80, height: 80, position: Offset(200, 900)),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b'),
                FcoseEdge(id: 'bc', source: 'b', target: 'c'),
                FcoseEdge(id: 'ca', source: 'c', target: 'a'),
              ],
            ),
          );

      expect(result.iterations, 202);
      expect(result.positionOf('a').x, closeTo(429.63414961256257, 1e-9));
      expect(result.positionOf('a').y, closeTo(369.15194142985865, 1e-9));
      expect(result.positionOf('b').x, closeTo(670.3658503874374, 1e-9));
      expect(result.positionOf('b').y, closeTo(369.1506815976752, 1e-9));
      expect(result.positionOf('c').x, closeTo(462.90960690594864, 1e-9));
      expect(result.positionOf('c').y, closeTo(580.8493184023248, 1e-9));
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

    test('packs disconnected top-level compounds without separating their descendants', () {
      final result =
          FcoseLayout(options: const FcoseOptions(quality: LayoutQuality.draft, randomize: false, tile: false)).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'group'),
                FcoseNode(id: 'a', parentId: 'group', position: Offset(0, 0)),
                FcoseNode(id: 'b', parentId: 'group', position: Offset(20, 0)),
                FcoseNode(id: 'outside', position: Offset(200, 0)),
              ],
            ),
          );

      expect(result.positionOf('a').distanceTo(result.positionOf('b')), 20);
      expect(result.rectOf('group').containsRect(result.rectOf('a')), isTrue);
      expect(result.rectOf('group').containsRect(result.rectOf('b')), isTrue);
      expect(result.rectOf('group').overlaps(result.rectOf('outside')), isFalse);
    });

    test('matches upstream tiling for flat zero-degree nodes', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 2,
              tile: true,
              tilingPaddingHorizontal: 10,
              tilingPaddingVertical: 10,
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 80, height: 80, position: Offset(50, 50)),
                FcoseNode(id: 'b', width: 80, height: 80, position: Offset(150, 50)),
                FcoseNode(id: 'c', width: 80, height: 80, position: Offset(50, 150)),
                FcoseNode(id: 'd', width: 80, height: 80, position: Offset(150, 150)),
              ],
            ),
          );

      expect(result.iterations, 5);
      expect(result.positionOf('a'), const Offset(55, 55));
      expect(result.positionOf('b'), const Offset(145, 55));
      expect(result.positionOf('c'), const Offset(55, 145));
      expect(result.positionOf('d'), const Offset(145, 145));
    });

    test('resolves lazy tiling padding once per run and applies it to flat tiling', () {
      var horizontalCalls = 0;
      var verticalCalls = 0;
      final callbackOrder = <String>[];
      final graph = FcoseGraph(
        nodes: const [
          FcoseNode(id: 'a', width: 80, height: 80, position: Offset(50, 50)),
          FcoseNode(id: 'b', width: 80, height: 80, position: Offset(150, 50)),
          FcoseNode(id: 'c', width: 80, height: 80, position: Offset(50, 150)),
          FcoseNode(id: 'd', width: 80, height: 80, position: Offset(150, 150)),
        ],
      );
      final lazyLayout = FcoseLayout(
        options: FcoseOptions(
          quality: LayoutQuality.proof,
          randomize: false,
          maxIterations: 2,
          tile: true,
          tilingPaddingHorizontal: 1,
          tilingPaddingVertical: 2,
          tilingPaddingHorizontalFor: () {
            horizontalCalls++;
            callbackOrder.add('horizontal');
            return 26;
          },
          tilingPaddingVerticalFor: () {
            verticalCalls++;
            callbackOrder.add('vertical');
            return 14;
          },
        ),
      );
      final eagerLayout = FcoseLayout(
        options: const FcoseOptions(
          quality: LayoutQuality.proof,
          randomize: false,
          maxIterations: 2,
          tile: true,
          tilingPaddingHorizontal: 26,
          tilingPaddingVertical: 14,
        ),
      );

      final first = lazyLayout.run(graph);
      final expected = eagerLayout.run(graph);
      final second = lazyLayout.run(graph);

      expect(first.positions, expected.positions);
      expect(second.positions, expected.positions);
      expect(horizontalCalls, 2);
      expect(verticalCalls, 2);
      expect(callbackOrder, ['vertical', 'horizontal', 'vertical', 'horizontal']);
    });

    test('applies lazy tiling padding through nested compound restoration', () {
      var horizontalCalls = 0;
      var verticalCalls = 0;
      final graph = FcoseGraph(
        nodes: const [
          FcoseNode(id: 'outer'),
          FcoseNode(id: 'inner', parentId: 'outer'),
          FcoseNode(id: 'a', parentId: 'inner', width: 60, height: 30, position: Offset(20, 20)),
          FcoseNode(id: 'b', parentId: 'inner', width: 30, height: 60, position: Offset(160, 30)),
          FcoseNode(id: 'c', parentId: 'outer', width: 40, height: 40, position: Offset(80, 160)),
          FcoseNode(id: 'x', position: Offset(300, 50)),
          FcoseNode(id: 'y', position: Offset(420, 50)),
        ],
        edges: const [FcoseEdge(id: 'xy', source: 'x', target: 'y')],
      );

      final lazy = FcoseLayout(
        options: FcoseOptions(
          quality: LayoutQuality.proof,
          randomize: false,
          maxIterations: 10,
          tile: true,
          tilingPaddingHorizontalFor: () {
            horizontalCalls++;
            return 24;
          },
          tilingPaddingVerticalFor: () {
            verticalCalls++;
            return 18;
          },
        ),
      ).run(graph);
      final eager = FcoseLayout(
        options: const FcoseOptions(
          quality: LayoutQuality.proof,
          randomize: false,
          maxIterations: 10,
          tile: true,
          tilingPaddingHorizontal: 24,
          tilingPaddingVertical: 18,
        ),
      ).run(graph);

      expect(lazy.positions, eager.positions);
      expect(lazy.rectangles.keys.toSet(), eager.rectangles.keys.toSet());
      for (final id in eager.rectangles.keys) {
        final actual = lazy.rectOf(id);
        final expected = eager.rectOf(id);
        expect(
          [actual.left, actual.top, actual.width, actual.height],
          [expected.left, expected.top, expected.width, expected.height],
          reason: id,
        );
      }
      expect(horizontalCalls, 1);
      expect(verticalCalls, 1);
    });

    test('does not resolve lazy tiling padding for draft quality', () {
      var calls = 0;
      final result =
          FcoseLayout(
            options: FcoseOptions(
              quality: LayoutQuality.draft,
              randomize: false,
              packComponents: false,
              tilingPaddingHorizontalFor: () {
                calls++;
                return 24;
              },
              tilingPaddingVerticalFor: () {
                calls++;
                return 18;
              },
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', position: Offset.zero),
                FcoseNode(id: 'b', position: Offset(100, 0)),
              ],
              edges: const [FcoseEdge(id: 'ab', source: 'a', target: 'b')],
            ),
          );

      expect(result.positionOf('a'), Offset.zero);
      expect(result.positionOf('b'), const Offset(100, 0));
      expect(calls, 0);
    });

    test('validates resolved lazy tiling padding before layout', () {
      expect(
        () => FcoseLayout(
          options: FcoseOptions(quality: LayoutQuality.proof, tilingPaddingHorizontalFor: () => -1),
        ).run(FcoseGraph(nodes: const [FcoseNode(id: 'a')])),
        throwsArgumentError,
      );
    });

    test('matches upstream area-ordered tiling for mixed node sizes', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(quality: LayoutQuality.proof, randomize: false, maxIterations: 2, tile: true),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 80, height: 40, position: Offset(50, 50)),
                FcoseNode(id: 'b', width: 40, height: 80, position: Offset(150, 50)),
                FcoseNode(id: 'c', width: 60, height: 60, position: Offset(50, 150)),
                FcoseNode(id: 'd', width: 100, height: 30, position: Offset(150, 150)),
              ],
            ),
          );

      expect(result.positionOf('a'), const Offset(140, 40));
      expect(result.positionOf('b'), const Offset(50, 130));
      expect(result.positionOf('c'), const Offset(60, 50));
      expect(result.positionOf('d'), const Offset(130, 105));
    });

    test('matches upstream custom tiling order for mixed node sizes', () {
      final result =
          FcoseLayout(
            options: FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 2,
              tile: true,
              tilingCompareBy: (first, second) => second.compareTo(first),
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 80, height: 40, position: Offset(50, 50)),
                FcoseNode(id: 'b', width: 40, height: 80, position: Offset(150, 50)),
                FcoseNode(id: 'c', width: 60, height: 60, position: Offset(50, 150)),
                FcoseNode(id: 'd', width: 100, height: 30, position: Offset(150, 150)),
              ],
            ),
          );

      // Differential fixture from cytoscape-fcose 2.2.0. Translation differs
      // between adapters, so compare the invariant relative coordinates.
      expect(result.positionOf('a') - result.positionOf('b'), const Offset(70, -20));
      expect(result.positionOf('c') - result.positionOf('d'), const Offset(90, 15));
      expect(result.positionOf('a') - result.positionOf('d'), const Offset(40, 75));
    });

    test('matches upstream zero-degree dummy compound in a mixed root graph', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 10,
              tile: true,
              idealEdgeLength: 120,
              edgeElasticity: 0.45,
              nodeRepulsion: 4500,
              gravity: 0.25,
              gravityRange: 3.8,
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 80, height: 80, position: Offset(50, 50)),
                FcoseNode(id: 'b', width: 80, height: 80, position: Offset(250, 50)),
                FcoseNode(id: 'e', width: 80, height: 80, position: Offset(150, 150)),
                FcoseNode(id: 'c', width: 80, height: 80, position: Offset(50, 250)),
                FcoseNode(id: 'd', width: 80, height: 80, position: Offset(150, 250)),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b'),
                FcoseEdge(id: 'be', source: 'b', target: 'e'),
                FcoseEdge(id: 'ea', source: 'e', target: 'a'),
              ],
            ),
          );

      // Upstream's own positions, reproduced to 1e-13.
      expect(result.positionOf('a').x, closeTo(85.3021685902211, 1e-9));
      expect(result.positionOf('a').y, closeTo(-43.94838218086505, 1e-9));
      expect(result.positionOf('b').x, closeTo(287.9585905117531, 1e-9));
      expect(result.positionOf('b').y, closeTo(-43.972205200879216, 1e-9));
      expect(result.positionOf('e').x, closeTo(186.63316539046826, 1e-9));
      expect(result.positionOf('e').y, closeTo(141.411953100745, 1e-9));
      expect(result.positionOf('c').x, closeTo(12.04140948824692, 1e-9));
      expect(result.positionOf('c').y, closeTo(301.2801260500671, 1e-9));
      expect(result.positionOf('d').x, closeTo(102.04140948824693, 1e-9));
      expect(result.positionOf('d').y, closeTo(301.2801260500671, 1e-9));
    });

    test('tiles a disconnected compound subtree bottom-up before force refinement', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(quality: LayoutQuality.proof, randomize: false, maxIterations: 10, tile: true),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'group'),
                FcoseNode(id: 'a', parentId: 'group', width: 60, height: 30, position: Offset(20, 20)),
                FcoseNode(id: 'b', parentId: 'group', width: 30, height: 60, position: Offset(160, 30)),
                FcoseNode(id: 'c', parentId: 'group', width: 40, height: 40, position: Offset(80, 160)),
                FcoseNode(id: 'x', position: Offset(300, 50)),
                FcoseNode(id: 'y', position: Offset(420, 50)),
              ],
              edges: const [FcoseEdge(id: 'xy', source: 'x', target: 'y')],
            ),
          );

      expect(result.positionOf('b') - result.positionOf('a'), const Offset(-15, 55));
      expect(result.positionOf('c') - result.positionOf('a'), const Offset(30, 45));
      expect(result.rectOf('group').containsRect(result.rectOf('a')), isTrue);
      expect(result.rectOf('group').containsRect(result.rectOf('b')), isTrue);
      expect(result.rectOf('group').containsRect(result.rectOf('c')), isTrue);
    });

    test('groups randomized zero-degree siblings inside a live compound', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.defaultQuality,
              randomize: true,
              seed: 7,
              maxIterations: 10,
              tile: true,
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'parent'),
                FcoseNode(id: 'a', parentId: 'parent'),
                FcoseNode(id: 'b', parentId: 'parent'),
                FcoseNode(id: 'c', parentId: 'parent'),
                FcoseNode(id: 'd', parentId: 'parent'),
              ],
              edges: const [FcoseEdge(id: 'ab', source: 'a', target: 'b')],
            ),
          );

      expect(result.positionOf('d') - result.positionOf('c'), const Offset(40, 0));
      expect(result.rectOf('parent').containsRect(result.rectOf('c')), isTrue);
      expect(result.rectOf('parent').containsRect(result.rectOf('d')), isTrue);
      expect(result.positions.keys.toSet(), {'parent', 'a', 'b', 'c', 'd'});
      expect(result.rectangles.keys.toSet(), {'parent', 'a', 'b', 'c', 'd'});
    });

    test('repopulates nested tiled compounds from the outside in', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(quality: LayoutQuality.proof, randomize: false, maxIterations: 10, tile: true),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'outer'),
                FcoseNode(id: 'inner', parentId: 'outer'),
                FcoseNode(id: 'a', parentId: 'inner', width: 60, height: 30, position: Offset(20, 20)),
                FcoseNode(id: 'b', parentId: 'inner', width: 30, height: 60, position: Offset(160, 30)),
                FcoseNode(id: 'c', parentId: 'outer', width: 40, height: 40, position: Offset(80, 160)),
                FcoseNode(id: 'x', position: Offset(300, 50)),
                FcoseNode(id: 'y', position: Offset(420, 50)),
              ],
              edges: const [FcoseEdge(id: 'xy', source: 'x', target: 'y')],
            ),
          );

      expect((result.positionOf('b') - result.positionOf('a')).x, closeTo(-15, 1e-9));
      expect((result.positionOf('b') - result.positionOf('a')).y, closeTo(55, 1e-9));
      expect((result.positionOf('c') - result.positionOf('a')).x, closeTo(70, 1e-9));
      expect((result.positionOf('c') - result.positionOf('a')).y, closeTo(-5, 1e-9));
      expect(result.rectOf('inner').containsRect(result.rectOf('a')), isTrue);
      expect(result.rectOf('inner').containsRect(result.rectOf('b')), isTrue);
      expect(result.rectOf('outer').containsRect(result.rectOf('inner')), isTrue);
      expect(result.rectOf('outer').containsRect(result.rectOf('c')), isTrue);
    });

    test('uses each compound node padding while tiling nested children', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 10,
              tile: true,
              compoundPadding: 10,
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'outer', padding: 25),
                FcoseNode(id: 'inner', parentId: 'outer', padding: 40),
                FcoseNode(id: 'a', parentId: 'inner', width: 20, height: 20, position: Offset(20, 20)),
                FcoseNode(id: 'b', parentId: 'inner', width: 20, height: 20, position: Offset(80, 20)),
                FcoseNode(id: 'c', parentId: 'outer', width: 20, height: 20, position: Offset(50, 100)),
                FcoseNode(id: 'x', position: Offset(300, 50)),
                FcoseNode(id: 'y', position: Offset(420, 50)),
              ],
              edges: const [FcoseEdge(id: 'xy', source: 'x', target: 'y')],
            ),
          );

      expect(result.rectOf('inner').width, 130);
      expect(result.rectOf('inner').height, 100);
      expect(result.rectOf('outer').width, 180);
      expect(result.rectOf('outer').height, 180);
      expect(result.rectOf('inner').containsRect(result.rectOf('a')), isTrue);
      expect(result.rectOf('inner').containsRect(result.rectOf('b')), isTrue);
      expect(result.rectOf('outer').containsRect(result.rectOf('inner')), isTrue);
      expect(result.rectOf('outer').containsRect(result.rectOf('c')), isTrue);
    });

    test('uses owner padding for zero-degree groups inside a live compound', () {
      FcoseGraph graph({double? parentPadding}) => FcoseGraph(
        nodes: [
          FcoseNode(id: 'parent', padding: parentPadding),
          const FcoseNode(id: 'a', parentId: 'parent', position: Offset(0, 0)),
          const FcoseNode(id: 'b', parentId: 'parent', position: Offset(100, 0)),
          const FcoseNode(id: 'c', parentId: 'parent', position: Offset(0, 100)),
          const FcoseNode(id: 'd', parentId: 'parent', position: Offset(100, 100)),
        ],
        edges: const [FcoseEdge(id: 'ab', source: 'a', target: 'b')],
      );

      FcoseResult run(FcoseGraph graph, double fallbackPadding) => FcoseLayout(
        options: FcoseOptions(
          quality: LayoutQuality.proof,
          randomize: false,
          maxIterations: 10,
          tile: true,
          compoundPadding: fallbackPadding,
        ),
      ).run(graph);

      final perNode = run(graph(parentPadding: 35), 10);
      final fallback = run(graph(), 35);

      expect(perNode.positions, fallback.positions);
      final actualParent = perNode.rectOf('parent');
      final expectedParent = fallback.rectOf('parent');
      expect(
        [actualParent.left, actualParent.top, actualParent.width, actualParent.height],
        [expectedParent.left, expectedParent.top, expectedParent.width, expectedParent.height],
      );
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

    test('dampens compound movement around a fixed descendant', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 2,
              gravity: 0,
              nodeRepulsion: 0,
              fixedNodes: [FixedNodeConstraint('anchor', Offset(0, 0))],
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'group'),
                FcoseNode(id: 'anchor', parentId: 'group', width: 20, height: 20, position: Offset(0, 0)),
                FcoseNode(id: 'sibling', parentId: 'group', width: 20, height: 20, position: Offset(20, 0)),
                FcoseNode(id: 'external', width: 20, height: 20, position: Offset(500, 0)),
              ],
              edges: const [FcoseEdge(id: 'group-external', source: 'group', target: 'external', idealLength: 100)],
            ),
          );

      expect(result.positionOf('anchor'), const Offset(0, 0));
      expect(result.iterations, 20);
      expect(result.positionOf('sibling').x, inExclusiveRange(20, 50));
    });

    test('matches upstream constraints across deeply nested compounds', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              seed: 1,
              maxIterations: 2500,
              idealEdgeLength: 120,
              edgeElasticity: 0.45,
              compoundPadding: 40,
              fixedNodes: [FixedNodeConstraint('a1', Offset.zero)],
              alignment: AlignmentConstraint(
                vertical: [
                  ['a1', 'b1'],
                ],
                horizontal: [
                  ['a2', 'b2'],
                ],
              ),
              relativePlacements: [
                RelativePlacementConstraint.horizontal('a1', 'a2', gap: 120),
                RelativePlacementConstraint.vertical('b1', 'b2', gap: 120),
                RelativePlacementConstraint.vertical('a2', 'free', gap: 120),
              ],
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'left'),
                FcoseNode(id: 'left-inner', parentId: 'left'),
                FcoseNode(id: 'a1', parentId: 'left-inner', width: 80, height: 80, position: Offset.zero),
                FcoseNode(id: 'a2', parentId: 'left-inner', width: 80, height: 80, position: Offset(80, 80)),
                FcoseNode(id: 'right'),
                FcoseNode(id: 'right-inner', parentId: 'right'),
                FcoseNode(id: 'b1', parentId: 'right-inner', width: 80, height: 80, position: Offset(320, 0)),
                FcoseNode(id: 'b2', parentId: 'right-inner', width: 80, height: 80, position: Offset(400, 80)),
                FcoseNode(id: 'free', width: 80, height: 80, position: Offset(200, 260)),
              ],
              edges: const [
                FcoseEdge(id: 'a1-a2', source: 'a1', target: 'a2'),
                FcoseEdge(id: 'b1-b2', source: 'b1', target: 'b2'),
                FcoseEdge(id: 'a1-b1', source: 'a1', target: 'b1'),
                FcoseEdge(id: 'a2-free', source: 'a2', target: 'free'),
                FcoseEdge(id: 'b2-free', source: 'b2', target: 'free'),
              ],
            ),
          );

      expect(result.positionOf('a1'), Offset.zero);
      expect(result.positionOf('b1').x, closeTo(0, 1e-9));
      expect(result.positionOf('b1').y, closeTo(10, 1e-9));
      expect(result.positionOf('a2').x, closeTo(120, 1e-9));
      expect(result.positionOf('a2').y, closeTo(217.37804058764965, 0.5));
      expect(result.positionOf('b2').x, closeTo(409.1035712471904, 0.5));
      expect(result.positionOf('b2').y, closeTo(result.positionOf('a2').y, 1e-9));
      expect(result.positionOf('free').x, closeTo(265.11546183823043, 0.5));
      expect(result.positionOf('free').y, closeTo(531.5464187729549, 0.5));
      expect(result.rectOf('left').containsRect(result.rectOf('left-inner')), isTrue);
      expect(result.rectOf('right').containsRect(result.rectOf('right-inner')), isTrue);
    });

    test('enforces upstream implicit gaps across mixed-size nested compounds', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              step: LayoutStep.enforced,
              seed: 1,
              maxIterations: 2500,
              edgeElasticity: 0.45,
              compoundPadding: 40,
              fixedNodes: [FixedNodeConstraint('a1', Offset.zero)],
              alignment: AlignmentConstraint(
                vertical: [
                  ['a1', 'b1'],
                ],
                horizontal: [
                  ['a2', 'b2'],
                ],
              ),
              relativePlacements: [
                RelativePlacementConstraint.horizontal('a1', 'a2'),
                RelativePlacementConstraint.vertical('b1', 'b2'),
                RelativePlacementConstraint.vertical('a2', 'free'),
              ],
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'left'),
                FcoseNode(id: 'left-inner', parentId: 'left'),
                FcoseNode(id: 'a1', parentId: 'left-inner', width: 40, height: 60, position: Offset.zero),
                FcoseNode(id: 'a2', parentId: 'left-inner', width: 100, height: 20, position: Offset(80, 80)),
                FcoseNode(id: 'right'),
                FcoseNode(id: 'right-inner', parentId: 'right'),
                FcoseNode(id: 'b1', parentId: 'right-inner', width: 30, height: 80, position: Offset(320, 0)),
                FcoseNode(id: 'b2', parentId: 'right-inner', width: 70, height: 40, position: Offset(400, 80)),
                FcoseNode(id: 'free', width: 60, height: 90, position: Offset(200, 260)),
              ],
              edges: const [
                FcoseEdge(id: 'a1-a2', source: 'a1', target: 'a2', idealLength: 80),
                FcoseEdge(id: 'b1-b2', source: 'b1', target: 'b2', idealLength: 160),
                FcoseEdge(id: 'a1-b1', source: 'a1', target: 'b1', idealLength: 100),
                FcoseEdge(id: 'a2-free', source: 'a2', target: 'free', idealLength: 140),
                FcoseEdge(id: 'b2-free', source: 'b2', target: 'free', idealLength: 120),
              ],
            ),
          );

      expect(result.positionOf('a1'), Offset.zero);
      expect(result.positionOf('a2').x, closeTo(190, 1e-9));
      expect(result.positionOf('a2').y, closeTo(132.5, 1e-9));
      expect(result.positionOf('b1').x, closeTo(0, 1e-9));
      expect(result.positionOf('b1').y, closeTo(-47.5, 1e-9));
      expect(result.positionOf('b2').x, closeTo(400, 1e-9));
      expect(result.positionOf('b2').y, closeTo(result.positionOf('a2').y, 1e-9));
      expect(result.positionOf('free').x, closeTo(200, 1e-9));
      expect(result.positionOf('free').y, closeTo(307.5, 1e-9));
      expect(result.rectOf('left').containsRect(result.rectOf('left-inner')), isTrue);
      expect(result.rectOf('right').containsRect(result.rectOf('right-inner')), isTrue);
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

    test('uses average resolved edge length in an omitted relative-placement gap', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              step: LayoutStep.enforced,
              idealEdgeLength: 50,
              relativePlacements: [RelativePlacementConstraint.horizontal('a', 'c')],
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', position: Offset.zero),
                FcoseNode(id: 'b', position: Offset(10, 0)),
                FcoseNode(id: 'c', position: Offset(20, 0)),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b', idealLength: 80),
                FcoseEdge(id: 'bc', source: 'b', target: 'c', idealLength: 160),
              ],
            ),
          );

      expect(result.positionOf('c').x - result.positionOf('a').x, closeTo(150, 1e-9));
    });

    test('preserves upstream mixed-size implicit gaps through force refinement', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              relativePlacements: [
                RelativePlacementConstraint.horizontal('a', 'b'),
                RelativePlacementConstraint.vertical('c', 'd'),
              ],
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 40, height: 60, position: Offset.zero),
                FcoseNode(id: 'b', width: 100, height: 20, position: Offset(10, 0)),
                FcoseNode(id: 'c', width: 30, height: 80, position: Offset(0, 10)),
                FcoseNode(id: 'd', width: 70, height: 40, position: Offset(0, 20)),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b', idealLength: 80),
                FcoseEdge(id: 'cd', source: 'c', target: 'd', idealLength: 160),
              ],
            ),
          );

      expect(result.positionOf('b').x - result.positionOf('a').x, closeTo(190, 1e-9));
      expect(result.positionOf('b').y - result.positionOf('a').y, closeTo(-0.035872655514854, 1e-9));
      expect(result.positionOf('d').x - result.positionOf('c').x, closeTo(-1.88312109249442, 1e-9));
      expect(result.positionOf('d').y - result.positionOf('c').y, closeTo(221.92308086131816, 1e-9));
    });

    test('resolves only the first non-loop edge between each node pair', () {
      final idealLengthCalls = <String>[];
      final elasticityCalls = <String>[];
      final result =
          FcoseLayout(
            options: FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              step: LayoutStep.enforced,
              relativePlacements: const [RelativePlacementConstraint.horizontal('a', 'c')],
              idealEdgeLengthFor: (edge) {
                idealLengthCalls.add(edge.id);
                return edge.id == 'ab' ? 80 : 160;
              },
              edgeElasticityFor: (edge) {
                elasticityCalls.add(edge.id);
                return 0.45;
              },
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', position: Offset.zero),
                FcoseNode(id: 'b', position: Offset(10, 0)),
                FcoseNode(id: 'c', position: Offset(20, 0)),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b'),
                FcoseEdge(id: 'ba-duplicate', source: 'b', target: 'a'),
                FcoseEdge(id: 'aa-loop', source: 'a', target: 'a'),
                FcoseEdge(id: 'bc', source: 'b', target: 'c'),
              ],
            ),
          );

      expect(idealLengthCalls, ['ab', 'bc']);
      expect(elasticityCalls, ['ab', 'bc']);
      expect(result.positionOf('c').x - result.positionOf('a').x, closeTo(150, 1e-9));
    });

    test('exposes the transformed constraint-debug stage without refinement', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              step: LayoutStep.transformed,
              alignment: AlignmentConstraint(
                vertical: [
                  ['a', 'b'],
                ],
              ),
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', position: Offset.zero),
                FcoseNode(id: 'b', position: Offset(100, 100)),
                FcoseNode(id: 'free', position: Offset(100, 0)),
              ],
            ),
          );

      expect(result.iterations, 0);
      expect(result.positionOf('a').x, closeTo(14.64466094067263, 1e-9));
      expect(result.positionOf('a').y, closeTo(-20.71067811865474, 1e-9));
      expect(result.positionOf('b').x, closeTo(14.64466094067263, 1e-9));
      expect(result.positionOf('b').y, closeTo(120.71067811865474, 1e-9));
      expect(result.positionOf('free').x, closeTo(85.35533905932738, 1e-9));
      expect(result.positionOf('free').y, closeTo(50, 1e-9));
    });

    test('recenters a constrained layout on its original bounding box', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 1,
              nodeRepulsion: 0,
              gravity: 0,
              tile: false,
              packComponents: false,
              alignment: AlignmentConstraint(
                vertical: [
                  ['a', 'b'],
                ],
              ),
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', position: Offset.zero),
                FcoseNode(id: 'b', position: Offset(100, 100)),
                FcoseNode(id: 'free', position: Offset(100, 0)),
              ],
            ),
          );

      // Alignment pulls a and b onto a shared x of 50 and leaves free at 100,
      // so the result sits 25 to the right of where it started; constraints
      // disable packing, which makes the whole graph one component to move back.
      expect(result.positionOf('a').x, 25);
      expect(result.positionOf('b').x, 25);
      expect(result.positionOf('free').x, 75);
    });

    test('recenters on the bounding box the host reports, not the one it lays out', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 30,
              idealEdgeLength: 70,
              compoundPadding: 0,
              alignment: AlignmentConstraint(
                vertical: [
                  ['a', 'c'],
                ],
              ),
              relativePlacements: [RelativePlacementConstraint.vertical('a', 'b', gap: 90)],
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'p1'),
                FcoseNode(id: 'p2'),
                FcoseNode(id: 'a', parentId: 'p1', position: Offset.zero),
                FcoseNode(id: 'b', parentId: 'p1', position: Offset(60, 80)),
                FcoseNode(id: 'c', parentId: 'p2', position: Offset(220, 10)),
                FcoseNode(id: 'd', parentId: 'p2', position: Offset(280, 90)),
                FcoseNode(id: 'e', position: Offset(120, 220)),
                FcoseNode(id: 'f', position: Offset(10, 260)),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b'),
                FcoseEdge(id: 'cd', source: 'c', target: 'd'),
                FcoseEdge(id: 'ac', source: 'a', target: 'c'),
                FcoseEdge(id: 'eb', source: 'e', target: 'b'),
              ],
            ),
          );

      // The graph the layout produces is measured on cose-base rectangles, but
      // the center it is put back on came from the host, which stands a
      // compound's box a border-half and an antialiasing pixel outside its
      // children's. Two of these roots are compounds and two are plain, so the
      // two rulers disagree, and every node lands three quarters of a pixel
      // above where the layout's own measurement would have left it.
      expect(result.positionOf('a').x, closeTo(160.9947303055039, 1e-9));
      expect(result.positionOf('a').y, closeTo(-24.818793767226673, 1e-9));
      expect(result.positionOf('b').x, closeTo(61.72909721473022, 1e-9));
      expect(result.positionOf('b').y, closeTo(65.18120623277332, 1e-9));
      expect(result.positionOf('c').x, closeTo(160.9947303055039, 1e-9));
      expect(result.positionOf('c').y, closeTo(118.5068525395046, 1e-9));
      expect(result.positionOf('d').x, closeTo(271.63300926371664, 1e-9));
      expect(result.positionOf('d').y, closeTo(175.55900835096978, 1e-9));
      expect(result.positionOf('e').x, closeTo(58.19680384176683, 1e-9));
      expect(result.positionOf('e').y, closeTo(167.60980721123457, 1e-9));
      expect(result.positionOf('f').x, closeTo(8.366990736283393, 1e-9));
      expect(result.positionOf('f').y, closeTo(283.3187937672267, 1e-9));
    });

    test('exposes the enforced constraint-debug stage without refinement', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              step: LayoutStep.enforced,
              fixedNodes: [FixedNodeConstraint('a', Offset(10, 20))],
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', position: Offset.zero),
                FcoseNode(id: 'b', position: Offset(100, 100)),
                FcoseNode(id: 'c', position: Offset(200, 20)),
              ],
            ),
          );

      expect(result.iterations, 0);
      expect(result.positionOf('a'), const Offset(10, 20));
      expect(result.positionOf('b'), const Offset(110, 120));
      expect(result.positionOf('c'), const Offset(210, 40));
    });

    test('skips the spectral embedding for a debug step even when randomized', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              seed: 5,
              step: LayoutStep.enforced,
              alignment: AlignmentConstraint(
                vertical: [
                  ['a', 'd'],
                ],
              ),
              relativePlacements: [RelativePlacementConstraint.horizontal('a', 'b', gap: 140)],
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 60, height: 60),
                FcoseNode(id: 'b', width: 60, height: 60),
                FcoseNode(id: 'c', width: 60, height: 60),
                FcoseNode(id: 'd', width: 60, height: 60),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b'),
                FcoseEdge(id: 'bc', source: 'b', target: 'c'),
                FcoseEdge(id: 'cd', source: 'c', target: 'd'),
              ],
            ),
          );

      // Upstream calls the spectral routine for every randomized run, but the
      // routine embeds nothing unless the quality is draft or the step is the
      // whole pipeline; a debug step reads back the positions it was given.
      // Every node here starts at the origin, so only the constraints move
      // anything, and c, which no constraint names, does not move at all.
      expect(result.positionOf('a'), const Offset(-70, 0));
      expect(result.positionOf('b'), const Offset(70, 0));
      expect(result.positionOf('c'), Offset.zero);
      expect(result.positionOf('d'), const Offset(-70, 0));
    });

    test('starts the CoSE debug stage before constraint preprocessing', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              step: LayoutStep.cose,
              maxIterations: 20,
              idealEdgeLength: 80,
              fixedNodes: [FixedNodeConstraint('a', Offset(10, 20))],
              alignment: AlignmentConstraint(
                vertical: [
                  ['a', 'b'],
                ],
              ),
              relativePlacements: [RelativePlacementConstraint.horizontal('b', 'c', gap: 80)],
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', position: Offset.zero),
                FcoseNode(id: 'b', position: Offset(100, 100)),
                FcoseNode(id: 'c', position: Offset(200, 20)),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b'),
                FcoseEdge(id: 'bc', source: 'b', target: 'c'),
              ],
            ),
          );

      expect(result.iterations, greaterThan(0));
      expect(result.positionOf('a'), Offset.zero);
      expect(result.positionOf('b'), isNot(const Offset(100, 100)));
      expect(result.positions.values.every((position) => position.isFinite), isTrue);
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

    test('draft quality bypasses CoSE constraint preprocessing', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.draft,
              randomize: false,
              fixedNodes: [FixedNodeConstraint('a', Offset(10, 20))],
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', position: Offset.zero),
                FcoseNode(id: 'b', position: Offset(100, 50)),
              ],
              edges: const [FcoseEdge(id: 'ab', source: 'a', target: 'b')],
            ),
          );

      expect(result.iterations, 0);
      expect(result.positionOf('a'), Offset.zero);
      expect(result.positionOf('b'), const Offset(100, 50));
    });

    test('draft quality bypasses CoSE zero-degree tiling', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.draft,
              randomize: false,
              tile: true,
              packComponents: false,
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', position: Offset(0, 0)),
                FcoseNode(id: 'b', position: Offset(200, 0)),
                FcoseNode(id: 'c', position: Offset(0, 200)),
              ],
            ),
          );

      expect(result.iterations, 0);
      expect(result.positionOf('a'), Offset.zero);
      expect(result.positionOf('b'), const Offset(200, 0));
      expect(result.positionOf('c'), const Offset(0, 200));
    });

    test('spectrally connects disconnected child components inside a compound', () {
      final result = FcoseLayout(options: const FcoseOptions(quality: LayoutQuality.draft, seed: 7, tile: false)).run(
        FcoseGraph(
          nodes: const [
            FcoseNode(id: 'parent'),
            FcoseNode(id: 'a', parentId: 'parent'),
            FcoseNode(id: 'b', parentId: 'parent'),
            FcoseNode(id: 'c', parentId: 'parent'),
            FcoseNode(id: 'd', parentId: 'parent'),
          ],
          edges: const [
            FcoseEdge(id: 'ab', source: 'a', target: 'b'),
            FcoseEdge(id: 'cd', source: 'c', target: 'd'),
          ],
        ),
      );

      expect(result.rectOf('a').overlaps(result.rectOf('c')), isFalse);
      expect(result.rectOf('b').overlaps(result.rectOf('d')), isFalse);
      expect(result.rectOf('parent').containsRect(result.rectOf('a')), isTrue);
      expect(result.rectOf('parent').containsRect(result.rectOf('d')), isTrue);
      // Upstream values from tool/oracle/specs/draft-compound.json, which draws
      // the same random stream as this seed; power iteration converges slightly
      // differently in the two languages, hence the millionth of a pixel.
      expect(result.positionOf('a').x, closeTo(74.99949047260667, 1e-6));
      expect(result.positionOf('a').y, closeTo(-5.492685845029593, 1e-6));
      expect(result.positionOf('b').x, closeTo(149.99898100619504, 1e-6));
      expect(result.positionOf('b').y, closeTo(5.492686261365482, 1e-6));
      expect(result.positionOf('c').x, closeTo(-74.9994905335884, 1e-6));
      expect(result.positionOf('c').y, closeTo(-5.492686261365481, 1e-6));
      expect(result.positionOf('d').x, closeTo(-149.99898100619504, 1e-6));
      expect(result.positionOf('d').y, closeTo(5.492685428693705, 1e-6));
    });

    test('uses one root spectral graph for disconnected top-level components', () {
      // Packing is what makes upstream embed one component at a time; with it
      // off, both components share a single spectral graph tied together by root
      // dummy nodes, which is the path this case covers.
      final result =
          FcoseLayout(
            options: const FcoseOptions(quality: LayoutQuality.draft, seed: 7, tile: false, packComponents: false),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a'),
                FcoseNode(id: 'b'),
                FcoseNode(id: 'c'),
                FcoseNode(id: 'd'),
              ],
              edges: const [
                FcoseEdge(id: 'ab', source: 'a', target: 'b'),
                FcoseEdge(id: 'cd', source: 'c', target: 'd'),
              ],
            ),
          );

      // Port values. Upstream cannot produce any for this graph: its default
      // ideal edge length is a function, and the two-node shortcut of
      // spectral.js adds that option to a coordinate without calling it. See
      // tool/oracle/specs/draft-disconnected.json.
      final firstEdge = result.positionOf('b') - result.positionOf('a');
      final secondEdge = result.positionOf('d') - result.positionOf('c');
      expect(firstEdge.x, closeTo(74.99949049350419, 1e-3));
      expect(firstEdge.y, closeTo(10.985371832731135, 1e-3));
      expect(secondEdge.x, closeTo(-74.999490512691, 1e-3));
      expect(secondEdge.y, closeTo(10.98537196372347, 1e-3));
    });

    test('stacks owner-level dummy connections through nested compounds', () {
      final result = FcoseLayout(options: const FcoseOptions(quality: LayoutQuality.draft, seed: 7, tile: false)).run(
        FcoseGraph(
          nodes: const [
            FcoseNode(id: 'outer'),
            FcoseNode(id: 'left', parentId: 'outer'),
            FcoseNode(id: 'busy', parentId: 'left'),
            FcoseNode(id: 'quiet', parentId: 'left'),
            FcoseNode(id: 'standalone', parentId: 'outer'),
          ],
          edges: const [FcoseEdge(id: 'loop', source: 'busy', target: 'busy')],
        ),
      );

      // Upstream values from tool/oracle/specs/draft-nested-compound.json.
      expect(result.positionOf('busy').x, closeTo(-149.99898100619524, 1e-9));
      expect(result.positionOf('busy').y, closeTo(-7.323581344185225, 1e-9));
      expect(result.positionOf('quiet').x, closeTo(1.5369854544902844e-8, 1e-9));
      expect(result.positionOf('quiet').y, closeTo(7.323581344185227, 1e-9));
      expect(result.positionOf('standalone').x, closeTo(149.99898100619524, 1e-9));
      expect(result.positionOf('standalone').y, closeTo(-7.3235810293843855, 1e-9));
      expect(result.rectOf('left').containsRect(result.rectOf('busy')), isTrue);
      expect(result.rectOf('outer').containsRect(result.rectOf('standalone')), isTrue);
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

    test('uses center distances for uniform leaf node force calculations', () {
      FcoseResult run({required bool uniformNodeDimensions}) =>
          FcoseLayout(
            options: FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              maxIterations: 1000,
              tile: false,
              idealEdgeLength: 80,
              uniformNodeDimensions: uniformNodeDimensions,
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'a', width: 120, height: 40, position: Offset(0, 0)),
                FcoseNode(id: 'b', width: 20, height: 100, position: Offset(300, 0)),
              ],
              edges: const [FcoseEdge(id: 'ab', source: 'a', target: 'b')],
            ),
          );

      final clipped = run(uniformNodeDimensions: false);
      final uniform = run(uniformNodeDimensions: true);

      expect(clipped.positionOf('a').distanceTo(clipped.positionOf('b')), greaterThan(130));
      expect(uniform.positionOf('a').distanceTo(uniform.positionOf('b')), closeTo(109.45297568384221, 1e-9));
      expect(
        uniform.positionOf('a').distanceTo(uniform.positionOf('b')),
        lessThan(clipped.positionOf('a').distanceTo(clipped.positionOf('b'))),
      );
    });

    test('matches upstream constrained three-node chain spacing', () {
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

    test('preserves row-aligned fan-in constraints during force refinement', () {
      final result =
          FcoseLayout(
            options: const FcoseOptions(
              quality: LayoutQuality.proof,
              randomize: false,
              idealEdgeLength: 120,
              edgeElasticity: 0.45,
              alignment: AlignmentConstraint(
                horizontal: [
                  ['src1', 'src2', 'src3'],
                ],
              ),
              relativePlacements: [
                RelativePlacementConstraint.horizontal('src1', 'src2', gap: 120),
                RelativePlacementConstraint.horizontal('src2', 'src3', gap: 120),
                RelativePlacementConstraint.vertical('src3', 'proc', gap: 120),
              ],
            ),
          ).run(
            FcoseGraph(
              nodes: const [
                FcoseNode(id: 'src1', width: 80, height: 80, position: Offset(0, 0)),
                FcoseNode(id: 'src2', width: 80, height: 80, position: Offset.zero),
                FcoseNode(id: 'src3', width: 80, height: 80, position: Offset.zero),
                FcoseNode(id: 'proc', width: 80, height: 80, position: Offset.zero),
              ],
              edges: const [
                FcoseEdge(id: '1p', source: 'src1', target: 'proc'),
                FcoseEdge(id: '2p', source: 'src2', target: 'proc'),
                FcoseEdge(id: '3p', source: 'src3', target: 'proc'),
              ],
            ),
          );

      expect(result.positionOf('src1').y, closeTo(result.positionOf('src2').y, 1e-9));
      expect(result.positionOf('src2').y, closeTo(result.positionOf('src3').y, 1e-9));
      expect(result.positionOf('src2').x - result.positionOf('src1').x, greaterThanOrEqualTo(120));
      expect(result.positionOf('src3').x - result.positionOf('src2').x, greaterThanOrEqualTo(120));
      expect(result.positionOf('proc').y - result.positionOf('src3').y, greaterThanOrEqualTo(120));
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

    test('validates fixed-node constraints against the dimension-aware default gap', () {
      final graph = FcoseGraph(
        nodes: const [
          FcoseNode(id: 'a'),
          FcoseNode(id: 'b'),
          FcoseNode(id: 'c'),
        ],
        edges: const [
          FcoseEdge(id: 'ab', source: 'a', target: 'b', idealLength: 80),
          FcoseEdge(id: 'bc', source: 'b', target: 'c', idealLength: 160),
        ],
      );
      expect(
        () => FcoseLayout(
          options: const FcoseOptions(
            fixedNodes: [FixedNodeConstraint('a', Offset.zero), FixedNodeConstraint('c', Offset(135, 0))],
            relativePlacements: [RelativePlacementConstraint.horizontal('a', 'c')],
          ),
        ).run(graph),
        throwsArgumentError,
      );
    });

    test('keeps the flat n=800 spring hot path bit-stable', () {
      // Characterization lock for allocation-free spring ticks: same graph, seed,
      // and options as tool/bench_layout.dart's common fixture.
      final side = 29; // ceil(sqrt(800))
      final nodes = [for (var i = 0; i < 800; i++) FcoseNode(id: 'n$i', width: 40, height: 30)];
      final edges = <FcoseEdge>[];
      for (var i = 0; i < 800; i++) {
        final x = i % side;
        final y = i ~/ side;
        if (x + 1 < side && i + 1 < 800) {
          edges.add(FcoseEdge(id: 'e${i}_r', source: 'n$i', target: 'n${i + 1}', idealLength: 50));
        }
        final below = i + side;
        if (y + 1 < side && below < 800) {
          edges.add(FcoseEdge(id: 'e${i}_d', source: 'n$i', target: 'n$below', idealLength: 50));
        }
      }
      final result = FcoseLayout(
        options: const FcoseOptions(
          quality: LayoutQuality.proof,
          randomize: true,
          seed: 7,
          packComponents: false,
          tile: false,
        ),
      ).run(FcoseGraph(nodes: nodes, edges: edges));

      final ids = result.positions.keys.toList()..sort();
      final dump = StringBuffer();
      for (final id in ids) {
        final point = result.positions[id]!;
        dump.writeln('$id ${point.x.toStringAsExponential(17)} ${point.y.toStringAsExponential(17)}');
      }
      var hash = 0xcbf29ce484222325;
      for (final unit in dump.toString().codeUnits) {
        hash ^= unit;
        hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
      }
      expect(hash.toRadixString(16).padLeft(16, '0'), '0971402e9cafe83a');
    });
  });
}
