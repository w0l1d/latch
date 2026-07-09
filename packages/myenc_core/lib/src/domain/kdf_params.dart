class KdfParams {
  // Security floor — reject params below these (spec §7)
  static const int minOpslimit = 2;
  static const int minMemlimitKib = 65536; // 64 MiB

  // Conservative defaults (overridden by device benchmark result)
  static const KdfParams defaults = KdfParams(opslimit: 3, memlimit: 65536);

  final int opslimit;
  final int memlimit; // KiB

  const KdfParams({required this.opslimit, required this.memlimit});

  bool meetsFloor() => opslimit >= minOpslimit && memlimit >= minMemlimitKib;
}
