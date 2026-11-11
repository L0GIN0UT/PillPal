package com.pillpal.pillpal

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/**
 * The `pillpal/reports` channel (docs/adr/0019 §5): open, save and share a
 * report PDF that the app keeps in `filesDir/reports/<id>/`.
 *
 * Only an absolute path arrives from Dart. It is canonicalised (symlinks and
 * `..` resolved) and must be a `.pdf` file inside `filesDir/reports`;
 * anything else is `invalid_path`. Other apps never get the path: they get a
 * `content://` Uri of [ReportFileProvider] (a FileProvider) with a read grant for that one
 * file. Answers: `done`, `cancelled` (save picker closed), `no_app`.
 *
 * One call at a time: while a save waits for the system picker or copies the
 * file, any other call answers the error `busy`. Copying runs on a worker
 * thread, never on the main thread.
 */
class ReportChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    /** The save waiting for the picker or the copy; at most one, main thread only. */
    private var pending: Pending? = null

    private class Pending(val result: MethodChannel.Result, val source: File)

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in METHODS) {
            result.notImplemented()
            return
        }
        if (pending != null) {
            result.error("busy", null, null)
            return
        }
        val file = reportFile(call.argument<String>("path"))
        if (file == null) {
            result.error("invalid_path", null, null)
            return
        }
        when (call.method) {
            "open" -> open(file, result)
            "share" -> share(file, result)
            else -> save(file, result)
        }
    }

    /** The file if [path] is a PDF inside `filesDir/reports`, else null. */
    internal fun reportFile(path: String?): File? {
        if (path.isNullOrEmpty()) return null
        return try {
            validatedReportFile(File(activity.filesDir, REPORTS_FOLDER), File(path))
        } catch (error: IOException) {
            null
        }
    }

    private fun open(file: File, result: MethodChannel.Result) {
        val uri = uriOf(file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, PDF)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        result.success(if (start(intent)) "done" else "no_app")
    }

    private fun share(file: File, result: MethodChannel.Result) {
        val uri = uriOf(file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = PDF
            putExtra(Intent.EXTRA_STREAM, uri)
            // The grant of the chooser's target comes from the ClipData.
            clipData = ClipData.newRawUri("", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        result.success(if (start(Intent.createChooser(send, null))) "done" else "no_app")
    }

    private fun save(file: File, result: MethodChannel.Result) {
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(PDF)
            .putExtra(Intent.EXTRA_TITLE, file.name)
        pending = Pending(result, file)
        try {
            activity.startActivityForResult(intent, REQUEST_SAVE)
        } catch (error: ActivityNotFoundException) {
            pending = null
            result.success("no_app")
        }
    }

    /** Called from `MainActivity.onActivityResult`; true when it was ours. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_SAVE) return false
        val save = pending ?: return true
        val target = data?.data
        if (resultCode != Activity.RESULT_OK || target == null) {
            pending = null
            save.result.success("cancelled")
            return true
        }
        // The slot stays taken until the copy ends.
        worker.execute {
            val failed = try {
                copy(save.source, target)
                false
            } catch (error: IOException) {
                true
            } catch (error: SecurityException) {
                true
            }
            main.post {
                pending = null
                if (failed) save.result.error("io_error", null, null)
                else save.result.success("done")
            }
        }
        return true
    }

    private fun copy(source: File, target: Uri) {
        val output = activity.contentResolver.openOutputStream(target, "w")
            ?: throw IOException("no output stream")
        output.use { out -> source.inputStream().use { it.copyTo(out) } }
    }

    private fun uriOf(file: File): Uri =
        FileProvider.getUriForFile(activity, "${activity.packageName}.reports", file)

    /** False when no app handles [intent]. */
    private fun start(intent: Intent): Boolean = try {
        activity.startActivity(intent)
        true
    } catch (error: ActivityNotFoundException) {
        false
    }

    /** Stops the worker when the engine goes away. */
    fun dispose() {
        worker.shutdown()
    }

    companion object {
        const val CHANNEL = "pillpal/reports"
        const val REPORTS_FOLDER = "reports"
        private const val PDF = "application/pdf"
        private const val REQUEST_SAVE = 4817
        private val METHODS = setOf("open", "saveAs", "share")

        /**
         * [candidate] resolved to its canonical form if it is a `.pdf` file
         * strictly inside [root] (itself canonicalised), else null.
         */
        fun validatedReportFile(root: File, candidate: File): File? {
            val canonicalRoot = root.canonicalFile
            val canonical = candidate.canonicalFile
            val inside = canonical.path.startsWith(canonicalRoot.path + File.separator)
            return if (inside && canonical.isFile && canonical.name.endsWith(".pdf")) {
                canonical
            } else {
                null
            }
        }
    }
}
