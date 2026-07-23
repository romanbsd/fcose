# fcose

A framework-independent, pure Dart graph layout engine under development for a
Dart port of Mermaid.js. The package is not yet a complete or parity-verified
fCoSE port and should not be published as a drop-in replacement yet.

The package accepts measured node rectangles and compound parent IDs, then
returns center positions and final rectangles. Rendering and edge routing stay
with the Mermaid renderer.

## Implemented foundations

- validated undirected compound graph model;
- sampled deterministic spectral initialization;
- rectangle-clipped CoSE springs, repulsion, gravity, cooling, and convergence;
- live compound-node forces, nesting-aware edge lengths, and compound gravity;
- disconnected-component detection and packing;
- bottom-up compound bounds with configurable padding;
- transformed and displacement-relaxed fixed, alignment, and DAG placement constraints;
- typed quality and greedy/random sampling options;
- Mermaid architecture adapter for topology-specific springs, directional
  constraints, compound padding, and the renderer's two-pass layout lifecycle.

## Mermaid renderer integration

Measure service/group labels and icons before layout, create an `FcoseNode` for
each service and group, and use `parentId` for nested Mermaid groups. Supply
Cytoscape-grid initial positions when `randomize` is false, then configure the
directional architecture links and declared alignment hints:

```dart
const adapter = MermaidFcoseAdapter(
  iconSize: 80,
  idealEdgeLengthMultiplier: 1.5,
  edgeElasticity: 0.45,
);
final configuration = adapter.configureArchitecture(
  graph,
  directionalEdges: directionalEdges,
  layoutHints: const [
    MermaidAlignmentHint(
      MermaidAlignmentDirection.row,
      ['source-a', 'source-b'],
    ),
  ],
);
final result = configuration.runMermaidArchitecture();

final serviceCenter = result.positionOf('source-a');
final groupBounds = result.rectOf('group-id');
```

`runMermaidArchitecture()` intentionally runs fCoSE twice. Mermaid's
architecture renderer invokes a second layout from its one-shot `layoutstop`
callback, using the first pass positions as the second pass input. For a
single-pass general graph layout, call:

```dart
final result = FcoseLayout(
  options: configuration.options,
).run(
  configuration.graph,
);
```

The adapter now reproduces Mermaid's directional spatial maps, pairwise
alignment flattening, duplicate constraints, and JavaScript object-key ordering.
Its first pass matches the browser-backed Mermaid 11.16 deep-compound fixture
exactly. Full second-pass parity is still in progress: Cytoscape expands
compound bounds using child label boxes between passes, while `FcoseNode`
currently carries only the force rectangle. The same fixture is within four
pixels after pass two, but consumers should not claim exact renderer parity
until label-aware compound bounds are represented.

Renderer-specific ports, labels, SVG paths, and icon placement should be
computed after layout.

## Upstream mapping

The implementation is being split along the three upstream layers:

| Dart concern | Upstream source |
| --- | --- |
| geometry, graph validation, components | `layout-base` |
| spring embedding, cooling, compound bounds | `cose-base` |
| spectral start, constraints, public options | `cytoscape.js-fcose` 2.2.0 |

The public API uses Dart value types and enums rather than reproducing the
Cytoscape.js adapter. This is intentional: the consumer is a Dart Mermaid
renderer and not a JavaScript graph widget.

The upstream projects and this port are MIT licensed.
