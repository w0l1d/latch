import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_platform_interface/types/auth_messages.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Shared platform-interface fakes used to drive the real Latch app in
/// widget tests without touching real biometrics, file pickers, or
/// filesystem-root platform channels.

class FakeLocalAuth extends Fake implements LocalAuthentication {
  bool _nextResult = true;
  bool _supported = true;
  void setNextResult(bool v) => _nextResult = v;
  void setSupported(bool v) => _supported = v;

  @override
  Future<bool> get canCheckBiometrics async => _supported;

  @override
  Future<bool> isDeviceSupported() async => _supported;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<AuthMessages> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async => _nextResult;
}

class FakeFilePicker extends FilePicker {
  List<String> _pickPaths = const [];
  String? _pickDir;

  void configure({List<String> paths = const [], String? dir}) {
    _pickPaths = paths;
    _pickDir = dir;
  }

  @override
  Future<FilePickerResult?> pickFiles({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    if (_pickPaths.isEmpty) return null;
    return FilePickerResult(
      _pickPaths
          .map(
            (p) => PlatformFile(
              path: p,
              name: p.split('/').last,
              size: File(p).existsSync() ? File(p).lengthSync() : 0,
            ),
          )
          .toList(),
    );
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => _pickDir;

  @override
  Future<bool?> clearTemporaryFiles() async => true;
}

class FakePathProvider extends PathProviderPlatform {
  String _docs = '';
  void configure(String docs) => _docs = docs;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docs;
  @override
  Future<String?> getTemporaryPath() async => _docs;
  @override
  Future<String?> getApplicationSupportPath() async => _docs;
  @override
  Future<String?> getLibraryPath() async => _docs;
  @override
  Future<String?> getExternalStoragePath() async => _docs;
  @override
  Future<List<String>?> getExternalCachePaths() async => [_docs];
  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async => [_docs];
  @override
  Future<String?> getDownloadsPath() async => _docs;
}
