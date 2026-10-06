abstract interface class FreeSpacePort {
  /// Bytes available to this app at [path]'s volume, or null when the platform
  /// will not say. Null means *proceed*, never *refuse*. Must not throw.
  Future<int?> freeBytesAt(String path);
}
