import 'package:fcose/fcose.dart';
import 'package:fcose/src/packing.dart';
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

void _expectOffsetClose(Offset actual, Offset expected) {
  expect(actual.x, closeTo(expected.x, 1e-12));
  expect(actual.y, closeTo(expected.y, 1e-12));
}
