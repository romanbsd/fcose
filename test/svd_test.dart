import 'package:fcose/src/svd.dart';
import 'package:test/test.dart';

/// Rebuilds `U * diag(s) * V^T` so a decomposition can be checked against the
/// matrix it came from.
List<List<double>> _reconstruct(SvdResult result) => [
  for (var row = 0; row < result.u.length; row++)
    [
      for (var column = 0; column < result.v.length; column++)
        [
          for (var rank = 0; rank < result.u.first.length; rank++)
            result.u[row][rank] * result.singularValues[rank] * result.v[column][rank],
        ].fold(0.0, (sum, term) => sum + term),
    ],
];

void main() {
  group('singular value decomposition', () {
    test('factors a matrix into its singular values and vectors', () {
      final matrix = [
        [4.0, 0.0],
        [3.0, -5.0],
      ];
      final result = decompose([
        for (final row in matrix) [...row],
      ]);

      // A^T A is [[25, -15], [-15, 25]], whose eigenvalues 40 and 10 make the
      // singular values sqrt(40) and sqrt(10).
      expect(result.singularValues[0], closeTo(6.324555320336759, 1e-12));
      expect(result.singularValues[1], closeTo(3.1622776601683795, 1e-12));
      for (var row = 0; row < matrix.length; row++) {
        for (var column = 0; column < matrix.length; column++) {
          expect(_reconstruct(result)[row][column], closeTo(matrix[row][column], 1e-12));
        }
      }
    });

    test('orders singular values from largest to smallest', () {
      final result = decompose([
        [1.0, 2.0, 3.0],
        [4.0, 5.0, 6.0],
        [7.0, 8.0, 10.0],
      ]);
      expect(result.singularValues[0], greaterThan(result.singularValues[1]));
      expect(result.singularValues[1], greaterThan(result.singularValues[2]));
      expect(result.singularValues.last, greaterThan(0));
    });

    test('reports a rank-deficient matrix with a zero singular value', () {
      final result = decompose([
        [1.0, 2.0],
        [2.0, 4.0],
      ]);
      expect(result.singularValues[1], closeTo(0, 1e-12));
    });
  });
}
