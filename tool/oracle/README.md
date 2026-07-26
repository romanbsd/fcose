# Upstream oracle

Runs the original cytoscape-fcose 2.2.0 layout on a fixture and diffs it
against this port, so a parity claim can be a number instead of an argument.

```sh
cd tool/oracle && npm install          # once
dart run tool/parity.dart tool/oracle/specs/*.json --tolerance 0.5
node tool/oracle/oracle.js tool/oracle/specs/overlap-separation.json
```

`parity.dart` runs both sides on the same spec and prints the worst
coordinate difference per fixture, exiting non-zero when a node moves further
than the tolerance. Every option a spec uses has to be translated in
`parity.dart`; an untranslated key fails the run, because an option that
reached only one of the two implementations would make the comparison
meaningless.

Only leaves are compared. Upstream hands `layoutPositions` the nodes that do
not match `:parent`, so a compound never receives a layout coordinate at all:
the one the oracle reports is what Cytoscape's compound-bounds rule derives
from the children, after padding every box by a pixel for antialiasing and
another for the default parent border. That is a rendering convention of the
host, not a result of fCoSE.

## Specs

A spec is JSON: `nodes` (`id`, `w`, `h`, `x`, `y`, `parent`, `padding`),
`edges` (`id`, `source`, `target`), `options` handed straight to `cy.layout`,
plus two knobs upstream exposes only through internals:

- `seed` replaces `Math.random` with the xorshift32 of `lib/src/random.dart`,
  which is what makes randomized and draft runs comparable at all.
- `finalTemperature` overrides the cooling floor cose-base hardcodes, so a
  spec can converge in a handful of iterations.

The specs here reproduce the graphs of the pinned expectations in
`test/fcose_test.dart`. Every fixture agrees to about 1e-13.

`symmetric-triangle` and `packed-symmetric-triangle` are not pinned in the
test suite; they exist because a symmetric graph is the sharpest parity probe
there is. `calcRepulsionForce` snaps any component below
`MIN_REPULSION_DIST` to `sign(delta) * MIN_REPULSION_DIST`, so on a graph
whose two halves are exact mirrors, a single-ulp difference in one coordinate
decides a sign and becomes a twelve-pixel kick within a few ticks. The packed
variant then feeds that triangle's hull to POSE, where a mirrored hull moves
the isolated component to the opposite side, and the fixture fails by a
hundred pixels. Both are the same one-ulp question asked at two amplitudes.

## Known divergences

`draft-disconnected.json` is a fixture where upstream is the one that is
wrong. Its default `idealEdgeLength` is a function, and the two-node shortcut
of `spectral.js` adds that option to a coordinate without calling it, so every
component of exactly two nodes comes back with a concatenated string and a
`NaN`. This port computes the same placement numerically, so the fixture is
kept as a reproducer rather than as an expectation; `parity.dart` reports it
as skipped instead of comparing coordinates against a `NaN`.
