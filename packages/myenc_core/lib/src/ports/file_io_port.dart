import 'dart:typed_data';

abstract interface class FileIoPort {
  Stream<Uint8List> openRead(String path, {int chunkSize = 65536});
  Future<void> writeChunked(String path, Stream<Uint8List> chunks);
  Future<void> deleteFile(String path);
  Future<bool> exists(String path);
  Future<int> fileSize(String path);
  String withSuffix(String path, String suffix);
  String withoutSuffix(String path, String suffix);
  String resolveNameCollision(String path);
}
