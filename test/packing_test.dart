import 'dart:math' as math;

import 'package:fcose/fcose.dart';
import 'package:fcose/src/packing.dart';
import 'package:fcose/src/pose_packing.dart';
import 'package:test/test.dart';

void main() {
  test('randomized polyomino packing matches layout-utilities 1.1.1', () {
    final components = [
      const PackingComponent(
        nodes: [Rect(0, 0, 30, 30), Rect(100, 0, 30, 30)],
        edges: [(start: Offset(15, 15), end: Offset(115, 15))],
      ),
      const PackingComponent(
        nodes: [Rect(300, 200, 60, 20), Rect(320, 280, 20, 60)],
        edges: [(start: Offset(330, 210), end: Offset(330, 310))],
      ),
      const PackingComponent(nodes: [Rect(-100, 50, 40, 40)], edges: []),
    ];

    final shifts = const RandomizedComponentPacker().pack(components);

    expect(shifts, const [Offset(56, 263), Offset(-244, -153), Offset(264, 105)]);
  });

  test('randomized polyomino packing matches layout-utilities 1.1.1 weighted utility', () {
    final components = [
      const PackingComponent(
        nodes: [Rect(0, 0, 30, 30), Rect(100, 0, 30, 30)],
        edges: [(start: Offset(15, 15), end: Offset(115, 15))],
      ),
      const PackingComponent(
        nodes: [Rect(300, 200, 60, 20), Rect(320, 280, 20, 60)],
        edges: [(start: Offset(330, 210), end: Offset(330, 310))],
      ),
      const PackingComponent(nodes: [Rect(-100, 50, 40, 40)], edges: []),
    ];

    final shifts = const RandomizedComponentPacker(utility: PackingUtility.weighted).pack(components);

    expect(shifts, const [Offset(10, 46), Offset(-110, -46), Offset(110, 104)]);
  });

  test('randomized polyomino packing preserves the combined bounding-box center', () {
    final components = [
      const PackingComponent(nodes: [Rect(-250, -30, 80, 20)], edges: []),
      const PackingComponent(nodes: [Rect(400, 120, 30, 90)], edges: []),
    ];
    final before = PackingComponent.combinedBounds(components).center;

    final shifts = const RandomizedComponentPacker().pack(components);
    final shifted = [
      for (var index = 0; index < components.length; index++) components[index].translated(shifts[index]),
    ];

    expect(PackingComponent.combinedBounds(shifted).center, before);
  });

  test('randomized polyomino packing rejects a grid it cannot allocate', () {
    // Tiny nodes drive the grid step down to one pixel while the grid still
    // spans twice the summed component extent, so a couple of hundred of them
    // ask for more cells than any packing they could produce.
    final components = [
      for (var index = 0; index < 200; index++) PackingComponent(nodes: [Rect(index * 1000, 0, 1, 1)], edges: const []),
    ];

    expect(
      () => const RandomizedComponentPacker().pack(components),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          allOf(contains('grid'), contains('gridSizeFactor')),
        ),
      ),
    );
  });

  test('incremental POSE packing matches layout-utilities 1.1.1', () {
    final components = [
      const PackingComponent(nodes: [Rect(0, 0, 40, 20)], edges: []),
      const PackingComponent(nodes: [Rect(15, 10, 30, 30)], edges: []),
      const PackingComponent(
        nodes: [Rect(80, 10, 20, 20), Rect(110, 20, 20, 30)],
        edges: [(start: Offset(90, 20), end: Offset(120, 35))],
      ),
    ];

    final shifts = const IncrementalComponentPacker(componentSpacing: 80).pack(components);

    _expectOffsetClose(shifts[0], const Offset(-20.000083717081107, -30.21939570147316));
    _expectOffsetClose(shifts[1], const Offset(38.320849004283275, 52.51313036188453));
    _expectOffsetClose(shifts[2], const Offset(20.00008371708113, -52.51313036188453));
  });

  test('incremental POSE packing clamps zero component spacing like layout-utilities', () {
    final shifts = const IncrementalComponentPacker(componentSpacing: 0).pack([
      const PackingComponent(nodes: [Rect(0, 0, 40, 20)], edges: []),
      const PackingComponent(nodes: [Rect(15, 10, 30, 30)], edges: []),
    ]);

    _expectOffsetClose(shifts[0], const Offset(-14.392267351610178, -6.35161944419734), tolerance: 1e-9);
    _expectOffsetClose(shifts[1], const Offset(14.392267351610178, 6.35161944419734), tolerance: 1e-9);
  });

  test('incremental POSE packing matches upstream Delaunay edge refreshes', () {
    final shifts = const IncrementalComponentPacker(componentSpacing: 50).pack([
      const PackingComponent(nodes: [Rect(0, 0, 20, 20)], edges: []),
      const PackingComponent(nodes: [Rect(50, 10, 30, 20)], edges: []),
      const PackingComponent(nodes: [Rect(10, 70, 20, 30)], edges: []),
      const PackingComponent(nodes: [Rect(100, 100, 40, 20)], edges: []),
    ]);

    const expected = [
      Offset(4.437313773086529, 10.007236439946134),
      Offset(24.435605121689427, 9.166838411831492),
      Offset(15.563980588714562, 9.99276356005387),
      Offset(-4.437313773086537, -10.834914752297184),
    ];
    // Tiny Dart/JavaScript numeric differences compound over 100 force steps.
    for (var index = 0; index < shifts.length; index++) {
      _expectOffsetClose(shifts[index], expected[index], tolerance: 0.02);
    }
  });

  test('incremental POSE packing matches one upstream force step', () {
    final shifts = const IncrementalComponentPacker(componentSpacing: 50, iterations: 1).pack([
      const PackingComponent(nodes: [Rect(0, 0, 20, 20)], edges: []),
      const PackingComponent(nodes: [Rect(50, 10, 30, 20)], edges: []),
      const PackingComponent(nodes: [Rect(10, 70, 20, 30)], edges: []),
      const PackingComponent(nodes: [Rect(100, 100, 40, 20)], edges: []),
    ]);

    const expected = [
      Offset(-0.7253697169422422, 1.0357527713992098),
      Offset(8.171597460209917, 2.45173965402656),
      Offset(4.881621913126693, 1.6912714315702753),
      Offset(0.7253697169422493, -1.0357527713992054),
    ];
    for (var index = 0; index < shifts.length; index++) {
      _expectOffsetClose(shifts[index], expected[index], tolerance: 1e-9);
    }
  });

  test('incremental POSE packing matches upstream before the first edge refresh', () {
    final shifts = const IncrementalComponentPacker(componentSpacing: 50, iterations: 5).pack([
      const PackingComponent(nodes: [Rect(0, 0, 20, 20)], edges: []),
      const PackingComponent(nodes: [Rect(50, 10, 30, 20)], edges: []),
      const PackingComponent(nodes: [Rect(10, 70, 20, 30)], edges: []),
      const PackingComponent(nodes: [Rect(100, 100, 40, 20)], edges: []),
    ]);

    const expected = [
      Offset(0.23213414872615878, 4.031958054893913),
      Offset(18.586459313169023, 8.222436831331517),
      Offset(13.15743318166388, 5.687538881253292),
      Offset(-0.23213414872614457, -4.031958054893911),
    ];
    for (var index = 0; index < shifts.length; index++) {
      _expectOffsetClose(shifts[index], expected[index], tolerance: 1e-9);
    }
  });

  test('incremental POSE packing keeps shifts finite for exactly touching components', () {
    // The Minkowski difference has the origin on one of its edges, so the
    // separating direction is undefined and convex-polygon-distance.ts would
    // divide by zero.
    final shifts = const IncrementalComponentPacker(componentSpacing: 50).pack([
      const PackingComponent(nodes: [Rect(0, 0, 20, 20)], edges: []),
      const PackingComponent(nodes: [Rect(20, 0, 20, 20)], edges: []),
      const PackingComponent(nodes: [Rect(40, 0, 20, 20)], edges: []),
    ]);

    for (final shift in shifts) {
      expect(shift.x.isFinite, isTrue);
      expect(shift.y.isFinite, isTrue);
    }
  });

  test('fCoSE applies incremental POSE shifts when randomization is disabled', () {
    final graph = FcoseGraph(
      nodes: const [
        FcoseNode(id: 'a', width: 40, height: 20, position: Offset(20, 10)),
        FcoseNode(id: 'b', width: 30, height: 30, position: Offset(30, 25)),
        FcoseNode(id: 'c', width: 20, height: 20, position: Offset(90, 20)),
        FcoseNode(id: 'd', width: 20, height: 30, position: Offset(120, 35)),
      ],
      edges: const [FcoseEdge(id: 'cd', source: 'c', target: 'd')],
    );

    final result = FcoseLayout(
      options: const FcoseOptions(quality: LayoutQuality.draft, randomize: false, tile: false, componentSeparation: 80),
    ).run(graph);

    _expectOffsetClose(result.positionOf('a'), const Offset(-0.000083717081107, -20.21939570147316));
    _expectOffsetClose(result.positionOf('b'), const Offset(68.32084900428328, 77.51313036188453));
    _expectOffsetClose(result.positionOf('c'), const Offset(110.00008371708113, -32.51313036188453));
    _expectOffsetClose(result.positionOf('d'), const Offset(140.00008371708113, -17.51313036188453));
  });

  test('fCoSE applies randomized polyomino shifts to whole components', () {
    final graph = FcoseGraph(
      nodes: const [
        FcoseNode(id: 'a', width: 30, height: 20, position: Offset(-200, -100)),
        FcoseNode(id: 'b', width: 50, height: 30, position: Offset(-100, -100)),
        FcoseNode(id: 'c', width: 40, height: 60, position: Offset(300, 200)),
        FcoseNode(id: 'd', width: 30, height: 30, position: Offset(300, 300)),
        FcoseNode(id: 'e', width: 45, height: 25, position: Offset(500, -50)),
      ],
      edges: const [
        FcoseEdge(id: 'ab', source: 'a', target: 'b'),
        FcoseEdge(id: 'cd', source: 'c', target: 'd'),
      ],
    );
    const baseOptions = FcoseOptions(
      quality: LayoutQuality.draft,
      randomize: true,
      seed: 7,
      tile: false,
      packComponents: false,
    );
    // Packing sends every component through its own spectral pass, so the
    // baseline is one unpacked run per component rather than one for the graph.
    final componentIds = [
      ['a', 'b'],
      ['c', 'd'],
      ['e'],
    ];
    final unpacked = [
      for (final ids in componentIds)
        FcoseLayout(options: baseOptions).run(
          FcoseGraph(
            nodes: [for (final id in ids) graph.nodeById[id]!],
            edges: graph.edges.where((edge) => ids.contains(edge.source) && ids.contains(edge.target)),
          ),
        ),
    ];
    final originalComponents = [
      const PackingComponent(nodes: [Rect(-215, -110, 30, 20), Rect(-125, -115, 50, 30)], edges: []),
      const PackingComponent(nodes: [Rect(280, 170, 40, 60), Rect(285, 285, 30, 30)], edges: []),
      const PackingComponent(nodes: [Rect(477.5, -62.5, 45, 25)], edges: []),
    ];
    final relocated = <PackingComponent>[];
    final relocations = <Offset>[];
    for (final (index, ids) in componentIds.indexed) {
      final component = unpacked[index];
      final bounds = ids.skip(1).fold(component.rectOf(ids.first), (value, id) => value.union(component.rectOf(id)));
      final relocation = PackingComponent.combinedBounds([originalComponents[index]]).center - bounds.center;
      relocations.add(relocation);
      relocated.add(
        PackingComponent(
          nodes: [for (final id in ids) component.rectOf(id).shift(relocation)],
          edges: [
            for (final edge in graph.edges)
              if (ids.contains(edge.source) && ids.contains(edge.target))
                (
                  start: component.positionOf(edge.source) + relocation,
                  end: component.positionOf(edge.target) + relocation,
                ),
          ],
        ),
      );
    }
    final shifts = const RandomizedComponentPacker().pack(relocated);

    final packed = FcoseLayout(
      options: const FcoseOptions(
        quality: LayoutQuality.draft,
        randomize: true,
        seed: 7,
        tile: false,
        packComponents: true,
      ),
    ).run(graph);

    for (final (index, ids) in componentIds.indexed) {
      for (final id in ids) {
        _expectOffsetClose(packed.positionOf(id), unpacked[index].positionOf(id) + relocations[index] + shifts[index]);
      }
    }
  });
  test('randomized polyomino packing separates hundreds of components', () {
    final components = _scatteredComponents(800);
    final before = PackingComponent.combinedBounds(components).center;

    final watch = Stopwatch()..start();
    final shifts = const RandomizedComponentPacker().pack(components);
    final elapsed = watch.elapsed;
    final packed = [for (final (index, component) in components.indexed) component.translated(shifts[index])];

    expect(_overlappingPairs(packed), 0);
    expect(PackingComponent.combinedBounds(packed).center, before);
    // The grid is laid out once and each polyomino placed into it, so the cost
    // is near linear in the component count; the ceiling is two orders of
    // magnitude above the measured time, which leaves it insensitive to a busy
    // machine while still catching a change of complexity class.
    expect(elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('incremental POSE packing stays finite and repeatable at hundreds of components', () {
    final components = _scatteredComponents(800);

    final watch = Stopwatch()..start();
    final shifts = const IncrementalComponentPacker(componentSpacing: 80).pack(components);
    final elapsed = watch.elapsed;

    for (final shift in shifts) {
      expect(shift.x.isFinite, isTrue);
      expect(shift.y.isFinite, isTrue);
    }
    // Upstream's POSE is a fixed number of force steps over a Delaunay
    // triangulation, not a separation algorithm: it leaves components
    // overlapping when they start crowded, and the only guarantees at this size
    // are that it terminates with finite shifts and repeats itself.
    expect(const IncrementalComponentPacker(componentSpacing: 80).pack(components), shifts);
    expect(elapsed, lessThan(const Duration(seconds: 10)));
  });
}

/// Single-node components spread over a wide area, sized and placed by a
/// generator of its own so the fixture cannot shift when the layout's random
/// stream changes.
List<PackingComponent> _scatteredComponents(int count) {
  final random = math.Random(1);
  return [
    for (var index = 0; index < count; index++)
      PackingComponent(
        nodes: [
          Rect(
            random.nextInt(4000).toDouble(),
            random.nextInt(4000).toDouble(),
            30 + random.nextInt(40).toDouble(),
            20 + random.nextInt(40).toDouble(),
          ),
        ],
        edges: const [],
      ),
  ];
}

int _overlappingPairs(List<PackingComponent> components) {
  final bounds = [
    for (final component in components) PackingComponent.combinedBounds([component]),
  ];
  var count = 0;
  for (var first = 0; first < bounds.length; first++) {
    for (var second = first + 1; second < bounds.length; second++) {
      final a = bounds[first];
      final b = bounds[second];
      if (a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom) count++;
    }
  }
  return count;
}

void _expectOffsetClose(Offset actual, Offset expected, {double tolerance = 1e-12}) {
  expect(actual.x, closeTo(expected.x, tolerance));
  expect(actual.y, closeTo(expected.y, tolerance));
}
