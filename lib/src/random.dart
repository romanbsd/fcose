/// Deterministic xorshift32 generator with JavaScript-compatible 32-bit steps.
///
/// Dart VM integers are not limited to 32 bits, so every operation is masked
/// just as JavaScript bitwise operators truncate their operands.
final class Xorshift32 {
  Xorshift32(int seed) : _state = seed & _uint32Mask;

  int _state;

  int nextUint32() {
    var value = _state;
    value = (value ^ (value << 13)) & _uint32Mask;
    value = (value ^ (value >>> 17)) & _uint32Mask;
    value = (value ^ (value << 5)) & _uint32Mask;
    return _state = value;
  }

  double nextDouble() => nextUint32() / _uint32Range;

  int nextInt(int maximum) => (nextDouble() * maximum).floor();
}

const _uint32Mask = 0xffffffff;
const _uint32Range = 0x100000000;
