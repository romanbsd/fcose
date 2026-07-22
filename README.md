# fcose

A framework-independent, pure Dart graph layout engine under development for a
Dart port of Mermaid.js. The package is not yet a complete or parity-verified
fCoSE port and should not be published as a drop-in replacement yet.

The package accepts measured node rectangles and compound parent IDs, then
returns center positions and final rectangles. Rendering and edge routing stay
with the Mermaid renderer.

## Implemented foundations

- validated undirected compound graph model;
- experimental deterministic landmark initialization;
- CoSE-style spring, repulsion, gravity, cooling, and convergence;
- disconnected-component detection and packing;
- bottom-up compound bounds with configurable padding;
- fixed-node, horizontal/vertical alignment, and relative-placement constraints;
- typed quality and sampling options (full upstream semantics are still being ported);
- Mermaid option adapter for `randomize`, `nodeSeparation`,
  `idealEdgeLengthMultiplier`, `edgeElasticity`, and `numIter`.

## Mermaid renderer integration

Measure service/group labels and icons before layout, create an `FcoseNode` for
each service and group, and use `parentId` for nested Mermaid groups. Convert
links into `FcoseEdge` values and call:

```dart
final result = FcoseLayout(
  options: FcoseOptions.mermaid(
    randomize: false,
    nodeSeparation: 75,
    idealEdgeLengthMultiplier: 1,
    edgeElasticity: 0.45,
    numIter: 2500,
  ),
).run(graph);

final serviceCenter = result.positionOf('service-id');
final groupBounds = result.rectOf('group-id');
```

For directional Mermaid links, generate relative-placement constraints. A
left-to-right link uses `RelativePlacementConstraint.horizontal(source,
target)`; a top-to-bottom link uses the vertical constructor. Renderer-specific
ports, labels, SVG paths, and icon placement should be computed after layout.

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
