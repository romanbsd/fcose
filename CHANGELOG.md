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
- Match cose-base's dimension-aware defaults for omitted relative-placement
  gaps and cover mixed-size flat and nested compound differentials.
- Add typed zero-argument tiling-padding resolvers with run-scoped upstream
  semantics across flat and nested tiling.
- Add per-node compound padding across bounds, nested tiling, force geometry,
  and component packing while retaining the layout-wide fallback.
- Match CoSE's ten-pixel internal ideal-length floor when calculating sparse
  repulsion-grid neighborhoods without changing configured spring lengths.
- Measure draft-quality recentering on leaf bounds, as upstream does when it
  never builds the cose-base graph.
- Draw spectral samples and eigenvector guesses from the layout's own random
  stream, matching upstream's single sequence of `Math.random` calls.
- Replace the spectral pseudo-inverse with a transcription of the JAMA
  singular value decomposition that layout-base uses, so compound spectral
  layouts now match upstream to about 1e-13.
- Untile before relocating and packing, so a tiled layout now returns each
  component to its original center and takes part in component packing instead
  of keeping the coordinates the spring embedder left it with.
- Treat the components without an edge as the single tiled pseudo-component
  upstream packs, appended after the components that kept their edges.
- Run one spectral pass and one spring embedder per connected component when
  packing is enabled, in upstream's order, so a component is no longer embedded
  alongside the components it is only packed beside.
- Keep each leaf's top-left corner authoritative through the spring embedder,
  as `LNode` does, and derive its center from that corner. Accumulating
  displacements on a center instead lost the low bits of every tick, which
  `calcRepulsionForce`'s minimum-distance sign snap turned into whole pixels
  on symmetric graphs; every oracle fixture now matches upstream to about
  1e-13.
