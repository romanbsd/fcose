import 'package:fcose/src/random.dart';
import 'package:test/test.dart';

void main() {
  test('xorshift32 matches JavaScript unsigned bitwise semantics', () {
    final random = Xorshift32(1);

    expect(
      [for (var index = 0; index < 5; index++) random.nextUint32()],
      [270369, 67634689, 2647435461, 307599695, 2398689233],
    );
  });
}
