import 'dart:async';
import 'dart:math';

enum PassphraseStrength { weak, fair, strong, veryStrong }

class PassphraseResult {
  final PassphraseStrength strength;
  final String label;
  final double score;

  const PassphraseResult(this.strength, this.label, this.score);
}

class CryptoStub {
  static PassphraseResult evaluate(String passphrase) {
    if (passphrase.isEmpty)
      return const PassphraseResult(PassphraseStrength.weak, '', 0);
    final len = passphrase.length;
    final hasUpper = passphrase.contains(RegExp(r'[A-Z]'));
    final hasDigit = passphrase.contains(RegExp(r'[0-9]'));
    final hasSymbol = passphrase.contains(RegExp(r'[^a-zA-Z0-9]'));
    final hasSpaces = passphrase.contains(' ');
    final wordCount = hasSpaces
        ? passphrase.trim().split(RegExp(r'\s+')).length
        : 1;

    int score = 0;
    if (len >= 8) score++;
    if (len >= 16) score++;
    if (len >= 24) score++;
    if (hasUpper || hasDigit) score++;
    if (hasSymbol || wordCount >= 3) score++;
    if (wordCount >= 4) score++;

    if (score <= 1)
      return PassphraseResult(PassphraseStrength.weak, 'Too short', score / 6);
    if (score == 2)
      return PassphraseResult(
        PassphraseStrength.fair,
        'Could be stronger',
        score / 6,
      );
    if (score <= 4)
      return PassphraseResult(
        PassphraseStrength.strong,
        'Strong — good work',
        score / 6,
      );
    return PassphraseResult(
      PassphraseStrength.veryStrong,
      'Excellent — long and easy to remember',
      1.0,
    );
  }

  static Stream<double> encryptFiles(List<String> fileNames) async* {
    final rng = Random();
    for (var i = 0; i < fileNames.length; i++) {
      final steps = 8 + rng.nextInt(4);
      for (var s = 0; s <= steps; s++) {
        await Future.delayed(const Duration(milliseconds: 180));
        yield (i + s / steps) / fileNames.length;
      }
    }
    yield 1.0;
  }

  static Stream<double> decryptFile(String fileName) async* {
    const steps = 10;
    for (var s = 0; s <= steps; s++) {
      await Future.delayed(const Duration(milliseconds: 150));
      yield s / steps;
    }
    yield 1.0;
  }
}
