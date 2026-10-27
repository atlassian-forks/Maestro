package dev.mobile.maestro

import android.content.ContentUris
import android.os.Build
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MediaStorageTest {

    private val contentResolver =
        InstrumentationRegistry.getInstrumentation().targetContext.contentResolver
    private val createdMedia = mutableListOf<PendingMedia>()

    @After
    fun cleanUp() {
        createdMedia.forEach { runCatching { contentResolver.delete(it.uri, null, null) } }
    }

    @Test
    fun publishClosesAndPublishesMediaStoreEntry() {
        val bytes = byteArrayOf(1, 2, 3, 4)
        val media = createMedia()

        media.outputStream.write(bytes)
        media.publish()

        val projection = mutableListOf(MediaStore.MediaColumns.SIZE).apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                add(MediaStore.MediaColumns.IS_PENDING)
            }
        }.toTypedArray()
        checkNotNull(
            contentResolver.query(
                media.uri,
                projection,
                null,
                null,
                null,
            )
        ).use { cursor ->
            assertEquals(true, cursor.moveToFirst())
            assertEquals(bytes.size.toLong(), cursor.getLong(0))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                assertEquals(0, cursor.getInt(1))
            }
        }
        val storedBytes = checkNotNull(contentResolver.openInputStream(media.uri)).use { it.readBytes() }
        assertArrayEquals(bytes, storedBytes)
    }

    @Test
    fun abortDeletesIncompleteMediaStoreEntry() {
        val media = createMedia()
        val mediaId = ContentUris.parseId(media.uri)

        media.outputStream.write(byteArrayOf(1, 2, 3, 4))
        media.abort()

        checkNotNull(
            contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns._ID} = ?",
                arrayOf(mediaId.toString()),
                null,
            )
        ).use { cursor ->
            assertEquals(false, cursor.moveToFirst())
        }
    }

    private fun createMedia(): PendingMedia {
        return MediaStorage.createPendingMedia(
            mediaName = "maestro-${System.nanoTime()}.png",
            mediaExt = Service.FileType.PNG.ext,
        ).also(createdMedia::add)
    }
}
