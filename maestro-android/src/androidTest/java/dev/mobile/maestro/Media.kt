package dev.mobile.maestro

import android.content.ContentResolver
import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.test.platform.app.InstrumentationRegistry
import java.io.OutputStream

object MediaStorage {

    fun createPendingMedia(mediaName: String, mediaExt: String): PendingMedia {
        val collection = when (mediaExt) {
            Service.FileType.JPG.ext,
            Service.FileType.PNG.ext,
            Service.FileType.GIF.ext,
            Service.FileType.JPEG.ext -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            Service.FileType.MP4.ext -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            else -> throw IllegalStateException("mime .$mediaExt not yet supported")
        }
        val ext = Service.FileType.values().first { it.ext == mediaExt }
        val contentValues = ContentValues()
        contentValues.apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, mediaName)
            put(MediaStore.MediaColumns.MIME_TYPE, ext.mimeType)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }
        val contentResolver = InstrumentationRegistry.getInstrumentation().targetContext.contentResolver
        val mediaUri = checkNotNull(contentResolver.insert(collection, contentValues)) {
            "Unable to create MediaStore entry for $mediaName"
        }
        val outputStream = try {
            checkNotNull(contentResolver.openOutputStream(mediaUri)) {
                "Unable to open MediaStore entry for $mediaName"
            }
        } catch (t: Throwable) {
            runCatching { contentResolver.delete(mediaUri, null, null) }
            throw t
        }

        return PendingMedia(
            contentResolver = contentResolver,
            uri = mediaUri,
            outputStream = outputStream,
            requiresPublishing = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q,
        )
    }
}

class PendingMedia internal constructor(
    private val contentResolver: ContentResolver,
    internal val uri: Uri,
    val outputStream: OutputStream,
    private val requiresPublishing: Boolean,
) {
    private var state = State.OPEN

    @Synchronized
    fun publish() {
        check(state == State.OPEN) { "MediaStore entry is no longer open" }

        try {
            outputStream.close()
            if (requiresPublishing) {
                val publishedRows = contentResolver.update(
                    uri,
                    ContentValues().apply {
                        put(MediaStore.MediaColumns.IS_PENDING, 0)
                    },
                    null,
                    null,
                )
                check(publishedRows == 1) {
                    "Unable to publish MediaStore entry $uri"
                }
            }
            state = State.PUBLISHED
        } catch (t: Throwable) {
            abort()
            throw t
        }
    }

    @Synchronized
    fun abort() {
        if (state != State.OPEN) {
            return
        }

        state = State.ABORTED
        runCatching { outputStream.close() }
        runCatching { contentResolver.delete(uri, null, null) }
    }

    private enum class State {
        OPEN,
        PUBLISHED,
        ABORTED,
    }
}
