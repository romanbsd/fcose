// Runs the upstream cytoscape-fcose layout on a spec file and prints the
// resulting positions, so the Dart port can be diffed against the original:
//
//   node oracle.js specs/overlap-separation.json
//
// A spec is JSON with `nodes` (id, w, h, x, y, parent, padding), `edges`
// (id, source, target), `options` (handed straight to cy.layout) and the two
// knobs below that upstream exposes only through internals:
//
//   `seed`             replaces Math.random with the port's xorshift32, so
//                      randomize/draft runs are reproducible on both sides.
//   `finalTemperature` overrides the cooling floor cose-base hardcodes.
//
// cytoscape-layout-utilities reads `window` at require time, and packing stays
// off unless it loads, so the global has to exist before anything is required.
global.window = global;

const fs = require('fs');
const spec = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

// Mirrors lib/src/random.dart: every step is truncated to 32 bits the way
// JavaScript bitwise operators already truncate their operands.
let randomDraws = 0;
if (spec.seed !== undefined) {
  let state = spec.seed >>> 0;
  Math.random = () => {
    state = (state ^ (state << 13)) >>> 0;
    state = (state ^ (state >>> 17)) >>> 0;
    state = (state ^ (state << 5)) >>> 0;
    randomDraws++;
    return state / 0x100000000;
  };
}

// cose-base assigns finalTemperature inside initSpringEmbedder and no option
// reaches it, so the only way to shorten a cooling schedule is to reassign it
// once the original has run.
if (spec.finalTemperature !== undefined) {
  const proto = require('cose-base').CoSELayout.prototype;
  const initSpringEmbedder = proto.initSpringEmbedder;
  proto.initSpringEmbedder = function () {
    initSpringEmbedder.call(this);
    this.finalTemperature = spec.finalTemperature;
  };
}

const cytoscape = require('cytoscape');
cytoscape.use(require('cytoscape-fcose'));
cytoscape.use(require('cytoscape-layout-utilities'));

// Sizes and padding only reach the layout through the stylesheet, and the
// default padding of a cytoscape node is not zero.
const style = [{ selector: 'node', style: { padding: 0 } }];
for (const node of spec.nodes) {
  if (node.w !== undefined) style.push({ selector: '#' + node.id, style: { width: node.w, height: node.h } });
  if (node.padding !== undefined) style.push({ selector: '#' + node.id, style: { padding: node.padding } });
}

const cy = cytoscape({
  headless: true,
  styleEnabled: true,
  style,
  elements: {
    nodes: spec.nodes.map((node) => ({ data: { id: node.id, parent: node.parent } })),
    edges: (spec.edges || []).map((edge) => ({ data: { id: edge.id, source: edge.source, target: edge.target } })),
  },
});

// Positions given in the element definitions are ignored by the constructor.
for (const node of spec.nodes) {
  if (node.x !== undefined) cy.getElementById(node.id).position({ x: node.x, y: node.y });
}

// Upstream reads the per-element force options as callbacks, so plain numbers
// and per-id maps in a spec have to be wrapped before the layout sees them.
const options = Object.assign({ name: 'fcose', animate: false, fit: false }, spec.options);
for (const key of ['nodeRepulsion', 'idealEdgeLength', 'edgeElasticity']) {
  const value = options[key];
  if (typeof value === 'number') options[key] = () => value;
  else if (value && typeof value === 'object') options[key] = (element) => value[element.id()];
}

cy.layout(options).run();

const positions = {};
cy.nodes().forEach((node) => {
  positions[node.id()] = [node.position().x, node.position().y];
});
console.log(JSON.stringify(positions, null, 1));
if (spec.seed !== undefined) console.error(`random draws: ${randomDraws}`);

// Headless cytoscape keeps the event loop alive.
process.exit(0);
