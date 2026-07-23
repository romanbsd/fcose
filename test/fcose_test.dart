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
        seed: 1,
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
      expect(result.positionOf('a').x, closeTo(99.42754483305276, 0.1));
      expect(result.positionOf('a').y, closeTo(71.29156688814719, 0.1));
      expect(result.positionOf('b').x, closeTo(300.5724551669472, 0.1));
      expect(result.positionOf('b').y, closeTo(71.29156688814717, 0.1));
      expect(result.positionOf('c').x, closeTo(200, 0.1));
      expect(result.positionOf('c').y, closeTo(257.41686622370565, 0.1));
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
      expect(result.positionOf('a').x, closeTo(-1.7449812875310613, 1e-9));
      expect(result.positionOf('a').y, closeTo(63.13372421802022, 1e-9));
      expect(result.positionOf('b').x, closeTo(182.3138206405454, 1e-9));
      expect(result.positionOf('b').y, closeTo(84.30974146150082, 1e-9));
      expect(result.positionOf('c').x, closeTo(138.46636658037528, 1e-9));
      expect(result.positionOf('c').y, closeTo(262.556534320479, 1e-9));
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
      expect(result.positionOf('a').x, closeTo(49.420136929912445, 1e-9));
      expect(result.positionOf('a').y, closeTo(49.771008899324826, 1e-9));
      expect(result.positionOf('b').x, closeTo(350.79771567254494, 1e-9));
      expect(result.positionOf('b').y, closeTo(49.36502226812051, 1e-9));
      expect(result.positionOf('c').x, closeTo(199.78214739754267, 1e-9));
      expect(result.positionOf('c').y, closeTo(300.8639688325547, 1e-9));
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
      // Direct cose-base output before cytoscape-fcose's renderer relocation.
      // Repeated nonlinear ticks differ slightly between JavaScript and Dart,
      // but every completed center remains within a third of a logical pixel.
      expect(result.positionOf('a').x, closeTo(-22.580760794102254, 0.3));
      expect(result.positionOf('a').y, closeTo(1.1982125902694278, 0.3));
      expect(result.positionOf('b').x, closeTo(158.4767465117048, 0.3));
      expect(result.positionOf('b').y, closeTo(-6.613846539817089, 0.3));
      expect(result.positionOf('c').x, closeTo(96.26520854371415, 0.3));
      expect(result.positionOf('c').y, closeTo(185.7875863654262, 0.3));
      expect(result.positionOf('d').x, closeTo(323.0063977757626, 0.3));
      expect(result.positionOf('d').y, closeTo(-1.3153448560261296, 0.3));
      expect(result.positionOf('e').x, closeTo(487.40026951310483, 0.3));
      expect(result.positionOf('e').y, closeTo(-3.9655620530495312, 0.3));
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
      expect(result.positionOf('d').x, closeTo(1006.6076986228201, 0.5));
      expect(result.positionOf('e').x, closeTo(1685.3713349584318, 0.5));
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
      expect(result.positionOf('a').x, closeTo(341.99761397724626, 1e-9));
      expect(result.positionOf('a').y, closeTo(262.76796095323914, 1e-9));
      expect(result.positionOf('b').x, closeTo(582.7293147521211, 1e-9));
      expect(result.positionOf('b').y, closeTo(262.7667011210557, 1e-9));
      expect(result.positionOf('c').x, closeTo(375.27307127063233, 1e-9));
      expect(result.positionOf('c').y, closeTo(474.4653379257053, 1e-9));
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

      expect(result.positionOf('a').x, closeTo(67.01003008210519, 1e-9));
      expect(result.positionOf('a').y, closeTo(20.887744650386477, 1e-9));
      expect(result.positionOf('b').x, closeTo(268.80964560030645, 1e-9));
      expect(result.positionOf('b').y, closeTo(6.062370762764665, 1e-9));
      expect(result.positionOf('e').x, closeTo(201.79459405917498, 1e-9));
      expect(result.positionOf('e').y, closeTo(196.914018004143, 1e-9));
      expect(result.positionOf('c').x, closeTo(31.190354399693568, 1e-9));
      expect(result.positionOf('c').y, closeTo(293.93762923723534, 1e-9));
      expect(result.positionOf('d').x, closeTo(121.19035439969358, 1e-9));
      expect(result.positionOf('d').y, closeTo(293.93762923723534, 1e-9));
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
  });
}
