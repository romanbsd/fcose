## 0.1.0-dev.1

- Start an experimental pure Dart port of cytoscape-fcose.
- Add deterministic spectral initialization and CoSE-style force refinement.
- Add compound nodes, disconnected component packing, and placement constraints.
- Add CoSE leaf reduction, staged tree regrowth, sparse-side placement, and
  post-growth cooling.
- Connect disconnected root and nested compound child components through
  upstream-compatible spectral dummy nodes.
- Add CoSE-style randomized zero-degree grouping and bottom-up clearing and
  repopulation of fully tiled compound subtrees.
- Add layout-utilities-compatible randomized polyomino component packing,
  original-center relocation, and explicit typed packing controls.
- Add layout-utilities-compatible incremental POSE component packing for
  `randomize: false`.
- Add `uniformNodeDimensions` force semantics and custom `tilingCompareBy`
  ordering with upstream-compatible ideal-row-width tiling.
- Add typed constraint-pipeline debug stages and make draft quality bypass
  CoSE constraint preprocessing and zero-degree tiling.
- Recenter non-fixed transformed-stage results to their original graph bounds
  without perturbing full-layout coordinates.
- Add typed per-node and per-edge force resolvers, evaluated once per layout
  run with explicit element values taking precedence.
- Match upstream first-edge filtering before callback evaluation and use the
  average resolved ideal edge length for implicit relative-placement gaps.
- Match cose-base's cross-axis alignment dummy collision during constrained
  displacement relaxation and add a deeply nested compound differential case.
