// Layout microbench used for before/after optimization numbers.
// Usage: dart run tool/bench_layout.dart [label]

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fcose/fcose.dart';

void main(List<String> args) {
  final label = args.isEmpty ? 'run' : args.first;
  final common = _grid(800);
  final positioned = _withPositions(common);

  final commonOpts = const FcoseOptions(
    quality: LayoutQuality.proof,
    randomize: true,
    seed: 7,
    packComponents: false,
    tile: false,
  );
  final longOpts = const FcoseOptions(
    quality: LayoutQuality.proof,
    randomize: false,
    seed: 7,
    packComponents: false,
    tile: false,
    step: LayoutStep.cose,
  );

  for (var i = 0; i < 2; i++) {
    FcoseLayout(options: commonOpts).run(common);
  }
  final commonTimes = <int>[];
  FcoseResult? commonResult;
  for (var i = 0; i < 7; i++) {
    final watch = Stopwatch()..start();
    commonResult = FcoseLayout(options: commonOpts).run(common);
    commonTimes.add(watch.elapsedMilliseconds);
  }
  commonTimes.sort();

  FcoseLayout(options: longOpts).run(positioned);
  final longTimes = <int>[];
  FcoseResult? longResult;
  for (var i = 0; i < 3; i++) {
    final watch = Stopwatch()..start();
    longResult = FcoseLayout(options: longOpts).run(positioned);
    longTimes.add(watch.elapsedMilliseconds);
  }
  longTimes.sort();

  final commonDump = _dump(commonResult!);
  final longDump = _dump(longResult!);
  stdout.writeln(
    jsonEncode({
      'label': label,
      'common_n800_ms': {
        'median': commonTimes[commonTimes.length ~/ 2],
        'min': commonTimes.first,
        'max': commonTimes.last,
        'samples': commonTimes,
        'iterations': commonResult.iterations,
      },
      'long_cose_n800_ms': {
        'median': longTimes[longTimes.length ~/ 2],
        'min': longTimes.first,
        'max': longTimes.last,
        'samples': longTimes,
        'iterations': longResult.iterations,
      },
      'common_dump_sha1': _fnv(commonDump),
      'long_dump_sha1': _fnv(longDump),
    }),
  );

  if (args.contains('--dump')) {
    File('tool/bench_common.dump').writeAsStringSync(commonDump);
    File('tool/bench_long.dump').writeAsStringSync(longDump);
  }
}

String _dump(FcoseResult result) {
  final ids = result.positions.keys.toList()..sort();
  final buffer = StringBuffer();
  for (final id in ids) {
    final p = result.positions[id]!;
    buffer.writeln('$id ${p.x.toStringAsExponential(17)} ${p.y.toStringAsExponential(17)}');
  }
  return buffer.toString();
}

/// Stable 64-bit FNV-1a fingerprint for dump equality checks.
String _fnv(String text) {
  var hash = 0xcbf29ce484222325;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

FcoseGraph _grid(int nodeCount) {
  final side = math.sqrt(nodeCount).ceil();
  final nodes = [for (var i = 0; i < nodeCount; i++) FcoseNode(id: 'n$i', width: 40, height: 30)];
  final edges = <FcoseEdge>[];
  for (var i = 0; i < nodeCount; i++) {
    final x = i % side;
    final y = i ~/ side;
    if (x + 1 < side && i + 1 < nodeCount) {
      edges.add(FcoseEdge(id: 'e${i}_r', source: 'n$i', target: 'n${i + 1}', idealLength: 50));
    }
    final below = i + side;
    if (y + 1 < side && below < nodeCount) {
      edges.add(FcoseEdge(id: 'e${i}_d', source: 'n$i', target: 'n$below', idealLength: 50));
    }
  }
  return FcoseGraph(nodes: nodes, edges: edges);
}

FcoseGraph _withPositions(FcoseGraph graph) {
  final random = math.Random(1);
  return FcoseGraph(
    nodes: [
      for (final node in graph.nodes)
        FcoseNode(
          id: node.id,
          width: node.width,
          height: node.height,
          position: Offset(random.nextDouble() * 1000, random.nextDouble() * 1000),
        ),
    ],
    edges: graph.edges,
  );
}
