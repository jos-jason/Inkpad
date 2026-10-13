import 'package:flutter_test/flutter_test.dart';
import 'package:inkpad/model/units.dart';

void main() {
  const mm = LengthFormat(unit: 'mm');
  const inches = LengthFormat(unit: 'in', fractions: true, denominator: 32);
  const decimalInches = LengthFormat(unit: 'in', decimals: 3);
  double pt(double mmValue) => mmValue * 72 / 25.4;

  test('formats millimetres with fractions of a millimetre', () {
    expect(mm.format(pt(12.5)), '12.5 mm');
    expect(mm.format(pt(300)), '300 mm');
    expect(mm.format(pt(0.25)), '0.25 mm');
    expect(mm.format(pt(0.004)), '0 mm');
    expect(const LengthFormat(unit: 'mm', decimals: 3).format(pt(0.125)), '0.125 mm');
  });

  test('formats inches as reduced fractions, or decimals', () {
    expect(inches.format(72 * 1.375), '1 3/8″');
    expect(inches.format(72 * 0.1875), '3/16″');
    expect(inches.format(72 * 2), '2″');
    expect(inches.format(-72 * 0.5), '-1/2″');
    expect(inches.format(72 * 0.3), '≈5/16″'); // not an exact 32nd
    expect(decimalInches.format(72 * 1.375), '1.375″');
  });

  test('reads plain numbers in the current unit, and other units', () {
    expect(mm.parse('12.5'), closeTo(pt(12.5), 1e-9));
    expect(mm.parse('12,5'), closeTo(pt(12.5), 1e-9));
    expect(mm.parse('1in'), closeTo(72, 1e-9));
    expect(mm.parse('2.5 cm'), closeTo(pt(25), 1e-9));
    expect(inches.parse('25.4mm'), closeTo(72, 1e-9));
    expect(inches.parse('1 3/8'), closeTo(72 * 1.375, 1e-9));
    expect(inches.parse('1-3/8"'), closeTo(72 * 1.375, 1e-9));
    expect(inches.parse('3/16'), closeTo(72 * 0.1875, 1e-9));
    expect(inches.parse("2' 6\""), closeTo(72 * 30, 1e-9));
  });

  test('reads simple sums', () {
    expect(mm.parse('300-2*12'), closeTo(pt(276), 1e-9));
    expect(mm.parse('(600 - 18) / 2'), closeTo(pt(291), 1e-9));
    expect(mm.parse('100 + 1/2in'), closeTo(pt(112.7), 1e-9));
    expect(mm.parse('-5'), closeTo(pt(-5), 1e-9));
  });

  test('rejects nonsense', () {
    expect(mm.parse(''), isNull);
    expect(mm.parse('abc'), isNull);
    expect(mm.parse('1/0'), isNull);
    expect(mm.parse('(3'), isNull);
    expect(mm.parse('3 +'), isNull);
  });

  test('angles', () {
    expect(parseDegrees('45'), 45);
    expect(parseDegrees('90+45°'), 135);
    expect(formatDegrees(370), '10°');
    expect(formatDegrees(-90), '-90°');
  });
}
