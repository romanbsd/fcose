import 'dart:math' as math;

/// Singular value decomposition `A = U * diag(s) * V^T`.
final class SvdResult {
  const SvdResult({required this.u, required this.v, required this.singularValues});

  /// Left singular vectors, `m` rows by `min(m, n)` columns.
  final List<List<double>> u;

  /// Right singular vectors, `n` rows by `n` columns.
  final List<List<double>> v;

  /// Singular values in descending order, `min(m + 1, n)` of them.
  final List<double> singularValues;
}

/// Golub-Reinsch singular value decomposition.
///
/// This is a transcription of the JAMA implementation that layout-base ships as
/// `SVD.js`, kept operation for operation so that the spectral initializer
/// rounds exactly the way upstream fCoSE does. The power iteration downstream
/// decides convergence on a ratio that sits right at 1, so a last-bit
/// difference here changes the number of iterations and with it the sign of an
/// eigenvector.
///
/// Like JAMA, this overwrites [a] with working values.
SvdResult decompose(List<List<double>> a) {
  final m = a.length;
  final n = a[0].length;
  final nu = math.min(m, n);
  final s = List<double>.filled(math.min(m + 1, n), 0);
  final u = List.generate(m, (_) => List<double>.filled(nu, 0));
  final v = List.generate(n, (_) => List<double>.filled(n, 0));
  final e = List<double>.filled(n, 0);
  final work = List<double>.filled(m, 0);

  // Reduce A to bidiagonal form, storing the diagonal in s and the
  // superdiagonal in e.
  final nct = math.min(m - 1, n);
  final nrt = math.max(0, math.min(n - 2, m));
  for (var k = 0; k < math.max(nct, nrt); k++) {
    if (k < nct) {
      // Compute the transformation for the k-th column and place the k-th
      // diagonal in s[k].
      s[k] = 0;
      for (var i = k; i < m; i++) {
        s[k] = _hypot(s[k], a[i][k]);
      }
      if (s[k] != 0.0) {
        if (a[k][k] < 0.0) s[k] = -s[k];
        for (var i = k; i < m; i++) {
          a[i][k] /= s[k];
        }
        a[k][k] += 1.0;
      }
      s[k] = -s[k];
    }
    for (var j = k + 1; j < n; j++) {
      if (k < nct && s[k] != 0.0) {
        // Apply the transformation.
        var t = 0.0;
        for (var i = k; i < m; i++) {
          t += a[i][k] * a[i][j];
        }
        t = -t / a[k][k];
        for (var i = k; i < m; i++) {
          a[i][j] += t * a[i][k];
        }
      }
      // Place the k-th row of A into e for the subsequent calculation of the
      // row transformation.
      e[j] = a[k][j];
    }
    if (k < nct) {
      // Place the transformation in U for subsequent back multiplication.
      for (var i = k; i < m; i++) {
        u[i][k] = a[i][k];
      }
    }
    if (k < nrt) {
      // Compute the k-th row transformation and place the k-th superdiagonal
      // in e[k].
      e[k] = 0;
      for (var i = k + 1; i < n; i++) {
        e[k] = _hypot(e[k], e[i]);
      }
      if (e[k] != 0.0) {
        if (e[k + 1] < 0.0) e[k] = -e[k];
        for (var i = k + 1; i < n; i++) {
          e[i] /= e[k];
        }
        e[k + 1] += 1.0;
      }
      e[k] = -e[k];
      if (k + 1 < m && e[k] != 0.0) {
        // Apply the transformation.
        for (var i = k + 1; i < m; i++) {
          work[i] = 0.0;
        }
        for (var j = k + 1; j < n; j++) {
          for (var i = k + 1; i < m; i++) {
            work[i] += e[j] * a[i][j];
          }
        }
        for (var j = k + 1; j < n; j++) {
          final t = -e[j] / e[k + 1];
          for (var i = k + 1; i < m; i++) {
            a[i][j] += t * work[i];
          }
        }
      }
      // Place the transformation in V for subsequent back multiplication.
      for (var i = k + 1; i < n; i++) {
        v[i][k] = e[i];
      }
    }
  }

  // Set up the final bidiagonal matrix of order p.
  var p = math.min(n, m + 1);
  if (nct < n) s[nct] = a[nct][nct];
  if (m < p) s[p - 1] = 0.0;
  if (nrt + 1 < p) e[nrt] = a[nrt][p - 1];
  e[p - 1] = 0.0;

  // Generate U.
  for (var j = nct; j < nu; j++) {
    for (var i = 0; i < m; i++) {
      u[i][j] = 0.0;
    }
    u[j][j] = 1.0;
  }
  for (var k = nct - 1; k >= 0; k--) {
    if (s[k] != 0.0) {
      for (var j = k + 1; j < nu; j++) {
        var t = 0.0;
        for (var i = k; i < m; i++) {
          t += u[i][k] * u[i][j];
        }
        t = -t / u[k][k];
        for (var i = k; i < m; i++) {
          u[i][j] += t * u[i][k];
        }
      }
      for (var i = k; i < m; i++) {
        u[i][k] = -u[i][k];
      }
      u[k][k] = 1.0 + u[k][k];
      for (var i = 0; i < k - 1; i++) {
        u[i][k] = 0.0;
      }
    } else {
      for (var i = 0; i < m; i++) {
        u[i][k] = 0.0;
      }
      u[k][k] = 1.0;
    }
  }

  // Generate V.
  for (var k = n - 1; k >= 0; k--) {
    if (k < nrt && e[k] != 0.0) {
      for (var j = k + 1; j < nu; j++) {
        var t = 0.0;
        for (var i = k + 1; i < n; i++) {
          t += v[i][k] * v[i][j];
        }
        t = -t / v[k + 1][k];
        for (var i = k + 1; i < n; i++) {
          v[i][j] += t * v[i][k];
        }
      }
    }
    for (var i = 0; i < n; i++) {
      v[i][k] = 0.0;
    }
    v[k][k] = 1.0;
  }

  // Chase the superdiagonal entries to zero, one implicit QR step at a time.
  final pp = p - 1;
  var iteration = 0;
  while (p > 0) {
    int k;
    int kase;

    // Split at negligible s[k] or e[k], which decides the case below:
    //   1  s[p - 1] is negligible,
    //   2  s[k] is negligible and k < p - 1,
    //   3  e[k - 1] is negligible, k < p - 1, and s[k..p - 1] are not
    //      negligible, so this is a QR step,
    //   4  e[p - 2] is negligible, so a value has converged.
    for (k = p - 2; k >= -1; k--) {
      if (k == -1) break;
      if (e[k].abs() <= _tiny + _epsilon * (s[k].abs() + s[k + 1].abs())) {
        e[k] = 0.0;
        break;
      }
    }
    if (k == p - 2) {
      kase = 4;
    } else {
      int ks;
      for (ks = p - 1; ks >= k; ks--) {
        if (ks == k) break;
        final t = (ks != p ? e[ks].abs() : 0.0) + (ks != k + 1 ? e[ks - 1].abs() : 0.0);
        if (s[ks].abs() <= _tiny + _epsilon * t) {
          s[ks] = 0.0;
          break;
        }
      }
      if (ks == k) {
        kase = 3;
      } else if (ks == p - 1) {
        kase = 1;
      } else {
        kase = 2;
        k = ks;
      }
    }
    k++;

    switch (kase) {
      // Deflate negligible s[p - 1].
      case 1:
        var f = e[p - 2];
        e[p - 2] = 0.0;
        for (var j = p - 2; j >= k; j--) {
          var t = _hypot(s[j], f);
          final cs = s[j] / t;
          final sn = f / t;
          s[j] = t;
          if (j != k) {
            f = -sn * e[j - 1];
            e[j - 1] = cs * e[j - 1];
          }
          for (var i = 0; i < n; i++) {
            t = cs * v[i][j] + sn * v[i][p - 1];
            v[i][p - 1] = -sn * v[i][j] + cs * v[i][p - 1];
            v[i][j] = t;
          }
        }

      // Split at negligible s[k].
      case 2:
        var f = e[k - 1];
        e[k - 1] = 0.0;
        for (var j = k; j < p; j++) {
          var t = _hypot(s[j], f);
          final cs = s[j] / t;
          final sn = f / t;
          s[j] = t;
          f = -sn * e[j];
          e[j] = cs * e[j];
          for (var i = 0; i < m; i++) {
            t = cs * u[i][j] + sn * u[i][k - 1];
            u[i][k - 1] = -sn * u[i][j] + cs * u[i][k - 1];
            u[i][j] = t;
          }
        }

      // Perform one QR step.
      case 3:
        // Calculate the shift, scaled to keep b * b + c in range.
        final scale = math.max(
          math.max(math.max(math.max(s[p - 1].abs(), s[p - 2].abs()), e[p - 2].abs()), s[k].abs()),
          e[k].abs(),
        );
        final sp = s[p - 1] / scale;
        final spm1 = s[p - 2] / scale;
        final epm1 = e[p - 2] / scale;
        final sk = s[k] / scale;
        final ek = e[k] / scale;
        final b = ((spm1 + sp) * (spm1 - sp) + epm1 * epm1) / 2.0;
        final c = (sp * epm1) * (sp * epm1);
        var shift = 0.0;
        if (b != 0.0 || c != 0.0) {
          shift = math.sqrt(b * b + c);
          if (b < 0.0) shift = -shift;
          shift = c / (b + shift);
        }
        var f = (sk + sp) * (sk - sp) + shift;
        var g = sk * ek;
        // Chase zeros.
        for (var j = k; j < p - 1; j++) {
          var t = _hypot(f, g);
          var cs = f / t;
          var sn = g / t;
          if (j != k) e[j - 1] = t;
          f = cs * s[j] + sn * e[j];
          e[j] = cs * e[j] - sn * s[j];
          g = sn * s[j + 1];
          s[j + 1] = cs * s[j + 1];
          for (var i = 0; i < n; i++) {
            t = cs * v[i][j] + sn * v[i][j + 1];
            v[i][j + 1] = -sn * v[i][j] + cs * v[i][j + 1];
            v[i][j] = t;
          }
          t = _hypot(f, g);
          cs = f / t;
          sn = g / t;
          s[j] = t;
          f = cs * e[j] + sn * s[j + 1];
          s[j + 1] = -sn * e[j] + cs * s[j + 1];
          g = sn * e[j + 1];
          e[j + 1] = cs * e[j + 1];
          if (j < m - 1) {
            for (var i = 0; i < m; i++) {
              t = cs * u[i][j] + sn * u[i][j + 1];
              u[i][j + 1] = -sn * u[i][j] + cs * u[i][j + 1];
              u[i][j] = t;
            }
          }
        }
        e[p - 2] = f;
        iteration = iteration + 1;

      // A singular value has converged.
      case 4:
        // Make the singular value positive.
        if (s[k] <= 0.0) {
          s[k] = s[k] < 0.0 ? -s[k] : 0.0;
          for (var i = 0; i <= pp; i++) {
            v[i][k] = -v[i][k];
          }
        }
        // Order the singular values.
        while (k < pp) {
          if (s[k] >= s[k + 1]) break;
          var t = s[k];
          s[k] = s[k + 1];
          s[k + 1] = t;
          if (k < n - 1) {
            for (var i = 0; i < n; i++) {
              t = v[i][k + 1];
              v[i][k + 1] = v[i][k];
              v[i][k] = t;
            }
          }
          if (k < m - 1) {
            for (var i = 0; i < m; i++) {
              t = u[i][k + 1];
              u[i][k + 1] = u[i][k];
              u[i][k] = t;
            }
          }
          k++;
        }
        iteration = 0;
        p--;
    }
  }

  return SvdResult(u: u, v: v, singularValues: s);
}

/// `sqrt(a^2 + b^2)` without intermediate overflow or underflow.
double _hypot(double a, double b) {
  if (a.abs() > b.abs()) {
    final r = b / a;
    return a.abs() * math.sqrt(1 + r * r);
  }
  if (b != 0) {
    final r = a / b;
    return b.abs() * math.sqrt(1 + r * r);
  }
  return 0.0;
}

/// Machine epsilon for a double, the relative size below which JAMA treats a
/// bidiagonal entry as zero.
final _epsilon = math.pow(2.0, -52.0).toDouble();

/// Absolute floor for the same test, well below any magnitude the
/// decomposition can produce without having already underflowed.
final _tiny = math.pow(2.0, -966.0).toDouble();
