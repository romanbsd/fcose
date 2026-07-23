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
    final unpacked = FcoseLayout(options: baseOptions).run(graph);
    final originalComponents = [
      const PackingComponent(nodes: [Rect(-215, -110, 30, 20), Rect(-125, -115, 50, 30)], edges: []),
      const PackingComponent(nodes: [Rect(280, 170, 40, 60), Rect(285, 285, 30, 30)], edges: []),
      const PackingComponent(nodes: [Rect(477.5, -62.5, 45, 25)], edges: []),
    ];
    final relocated = <PackingComponent>[];
    final relocations = <Offset>[];
    for (final (index, ids) in [
      ['a', 'b'],
      ['c', 'd'],
      ['e'],
    ].indexed) {
      final bounds = ids.skip(1).fold(unpacked.rectOf(ids.first), (value, id) => value.union(unpacked.rectOf(id)));
      final relocation = PackingComponent.combinedBounds([originalComponents[index]]).center - bounds.center;
      relocations.add(relocation);
      relocated.add(
        PackingComponent(
          nodes: [for (final id in ids) unpacked.rectOf(id).shift(relocation)],
          edges: switch (ids) {
            ['a', 'b'] => [(start: unpacked.positionOf('a') + relocation, end: unpacked.positionOf('b') + relocation)],
            ['c', 'd'] => [(start: unpacked.positionOf('c') + relocation, end: unpacked.positionOf('d') + relocation)],
            _ => const [],
          },
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

    for (final id in ['a', 'b']) {
      _expectOffsetClose(packed.positionOf(id), unpacked.positionOf(id) + relocations[0] + shifts[0]);
    }
    for (final id in ['c', 'd']) {
      _expectOffsetClose(packed.positionOf(id), unpacked.positionOf(id) + relocations[1] + shifts[1]);
    }
    _expectOffsetClose(packed.positionOf('e'), unpacked.positionOf('e') + relocations[2] + shifts[2]);
  });
}

void _expectOffsetClose(Offset actual, Offset expected, {double tolerance = 1e-12}) {
  expect(actual.x, closeTo(expected.x, tolerance));
  expect(actual.y, closeTo(expected.y, tolerance));
}
