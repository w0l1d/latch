package com.latch.latch

import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

// local_auth's biometric prompt requires a FragmentActivity host — with a
// plain FlutterActivity every authenticate() call throws no_fragment_activity.
class MainActivity : FlutterFragmentActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // SAF bridge: the file picker hands Dart a private cache COPY of each
        // selection; the user's real document is only reachable through its
        // content:// URI. These methods let in-place operations (rewrap,
        // share, shred, delete-originals) act on the actual file.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "latch/saf")
            .setMethodCallHandler { call, result ->
                // File IO off the main thread — write-back can copy large files.
                Thread {
                    try {
                        when (call.method) {
                            // Copy the (modified) cache file over the real document.
                            "writeBack" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                val path = call.argument<String>("path")!!
                                val out = contentResolver.openOutputStream(uri, "wt")
                                    ?: throw IllegalStateException("cannot open $uri for writing")
                                out.use { stream ->
                                    File(path).inputStream().use { it.copyTo(stream) }
                                    if (stream is FileOutputStream) stream.fd.sync()
                                }
                                runOnUiThread { result.success(null) }
                            }
                            // Overwrite the real document's first bytes (crypto-erase
                            // of the header) without truncating, then delete it.
                            "overwriteAndDelete" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                val bytes = call.argument<ByteArray>("bytes")!!
                                val pfd = contentResolver.openFileDescriptor(uri, "rw")
                                    ?: throw IllegalStateException("cannot open $uri read-write")
                                pfd.use {
                                    FileOutputStream(it.fileDescriptor).use { out ->
                                        out.write(bytes)
                                        out.fd.sync()
                                    }
                                }
                                DocumentsContract.deleteDocument(contentResolver, uri)
                                runOnUiThread { result.success(null) }
                            }
                            // Delete the real document (encrypt's delete-originals).
                            "delete" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                DocumentsContract.deleteDocument(contentResolver, uri)
                                runOnUiThread { result.success(null) }
                            }
                            else -> runOnUiThread { result.notImplemented() }
                        }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("saf_error", e.message, null) }
                    }
                }.start()
            }
    }
}
