import 'dart:collection';
import 'dart:math' as math;

import 'geometry.dart';
import 'options.dart';
import 'random.dart';
import 'svd.dart';

final class SpectralResult {
  const SpectralResult(this.positions, this.samples);
  final Map<String, Offset> positions;
  final List<String> samples;
}

/// Greater than any distance in a connected graph this initializer accepts, so
/// the first BFS sweep always wins the running minimum.
const _unreachableDistance = 1 << 30;

/// Nonzero seed for the power iteration's ratio test; the first comparison
/// would otherwise divide by zero.
const _powerIterationSeed = 1e-9;

/// Caps the power iteration if its ratio test never settles inside the
/// configured tolerance.
const _powerIterationLimit = 1000;

/// Sampled pivot-distance spectral initializer used by fCoSE.
final class SpectralInitializer {
  SpectralInitializer({
    required this.sampleSize,
    required this.samplingType,
    required this.nodeSeparation,
    required this.random,
    this.tolerance = 1e-7,
  });

  final int sampleSize;
  final SamplingType samplingType;
  final double nodeSeparation;
  final double tolerance;

  /// Shared with the rest of the layout, because fCoSE draws its samples, its
  /// eigenvector guesses and its tree-growth choices from one `Math.random`
  /// stream, and a generator of its own here would shift every later draw.
  final Xorshift32 random;

  SpectralResult run(
    List<String> nodes,
    Map<String, Set<String>> adjacency, {
    Map<String, double> widths = const {},
    Map<String, Offset> initialPositions = const {},
    double idealEdgeLength = 50,
  }) {
    if (nodes.length <= 2) {
      if (nodes.isEmpty) return const SpectralResult({}, []);
      final first = nodes.first;
      final firstPosition = initialPositions[first] ?? Offset.zero;
      final positions = <String, Offset>{first: firstPosition};
      if (nodes case [_, final second]) {
        positions[second] = Offset(
          firstPosition.x + (widths[first] ?? 0) / 2 + (widths[second] ?? 0) / 2 + idealEdgeLength,
          firstPosition.y,
        );
      }
      return SpectralResult(positions, const []);
    }
    final count = math.min(sampleSize, nodes.length);
    final nodeSet = nodes.toSet();
    final samples = samplingType == SamplingType.greedy
        ? _greedySamples(nodes, nodeSet, adjacency, count)
        : _randomSamples(nodes, count);
    final c = List.generate(nodes.length, (_) => List<double>.filled(count, 0));
    for (var sampleIndex = 0; sampleIndex < samples.length; sampleIndex++) {
      final sample = samples[sampleIndex];
      final column = _distances(sample, nodeSet, adjacency);
      for (var nodeIndex = 0; nodeIndex < nodes.length; nodeIndex++) {
        c[nodeIndex][sampleIndex] = math.pow(column[nodes[nodeIndex]]! * nodeSeparation, 2).toDouble();
      }
    }
    final index = {for (var i = 0; i < nodes.length; i++) nodes[i]: i};
    final phi = List.generate(count, (row) => List.generate(count, (column) => c[index[samples[column]]!][row]));
    final inverse = _regularizedInverse(phi);
    final initialVectors = List.generate(
      nodes.length,
      (_) => (first: random.nextDouble(), second: random.nextDouble()),
    );
    final first = _powerVector(c, inverse, initial: [for (final values in initialVectors) values.first]);
    final second = _powerVector(
      c,
      inverse,
      initial: [for (final values in initialVectors) values.second],
      orthogonalTo: first.vector,
    );
    return SpectralResult({
      for (var i = 0; i < nodes.length; i++)
        nodes[i]: Offset(
          first.vector[i] * math.sqrt(first.value.abs()),
          second.vector[i] * math.sqrt(second.value.abs()),
        ),
    }, samples);
  }

  List<String> _randomSamples(List<String> nodes, int count) {
    final result = <String>[];
    final selected = <String>{};
    while (result.length < count) {
      final sample = nodes[random.nextInt(nodes.length)];
      if (selected.add(sample)) result.add(sample);
    }
    return result;
  }

  List<String> _greedySamples(List<String> nodes, Set<String> allowed, Map<String, Set<String>> adjacency, int count) {
    var current = nodes[random.nextInt(nodes.length)];
    final result = <String>[];
    final minimum = {for (final node in nodes) node: _unreachableDistance};
    while (result.length < count) {
      result.add(current);
      final distance = _distances(current, allowed, adjacency);
      for (final node in nodes) {
        minimum[node] = math.min(minimum[node]!, distance[node]!);
      }
      current = nodes.reduce((a, b) => minimum[a]! >= minimum[b]! ? a : b);
    }
    return result;
  }

  Map<String, int> _distances(String start, Set<String> allowed, Map<String, Set<String>> adjacency) {
    final result = <String, int>{start: 0};
    final queue = Queue<String>()..add(start);
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      for (final next in adjacency[current] ?? const {}) {
        if (allowed.contains(next) && !result.containsKey(next)) {
          result[next] = result[current]! + 1;
          queue.add(next);
        }
      }
    }
    return result;
  }

  ({List<double> vector, double value}) _powerVector(
    List<List<double>> c,
    List<List<double>> inverse, {
    required List<double> initial,
    List<double>? orthogonalTo,
  }) {
    var vector = _normalize(initial);
    var previous = _powerIterationSeed;
    var eigenvalue = 0.0;
    for (var iteration = 0; iteration < _powerIterationLimit; iteration++) {
      if (orthogonalTo != null) {
        final projection = _dot(orthogonalTo, vector);
        vector = List.generate(vector.length, (i) => vector[i] - orthogonalTo[i] * projection);
      }
      final next = _applyL(_center(vector), c, inverse);
      eigenvalue = _dot(vector, next);
      final normalized = _normalize(next);
      final current = _dot(vector, normalized);
      vector = normalized;
      final ratio = (current / previous).abs();
      if (ratio >= 1 && ratio <= 1 + tolerance) break;
      previous = current;
    }
    return (vector: vector, value: eigenvalue);
  }

  List<double> _applyL(List<double> vector, List<List<double>> c, List<List<double>> inverse) {
    final columns = c.first.length;
    final temp = List<double>.filled(columns, 0);
    for (var column = 0; column < columns; column++) {
      for (var row = 0; row < c.length; row++) {
        temp[column] += -0.5 * c[row][column] * vector[row];
      }
    }
    final projected = List<double>.filled(columns, 0);
    for (var row = 0; row < columns; row++) {
      for (var column = 0; column < columns; column++) {
        projected[row] += inverse[row][column] * temp[column];
      }
    }
    final result = List<double>.filled(c.length, 0);
    for (var row = 0; row < c.length; row++) {
      for (var column = 0; column < columns; column++) {
        result[row] += c[row][column] * projected[column];
      }
    }
    return _center(result);
  }

  /// The regularized pseudo-inverse of PHI that upstream fCoSE builds from its
  /// SVD: `V * diag(s / (s^2 + sMax^3 / s^2)) * U^T`. A zero singular value
  /// divides to infinity and so leaves a zero on the diagonal, which is how
  /// upstream handles a rank-deficient sample.
  List<List<double>> _regularizedInverse(List<List<double>> matrix) {
    final size = matrix.length;
    final decomposition = decompose(matrix);
    final values = decomposition.singularValues;
    final largestCubed = values.first * values.first * values.first;
    final sigma = [
      for (var row = 0; row < size; row++)
        [
          for (var column = 0; column < size; column++)
            if (row == column)
              values[row] / (values[row] * values[row] + largestCubed / (values[row] * values[row]))
            else
              0.0,
        ],
    ];
    return _multiply(_multiply(decomposition.v, sigma), _transpose(decomposition.u));
  }

  List<List<double>> _multiply(List<List<double>> first, List<List<double>> second) {
    final result = List.generate(first.length, (_) => List<double>.filled(second.first.length, 0));
    for (var row = 0; row < first.length; row++) {
      for (var column = 0; column < second.first.length; column++) {
        var sum = 0.0;
        for (var inner = 0; inner < first.first.length; inner++) {
          sum += first[row][inner] * second[inner][column];
        }
        result[row][column] = sum;
      }
    }
    return result;
  }

  List<List<double>> _transpose(List<List<double>> matrix) => [
    for (var row = 0; row < matrix.first.length; row++)
      [for (var column = 0; column < matrix.length; column++) matrix[column][row]],
  ];

  List<double> _center(List<double> values) {
    var sum = 0.0;
    for (final value in values) {
      sum += value;
    }
    sum *= -1 / values.length;
    return [for (final value in values) sum + value];
  }

  List<double> _normalize(List<double> values) {
    final magnitude = math.sqrt(_dot(values, values));
    return magnitude == 0 ? List.filled(values.length, 0) : [for (final value in values) value / magnitude];
  }

  double _dot(List<double> first, List<double> second) {
    var result = 0.0;
    for (var i = 0; i < first.length; i++) {
      result += first[i] * second[i];
    }
    return result;
  }
}
