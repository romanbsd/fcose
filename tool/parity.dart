// Diffs this port against upstream cytoscape-fcose for one spec file:
//
//   dart run tool/parity.dart tool/oracle/specs/overlap-separation.json
//   dart run tool/parity.dart tool/oracle/specs/*.json --tolerance 1e-6
//
// The spec format is described in tool/oracle/oracle.js, which produces the
// upstream side of the comparison. Every option key a spec uses has to be
// translated below; an unknown key fails the run rather than being dropped,
// because a silently ignored option would turn the comparison into a lie.
import 'dart:convert';
import 'dart:io';

import 'package:fcose/fcose.dart';

/// Largest accepted difference, in logical pixels, before a node is reported
/// as a mismatch. Short runs agree with upstream to about this much.
const _defaultTolerance = 1e-9;

void main(List<String> arguments) {
  final toleranceIndex = arguments.indexOf('--tolerance');
  final tolerance = toleranceIndex == -1 ? _defaultTolerance : double.parse(arguments[toleranceIndex + 1]);
  final specPaths = [
    for (final (index, argument) in arguments.indexed)
      if (toleranceIndex == -1 || (index != toleranceIndex && index != toleranceIndex + 1)) argument,
  ];
  if (specPaths.isEmpty) {
    stderr.writeln('usage: dart run tool/parity.dart <spec.json>... [--tolerance <pixels>]');
    exit(64);
  }

  var failed = false;
  for (final specPath in specPaths) {
    final spec = jsonDecode(File(specPath).readAsStringSync()) as Map<String, Object?>;
    final port = _runPort(spec);
    try {
      failed |= !_report(specPath, port, _runOracle(specPath), tolerance);
    } on _UpstreamNotNumeric catch (error) {
      // A spec kept around to document an upstream defect cannot be compared,
      // so it is reported and skipped rather than counted as a mismatch.
      stdout.writeln('skip ${_name(specPath)}  $error');
    }
  }
  exit(failed ? 1 : 0);
}

Map<String, Offset> _runPort(Map<String, Object?> spec) {
  final specNodes = (spec['nodes']! as List).cast<Map<String, Object?>>();
  final specEdges = (spec['edges'] as List? ?? const []).cast<Map<String, Object?>>();
  final graph = FcoseGraph(
    nodes: [
      for (final node in specNodes)
        FcoseNode(
          id: node['id']! as String,
          width: _number(node['w']) ?? 30,
          height: _number(node['h']) ?? 30,
          parentId: node['parent'] as String?,
          position: node['x'] == null ? null : Offset(_number(node['x'])!, _number(node['y'])!),
          padding: _number(node['padding']),
        ),
    ],
    edges: [
      for (final edge in specEdges)
        FcoseEdge(id: edge['id']! as String, source: edge['source']! as String, target: edge['target']! as String),
    ],
  );
  final result = FcoseLayout(options: _options(spec, graph)).run(graph);
  // Only leaves are comparable: upstream hands `layoutPositions` the nodes
  // matching `:parent` negated, so a compound's coordinate is whatever
  // Cytoscape's compound-bounds rule derives from its children, which pads
  // every box by a pixel for antialiasing and another for the default parent
  // border. That is a rendering convention, not a layout result.
  final parents = {for (final node in specNodes) node['parent'] as String?};
  return {
    for (final node in specNodes)
      if (!parents.contains(node['id'])) node['id']! as String: result.positionOf(node['id']! as String),
  };
}

FcoseOptions _options(Map<String, Object?> spec, FcoseGraph graph) {
  final options = Map<String, Object?>.from(spec['options'] as Map? ?? const {});
  final unknown = options.keys.toSet().difference(_translatedOptionKeys);
  if (unknown.isNotEmpty) throw UnsupportedError('spec uses untranslated options: ${unknown.join(', ')}');
  // Upstream reads nodeRepulsion as a callback, so a spec may give either one
  // value for every node or a value per node id.
  final nodeRepulsion = options['nodeRepulsion'];
  final perNodeRepulsion = nodeRepulsion is Map ? nodeRepulsion : null;
  return FcoseOptions(
    quality: switch (options['quality']) {
      null || 'default' => LayoutQuality.defaultQuality,
      'draft' => LayoutQuality.draft,
      'proof' => LayoutQuality.proof,
      final value => throw UnsupportedError('unknown quality: $value'),
    },
    step: switch (options['step']) {
      null || 'all' => LayoutStep.all,
      'transformed' => LayoutStep.transformed,
      'enforced' => LayoutStep.enforced,
      'cose' => LayoutStep.cose,
      final value => throw UnsupportedError('unknown step: $value'),
    },
    samplingType: switch (options['samplingType']) {
      null || true => SamplingType.greedy,
      false => SamplingType.random,
      final value => throw UnsupportedError('unknown samplingType: $value'),
    },
    randomize: options['randomize'] as bool? ?? true,
    seed: _integer(spec['seed']) ?? const FcoseOptions().seed,
    maxIterations: _integer(options['numIter']) ?? const FcoseOptions().maxIterations,
    sampleSize: _integer(options['sampleSize']) ?? const FcoseOptions().sampleSize,
    nodeSeparation: _number(options['nodeSeparation']) ?? const FcoseOptions().nodeSeparation,
    idealEdgeLength: _number(options['idealEdgeLength']) ?? const FcoseOptions().idealEdgeLength,
    edgeElasticity: _number(options['edgeElasticity']) ?? const FcoseOptions().edgeElasticity,
    nodeRepulsion: (perNodeRepulsion == null ? _number(nodeRepulsion) : null) ?? const FcoseOptions().nodeRepulsion,
    nodeRepulsionFor: perNodeRepulsion == null
        ? null
        : (node) => _number(perNodeRepulsion[node.id]) ?? const FcoseOptions().nodeRepulsion,
    gravity: _number(options['gravity']) ?? const FcoseOptions().gravity,
    gravityRange: _number(options['gravityRange']) ?? const FcoseOptions().gravityRange,
    compoundGravity: _number(options['gravityCompound']) ?? const FcoseOptions().compoundGravity,
    compoundGravityRange: _number(options['gravityRangeCompound']) ?? const FcoseOptions().compoundGravityRange,
    nestingFactor: _number(options['nestingFactor']) ?? const FcoseOptions().nestingFactor,
    // The oracle's stylesheet sets `padding: 0` on every node, which overrides
    // the 10 that Cytoscape's default `:parent` rule would otherwise apply.
    compoundPadding: 0,
    uniformNodeDimensions: options['uniformNodeDimensions'] as bool? ?? const FcoseOptions().uniformNodeDimensions,
    packComponents: options['packComponents'] as bool? ?? const FcoseOptions().packComponents,
    tile: options['tile'] as bool? ?? const FcoseOptions().tile,
    tilingPaddingVertical: _number(options['tilingPaddingVertical']) ?? const FcoseOptions().tilingPaddingVertical,
    tilingPaddingHorizontal:
        _number(options['tilingPaddingHorizontal']) ?? const FcoseOptions().tilingPaddingHorizontal,
    initialEnergyOnIncremental:
        _number(options['initialEnergyOnIncremental']) ?? const FcoseOptions().initialEnergyOnIncremental,
    // cose-base names this the final temperature of its cooling schedule.
    minTemperature: _number(spec['finalTemperature']) ?? const FcoseOptions().minTemperature,
    fixedNodes: [
      for (final constraint in options['fixedNodeConstraint'] as List? ?? const [])
        FixedNodeConstraint(
          (constraint as Map)['nodeId']! as String,
          Offset(_number((constraint['position'] as Map)['x'])!, _number((constraint['position'] as Map)['y'])!),
        ),
    ],
    alignment: switch (options['alignmentConstraint'] as Map?) {
      null => const AlignmentConstraint(),
      final alignment => AlignmentConstraint(
        vertical: [for (final group in alignment['vertical'] as List? ?? const []) (group as List).cast<String>()],
        horizontal: [for (final group in alignment['horizontal'] as List? ?? const []) (group as List).cast<String>()],
      ),
    },
    relativePlacements: [
      for (final constraint in (options['relativePlacementConstraint'] as List? ?? const []).cast<Map>())
        if (constraint['left'] != null)
          RelativePlacementConstraint.horizontal(
            constraint['left']! as String,
            constraint['right']! as String,
            gap: _number(constraint['gap']),
          )
        else
          RelativePlacementConstraint.vertical(
            constraint['top']! as String,
            constraint['bottom']! as String,
            gap: _number(constraint['gap']),
          ),
    ],
  );
}

const _translatedOptionKeys = {
  'quality',
  'step',
  'samplingType',
  'randomize',
  'numIter',
  'sampleSize',
  'nodeSeparation',
  'idealEdgeLength',
  'edgeElasticity',
  'nodeRepulsion',
  'gravity',
  'gravityRange',
  'gravityCompound',
  'gravityRangeCompound',
  'nestingFactor',
  'uniformNodeDimensions',
  'packComponents',
  'tile',
  'tilingPaddingVertical',
  'tilingPaddingHorizontal',
  'initialEnergyOnIncremental',
  'fixedNodeConstraint',
  'alignmentConstraint',
  'relativePlacementConstraint',
};

Map<String, Offset> _runOracle(String specPath) {
  final oracle = Platform.script.resolve('oracle/oracle.js').toFilePath();
  final process = Process.runSync('node', [oracle, specPath]);
  if (process.exitCode != 0) throw StateError('oracle failed for $specPath:\n${process.stderr}');
  final positions = jsonDecode(process.stdout as String) as Map<String, Object?>;
  return {
    for (final entry in positions.entries)
      // Upstream can finish with a coordinate that is not a number at all; see
      // the note on specs/draft-disconnected.json in tool/oracle/README.md.
      entry.key: switch (entry.value) {
        [final num x, final num y] => Offset(x.toDouble(), y.toDouble()),
        final value => throw _UpstreamNotNumeric('upstream placed ${entry.key} at $value'),
      },
  };
}

bool _report(String specPath, Map<String, Offset> port, Map<String, Offset> upstream, double tolerance) {
  var worst = 0.0;
  final mismatches = <String>[];
  for (final id in port.keys) {
    final expected = upstream[id];
    if (expected == null) {
      mismatches.add('  $id missing from the upstream result');
      continue;
    }
    final deltaX = (port[id]!.x - expected.x).abs();
    final deltaY = (port[id]!.y - expected.y).abs();
    worst = [worst, deltaX, deltaY].reduce((a, b) => a > b ? a : b);
    if (deltaX > tolerance || deltaY > tolerance) {
      mismatches.add('  $id port ${port[id]!.x}, ${port[id]!.y}  upstream ${expected.x}, ${expected.y}');
    }
  }
  stdout.writeln('${mismatches.isEmpty ? 'ok  ' : 'FAIL'} ${_name(specPath)}  worst delta $worst');
  mismatches.forEach(stdout.writeln);
  return mismatches.isEmpty;
}

String _name(String specPath) => specPath.split(Platform.pathSeparator).last;

/// Upstream finished with a coordinate that is not a number; see the note on
/// specs/draft-disconnected.json in tool/oracle/README.md.
final class _UpstreamNotNumeric implements Exception {
  _UpstreamNotNumeric(this.message);
  final String message;
  @override
  String toString() => message;
}

double? _number(Object? value) => (value as num?)?.toDouble();

int? _integer(Object? value) => (value as num?)?.toInt();
