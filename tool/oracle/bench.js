// Wall-time bench for upstream cytoscape-fcose 2.2.0, matched to
// tool/bench_layout.dart's n=800 fixtures (common randomize + long cose).
//
//   node tool/oracle/bench.js

global.window = global;

const cytoscape = require('cytoscape');
cytoscape.use(require('cytoscape-fcose'));
cytoscape.use(require('cytoscape-layout-utilities'));

function grid(nodeCount) {
  const side = Math.ceil(Math.sqrt(nodeCount));
  const nodes = [];
  const edges = [];
  for (let i = 0; i < nodeCount; i++) {
    nodes.push({ id: `n${i}`, w: 40, h: 30 });
    const x = i % side;
    const y = Math.floor(i / side);
    if (x + 1 < side && i + 1 < nodeCount) {
      edges.push({ id: `e${i}_r`, source: `n${i}`, target: `n${i + 1}` });
    }
    const below = i + side;
    if (y + 1 < side && below < nodeCount) {
      edges.push({ id: `e${i}_d`, source: `n${i}`, target: `n${below}` });
    }
  }
  return { nodes, edges };
}

// Same seed stream as lib/src/random.dart / oracle.js.
function installXorshift(seed) {
  let state = seed >>> 0;
  Math.random = () => {
    state = (state ^ (state << 13)) >>> 0;
    state = (state ^ (state >>> 17)) >>> 0;
    state = (state ^ (state << 5)) >>> 0;
    return state / 0x100000000;
  };
}

function withPositions(graph) {
  // Approximate Dart math.Random(1) start coords; exact match is not required
  // for wall-time comparison because both sides run the full iteration budget.
  const random = (() => {
    let s = 1 >>> 0;
    return () => {
      s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
      return s / 0x100000000;
    };
  })();
  return {
    nodes: graph.nodes.map((node) => ({
      ...node,
      x: random() * 1000,
      y: random() * 1000,
    })),
    edges: graph.edges,
  };
}

function runLayout(graph, options, seed) {
  installXorshift(seed);
  const style = [{ selector: 'node', style: { padding: 0 } }];
  for (const node of graph.nodes) {
    style.push({ selector: `#${node.id}`, style: { width: node.w, height: node.h } });
  }
  const cy = cytoscape({
    headless: true,
    styleEnabled: true,
    style,
    elements: {
      nodes: graph.nodes.map((node) => ({ data: { id: node.id } })),
      edges: graph.edges.map((edge) => ({
        data: { id: edge.id, source: edge.source, target: edge.target },
      })),
    },
  });
  for (const node of graph.nodes) {
    if (node.x !== undefined) cy.getElementById(node.id).position({ x: node.x, y: node.y });
  }
  const layoutOptions = Object.assign(
    {
      name: 'fcose',
      animate: false,
      fit: false,
      idealEdgeLength: () => 50,
      edgeElasticity: () => 0.45,
      nodeRepulsion: () => 4500,
    },
    options,
  );
  const start = process.hrtime.bigint();
  cy.layout(layoutOptions).run();
  const elapsedMs = Number(process.hrtime.bigint() - start) / 1e6;
  cy.destroy();
  return elapsedMs;
}

function median(samples) {
  const sorted = [...samples].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

function bench(label, graph, options, seed, runs, warmups) {
  for (let i = 0; i < warmups; i++) runLayout(graph, options, seed);
  const samples = [];
  for (let i = 0; i < runs; i++) samples.push(runLayout(graph, options, seed));
  const med = median(samples);
  return {
    label,
    median: Math.round(med),
    min: Math.round(Math.min(...samples)),
    max: Math.round(Math.max(...samples)),
    samples: samples.map((s) => Math.round(s)),
  };
}

const commonGraph = grid(800);
const longGraph = withPositions(commonGraph);

const common = bench(
  'common_n800',
  commonGraph,
  {
    quality: 'proof',
    randomize: true,
    packComponents: false,
    tile: false,
  },
  7,
  7,
  2,
);

const long = bench(
  'long_cose_n800',
  longGraph,
  {
    quality: 'proof',
    randomize: false,
    packComponents: false,
    tile: false,
    step: 'cose',
  },
  7,
  3,
  1,
);

console.log(
  JSON.stringify(
    {
      runtime: 'node ' + process.version,
      engine: 'cytoscape-fcose@2.2.0',
      common_n800_ms: common,
      long_cose_n800_ms: long,
    },
    null,
    2,
  ),
);
process.exit(0);
