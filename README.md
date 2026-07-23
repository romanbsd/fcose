# fcose

A framework-independent, pure Dart port of
[`cytoscape-fcose`](https://github.com/iVis-at-Bilkent/cytoscape.js-fcose)
2.2.0 and its required `cose-base` and `layout-base` foundations.

The package accepts a typed compound graph and returns deterministic node
centers and rectangles. It has no Cytoscape.js, browser, Flutter, FFI, or
JavaScript runtime dependency.

General fCoSE parity is still under development, so this prerelease is not yet
a universal drop-in replacement for every cytoscape-fcose option and graph
topology.

## Usage

```dart
import 'package:fcose/fcose.dart';

final graph = FcoseGraph(
  nodes: const [
    FcoseNode(id: 'cluster'),
    FcoseNode(id: 'api', width: 72, height: 48, parentId: 'cluster'),
    FcoseNode(id: 'database', width: 72, height: 48, parentId: 'cluster'),
    FcoseNode(id: 'client', width: 72, height: 48),
  ],
  edges: const [
    FcoseEdge(
      id: 'request',
      source: 'client',
      target: 'api',
      idealLength: 80,
    ),
    FcoseEdge(
      id: 'query',
      source: 'api',
      target: 'database',
      idealLength: 80,
    ),
  ],
);

final result = FcoseLayout(
  options: const FcoseOptions(
    quality: LayoutQuality.proof,
    seed: 7,
    idealEdgeLength: 80,
  ),
).run(graph);

final apiCenter = result.positionOf('api');
final clusterBounds = result.rectOf('cluster');
```

When `randomize` is false, every leaf node must provide an initial position.
Node widths and heights are measured layout dimensions. Edge ideal lengths are
boundary-to-boundary distances, matching CoSE rather than center-to-center
distances.

## Implemented foundations

- validated undirected compound graph model;
- sampled deterministic spectral initialization with root and nested-owner
  dummy connections for disconnected child components;
- rectangle-clipped CoSE springs and overlap separation;
- per-node repulsion, gravity, cooling, and convergence;
- same-owner leaf reduction, ten-tick staged regrowth, and post-growth
  convergence/cooling;
- live compound-node forces, nesting-aware edge lengths, and compound gravity;
- disconnected-component detection, original-center relocation,
  layout-utilities-compatible randomized polyomino packing, and incremental
  POSE packing;
- area-ordered zero-degree tiling with randomized sibling grouping and
  bottom-up nested-compound clearing/repopulation;
- bottom-up compound bounds with padding and label geometry;
- transformed and displacement-relaxed fixed, alignment, and DAG placement
  constraints;
- typed quality, greedy/random sampling, force, geometry, tiling, and
  constraint options;
- platform-stable seeded execution on the Dart VM and dart2js.

## Remaining parity work

The largest known differences from cytoscape-fcose 2.2.0 are:

- remaining general option semantics such as uniform leaf dimensions,
  configurable tiling comparison, tiling interactions with placement
  constraints, and debug steps.

Browser presentation concerns such as animation, viewport fitting, event
emission, and Cytoscape collection adaptation are intentionally outside this
renderer-independent layout engine.

## Upstream mapping

| Dart concern | Upstream source |
| --- | --- |
| geometry, graph validation, components | `layout-base` |
| spring embedding, cooling, compound bounds | `cose-base` |
| spectral start, constraints, public options | `cytoscape-fcose` 2.2.0 |

The public API expresses these algorithms with Dart value types and enums
instead of reproducing Cytoscape.js collection and callback conventions.

The upstream projects and this port are MIT licensed.
