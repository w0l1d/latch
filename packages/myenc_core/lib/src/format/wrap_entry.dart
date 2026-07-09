import 'dart:typed_data';

enum WrapType {
  passphrase(0x01),
  hardwareKey(0x02),
  recipient(0x03);

  const WrapType(this.code);
  final int code;

  static WrapType? fromCode(int code) {
    for (final v in values) {
      if (v.code == code) return v;
    }
    return null;
  }
}

class WrapEntry {
  final WrapType type;
  final Uint8List bytes;

  const WrapEntry({required this.type, required this.bytes});
}
