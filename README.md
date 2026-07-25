# fcose

A framework-independent, pure Dart port of
[`cytoscape-fcose`](https://github.com/iVis-at-Bilkent/cytoscape.js-fcose)
2.2.0 and its required `cose-base` and `layout-base` foundations.

The package accepts a typed compound graph and returns deterministic node
centers and rectangles. It has no Cytoscape.js, browser, Flutter, FFI, or
JavaScript runtime dependency. The Dart implementation is optimized for better
performance, including compact packing data structures and reduced allocation
and copying in layout hot paths.

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

The scalar force defaults can be replaced with typed per-element resolvers:
`nodeRepulsionFor`, `idealEdgeLengthFor`, and `edgeElasticityFor`. Resolver
outputs are captured once per layout run. Explicit values on `FcoseNode` and
`FcoseEdge` take precedence.

## Implemented foundations

- validated undirected compound graph model;
- sampled deterministic spectral initialization with root and nested-owner
  dummy connections for disconnected child components;
- rectangle-clipped CoSE springs and overlap separation;
- per-node repulsion, CoSE-clamped grid neighborhoods, gravity, cooling, and
  convergence;
- same-owner leaf reduction, ten-tick staged regrowth, and post-growth
  convergence/cooling;
- live compound-node forces, nesting-aware edge lengths, and compound gravity;
- disconnected-component detection, original-center relocation,
  layout-utilities-compatible randomized polyomino packing, and incremental
  POSE packing;
- area-ordered or caller-sorted zero-degree tiling with randomized sibling
  grouping, ideal-row-width organization, and bottom-up nested-compound
  clearing/repopulation;
- run-scoped lazy horizontal and vertical tiling-padding resolvers across flat
  and nested tiling;
- optional uniform-leaf center-distance spring and repulsion calculations;
- bottom-up compound bounds with per-node Cytoscape-style padding, a typed
  layout fallback, and label geometry;
- transformed and displacement-relaxed fixed, alignment, and DAG placement
  constraints;
- cose-base-compatible cross-axis alignment dummy handling, including fixed
  groups and deeply nested compound layouts;
- axis-aware omitted relative-placement gaps derived from the average resolved
  ideal edge length and both endpoint half-sizes, including mixed-size nested
  compounds;
- typed per-element force resolvers, first-edge handling for parallel edges,
  and average resolved ideal length semantics for implicit constraint gaps;
- upstream constraint interactions that disable tiling and component packing;
- typed `all`, `transformed`, `enforced`, and `cose` constraint-pipeline
  stages, transformed-stage bounds recentering, and draft-quality bypass of
  the CoSE pipeline;
- typed quality, greedy/random sampling, force, geometry, tiling, and
  constraint options;
- platform-stable seeded execution on the Dart VM and dart2js.
- performance-oriented hot-path and packing implementations that reduce
  temporary allocations, redundant copying, and grid-storage overhead.

## Remaining parity work

The largest remaining parity work is:

- broader randomized differential coverage for uncommon topology, overlapping
  alignment, and fixed-node combinations.

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
