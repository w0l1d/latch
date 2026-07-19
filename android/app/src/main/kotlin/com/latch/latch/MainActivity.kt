package com.latch.latch

import io.flutter.embedding.android.FlutterFragmentActivity

// local_auth's biometric prompt requires a FragmentActivity host — with a
// plain FlutterActivity every authenticate() call throws no_fragment_activity.
class MainActivity : FlutterFragmentActivity()
