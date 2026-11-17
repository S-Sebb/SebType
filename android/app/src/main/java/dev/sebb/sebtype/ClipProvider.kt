package dev.sebb.sebtype

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import java.io.File
import java.io.FileNotFoundException
import java.util.UUID

/**
 * A clipboard image pasted from the history (#281): the app it goes to reads it from here, for five minutes,
 * by a link that names nothing but a random id; only that app gets the right to read it (the keyboard grants
 * it with the paste), and nothing else of the keyboard's files is reachable.
 */
class ClipProvider : ContentProvider() {
    private class Shared(val file: File, val mime: String, val until: Long)

    companion object {
        private const val MINUTES_5 = 5 * 60_000L
        private val shared = HashMap<String, Shared>()

        /** A link to [file] for the app it is pasted into */
        @Synchronized
        fun share(context: Context, file: File, mime: String): Uri {
            val now = SystemClock.elapsedRealtime()
            shared.values.removeAll { it.until < now }
            val id = UUID.randomUUID().toString()
            shared[id] = Shared(file, mime, now + MINUTES_5)
            return Uri.parse("content://${context.packageName}.clipboard/clip/$id")
        }

        @Synchronized
        private fun find(uri: Uri): Shared? =
            uri.pathSegments.takeIf { it.size == 2 && it[0] == "clip" }?.let { shared[it[1]] }?.takeIf { it.until >= SystemClock.elapsedRealtime() }
    }

    override fun onCreate() = true

    override fun getType(uri: Uri) = find(uri)?.mime

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val s = find(uri) ?: throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(s.file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?) = null
    override fun insert(uri: Uri, values: ContentValues?) = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
}
