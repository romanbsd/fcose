import 'dart:collection';
import 'dart:math' as math;

import 'geometry.dart';
import 'options.dart';

final class SpectralResult {
  const SpectralResult(this.positions, this.samples);
  final Map<String, Offset> positions;
  final List<String> samples;
}

/// Sampled pivot-distance spectral initializer used by fCoSE.
final class SpectralInitializer {
  SpectralInitializer({
    required this.sampleSize,
    required this.samplingType,
    required this.nodeSeparation,
    required this.seed,
    this.tolerance = 1e-7,
  }) : _random = _SpectralRandom(seed);

  final int sampleSize;
  final SamplingType samplingType;
  final double nodeSeparation;
  final int seed;
  final double tolerance;
  final _SpectralRandom _random;

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
    final samples = samplingType == SamplingType.greedy
        ? _greedySamples(nodes, adjacency, count)
        : _randomSamples(nodes, count);
    final distances = <List<double>>[];
    for (final sample in samples) {
      final column = _distances(sample, nodes, adjacency);
      distances.add([for (final node in nodes) math.pow(column[node]! * nodeSeparation, 2).toDouble()]);
    }
    final c = List.generate(nodes.length, (row) => List.generate(count, (column) => distances[column][row]));
    final index = {for (var i = 0; i < nodes.length; i++) nodes[i]: i};
    final phi = List.generate(count, (row) => List.generate(count, (column) => c[index[samples[column]]!][row]));
    final inverse = _regularizedInverse(phi);
    final initialVectors = List.generate(
      nodes.length,
      (_) => (first: _random.nextDouble(), second: _random.nextDouble()),
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
    while (result.length < count) {
      final sample = nodes[_random.nextInt(nodes.length)];
      if (!result.contains(sample)) result.add(sample);
    }
    return result;
  }

  List<String> _greedySamples(List<String> nodes, Map<String, Set<String>> adjacency, int count) {
    var current = nodes[_random.nextInt(nodes.length)];
    final result = <String>[];
    final minimum = {for (final node in nodes) node: 1 << 30};
    while (result.length < count) {
      result.add(current);
      final distance = _distances(current, nodes, adjacency);
      for (final node in nodes) {
        minimum[node] = math.min(minimum[node]!, distance[node]!);
      }
      current = nodes.reduce((a, b) => minimum[a]! >= minimum[b]! ? a : b);
    }
    return result;
  }

  Map<String, int> _distances(String start, List<String> nodes, Map<String, Set<String>> adjacency) {
    final allowed = nodes.toSet();
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
    var previous = 1e-9;
    var eigenvalue = 0.0;
    for (var iteration = 0; iteration < 1000; iteration++) {
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
    final projected = List<double>.generate(
      columns,
      (row) =>
          List.generate(columns, (column) => inverse[row][column] * temp[column]).fold(0, (sum, value) => sum + value),
    );
    return _center(
      List.generate(
        c.length,
        (row) =>
            List.generate(columns, (column) => c[row][column] * projected[column]).fold(0, (sum, value) => sum + value),
      ),
    );
  }

  List<List<double>> _regularizedInverse(List<List<double>> matrix) {
    final size = matrix.length;
    final transposeProduct = List.generate(size, (_) => List<double>.filled(size, 0));
    for (var row = 0; row < size; row++) {
      for (var column = row; column < size; column++) {
        var value = 0.0;
        for (var inner = 0; inner < size; inner++) {
          value += matrix[inner][row] * matrix[inner][column];
        }
        transposeProduct[row][column] = value;
        transposeProduct[column][row] = value;
      }
    }

    final decomposition = _symmetricEigenDecomposition(transposeProduct);
    final order = List.generate(size, (index) => index)
      ..sort((first, second) => decomposition.values[second].compareTo(decomposition.values[first]));
    final singularValues = [for (final index in order) math.sqrt(math.max(0, decomposition.values[index]))];
    final largestCubed = math.pow(singularValues.first, 3).toDouble();
    final inverse = List.generate(size, (_) => List<double>.filled(size, 0));

    // This is the regularization used by upstream fCoSE after SVD(PHI):
    // V * diag(s / (s^2 + sMax^3 / s^2)) * U^T.
    for (var rank = 0; rank < size; rank++) {
      final singular = singularValues[rank];
      if (singular <= _singularValueTolerance) continue;
      final sourceColumn = order[rank];
      final right = [for (var row = 0; row < size; row++) decomposition.vectors[row][sourceColumn]];
      final left = List<double>.filled(size, 0);
      for (var row = 0; row < size; row++) {
        for (var column = 0; column < size; column++) {
          left[row] += matrix[row][column] * right[column] / singular;
        }
      }
      final coefficient = singular / (singular * singular + largestCubed / (singular * singular));
      for (var row = 0; row < size; row++) {
        for (var column = 0; column < size; column++) {
          inverse[row][column] += coefficient * right[row] * left[column];
        }
      }
    }
    return inverse;
  }

  ({List<double> values, List<List<double>> vectors}) _symmetricEigenDecomposition(List<List<double>> input) {
    final size = input.length;
    final values = [for (final row in input) List<double>.of(row)];
    final vectors = List.generate(size, (row) => List.generate(size, (column) => row == column ? 1.0 : 0.0));
    final maximumSweeps = math.max(_minimumJacobiSweeps, size * size * _jacobiSweepsPerEntry);
    for (var sweep = 0; sweep < maximumSweeps; sweep++) {
      var pivotRow = 0;
      var pivotColumn = 1;
      var maximum = 0.0;
      for (var row = 0; row < size; row++) {
        for (var column = row + 1; column < size; column++) {
          if (values[row][column].abs() > maximum) {
            maximum = values[row][column].abs();
            pivotRow = row;
            pivotColumn = column;
          }
        }
      }
      if (maximum <= _jacobiTolerance) break;

      final diagonalDifference = values[pivotColumn][pivotColumn] - values[pivotRow][pivotRow];
      final angle = 0.5 * math.atan2(2 * values[pivotRow][pivotColumn], diagonalDifference);
      final cosine = math.cos(angle);
      final sine = math.sin(angle);
      for (var index = 0; index < size; index++) {
        final rowValue = values[pivotRow][index];
        final columnValue = values[pivotColumn][index];
        values[pivotRow][index] = cosine * rowValue - sine * columnValue;
        values[pivotColumn][index] = sine * rowValue + cosine * columnValue;
      }
      for (var index = 0; index < size; index++) {
        final rowValue = values[index][pivotRow];
        final columnValue = values[index][pivotColumn];
        values[index][pivotRow] = cosine * rowValue - sine * columnValue;
        values[index][pivotColumn] = sine * rowValue + cosine * columnValue;
        final vectorRow = vectors[index][pivotRow];
        final vectorColumn = vectors[index][pivotColumn];
        vectors[index][pivotRow] = cosine * vectorRow - sine * vectorColumn;
        vectors[index][pivotColumn] = sine * vectorRow + cosine * vectorColumn;
      }
    }
    return (values: [for (var i = 0; i < size; i++) values[i][i]], vectors: vectors);
  }

  List<double> _center(List<double> values) {
    final average = values.fold(0.0, (sum, value) => sum + value) / values.length;
    return [for (final value in values) value - average];
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

const _singularValueTolerance = 1e-12;
const _jacobiTolerance = 1e-12;
const _minimumJacobiSweeps = 32;
const _jacobiSweepsPerEntry = 8;

final class _SpectralRandom {
  _SpectralRandom(int seed) : _state = seed & 0xffffffff;
  int _state;
  int _next() {
    var value = _state;
    value = (value ^ (value << 13)) & 0xffffffff;
    value = (value ^ (value >>> 17)) & 0xffffffff;
    value = (value ^ (value << 5)) & 0xffffffff;
    return _state = value & 0xffffffff;
  }

  double nextDouble() => _next() / 0x100000000;
  int nextInt(int maximum) => (nextDouble() * maximum).floor();
}
