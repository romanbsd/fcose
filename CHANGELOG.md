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
