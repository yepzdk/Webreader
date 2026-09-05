package dk.yepz.webreader

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Log
import androidx.documentfile.provider.DocumentFile

/**
 * The shared folder devices exchange their state through, as the Storage Access Framework sees
 * it: `<chosen tree>/WebReader/`, one `<deviceID>.json` per device.
 *
 * This is the Android answer to `ReaderKit.SyncFolder`, and it is only I/O — which files exist,
 * what is in them, and where the bytes ReaderKit hands back are put. The fold itself is the
 * `syncPeers` call; nothing here reads or writes a device file's contents.
 *
 * There is no remembered path and no `SharedPreferences` entry for the folder. A tree picked
 * through `ACTION_OPEN_DOCUMENT_TREE` is persisted by the system when the grant is taken, and
 * `ContentResolver.getPersistedUriPermissions` is that record — a second copy in app storage
 * could only ever disagree with it after the user revokes the grant.
 */
internal class SyncFolder(private val context: Context) {

    /** What a cycle did, so the caller can say something when it did not work. */
    sealed interface Outcome {
        /** Nothing to do: no folder has been chosen. */
        data object NotConfigured : Outcome

        /** The folder is gone, renamed beyond the grant, or the grant was revoked. */
        data object Unreadable : Outcome

        /** Peers were read and folded; [reply] carries the commands and the peer list. */
        data class Folded(val reply: ReaderBridge.Reply) : Outcome

        /** Peers were read, but this device's own file could not be published. */
        data class WriteFailed(val reply: ReaderBridge.Reply) : Outcome
    }

    /** The intent that asks for a folder. */
    fun setupIntent(): Intent =
        Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                     Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                     Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }

    /**
     * Records the chosen tree. Read *and* write: a device that can only read is a device that
     * receives everyone else's articles and publishes none of its own, which looks like sync
     * working right up until the other end is checked.
     */
    fun remember(tree: Uri) {
        context.contentResolver.takePersistableUriPermission(
            tree,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
    }

    fun isConfigured(): Boolean = tree() != null

    /**
     * The chosen folder as something worth showing, or null when sync is off — the Android
     * counterpart of the Apple hosts' `~`-abbreviated path. A tree's document id is
     * `<volume>:<path>`, so the volume is dropped for the internal storage everyone has and
     * kept for anything else, where it is the only thing telling two folders apart.
     */
    fun displayPath(): String? {
        val tree = tree() ?: return null
        val id = runCatching { DocumentsContract.getTreeDocumentId(tree) }.getOrNull() ?: return null
        val volume = id.substringBefore(':', missingDelimiterValue = "")
        val path = id.substringAfter(':', missingDelimiterValue = id)
        return when {
            path.isEmpty() -> volume.ifEmpty { null }
            volume == "primary" || volume.isEmpty() -> path
            else -> "$volume:$path"
        }
    }

    /** The chosen tree, or null when sync has never been set up or the grant was revoked. */
    private fun tree(): Uri? =
        context.contentResolver.persistedUriPermissions
            .firstOrNull { it.isReadPermission && it.isWritePermission }
            ?.uri

    /**
     * One cycle: read every device file, hand the lot to ReaderKit, publish what it names.
     *
     * Blocking, and must not run on the main thread — a document provider can be backed by a
     * network share, and `listFiles` on one of those is a round trip per call.
     */
    fun cycle(deviceId: String, deviceName: String): Outcome {
        val tree = tree() ?: return Outcome.NotConfigured
        // The folder the user chose is NOT created; only the `WebReader` subfolder inside it
        // is. If the chosen one has gone away, the honest answer is that sync is broken, not a
        // fresh empty folder at a path nothing syncs.
        val root = DocumentFile.fromTreeUri(context, tree)?.takeIf { it.isDirectory }
            ?: return Outcome.Unreadable
        val folder = root.findFile(FOLDER_NAME)?.takeIf { it.isDirectory }
            ?: root.createDirectory(FOLDER_NAME)
            ?: return Outcome.Unreadable

        // A missing file, a half-written one, or a stray JSON the user dropped in the folder
        // all read as nothing: `DeviceState.decode` is written to tolerate exactly that, so
        // unreadable entries are dropped here rather than failing the cycle.
        val files = folder.listFiles().filter { it.isFile && isDeviceState(it.name) }
        val states = files.mapNotNull { read(it.uri) }

        val reply = ReaderBridge.syncPeers(deviceId, deviceName, states)
        val name = reply.text("writeFileName")
        val contents = reply.text("writeContents")
        if (name == null || contents == null) return Outcome.Folded(reply)

        val target = files.firstOrNull { it.name == name }
            ?: folder.createFile(JSON_MIME, name)
            ?: return Outcome.WriteFailed(reply)
        if (!write(target.uri, contents)) return Outcome.WriteFailed(reply)
        return Outcome.Folded(reply)
    }

    /** A device file, and not a `.name.json` conflict copy or sync placeholder. */
    private fun isDeviceState(name: String?): Boolean =
        name != null && name.endsWith(".json") && !name.startsWith(".")

    private fun read(uri: Uri): String? =
        try {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes().decodeToString() }
        } catch (e: Exception) {
            Log.w(TAG, "unreadable device file $uri", e)
            null
        }

    /**
     * Publishes this device's file.
     *
     * Mode `"wt"` truncates: without it a shorter state leaves the tail of the previous one
     * behind and the file parses as neither. There is no atomic replace here — the Apple and
     * GTK hosts write a temp file and rename it, and SAF has no rename-over — so a cycle
     * interrupted mid-write leaves a partial file, which the readers already treat as absent.
     */
    private fun write(uri: Uri, contents: String): Boolean =
        try {
            context.contentResolver.openOutputStream(uri, "wt")?.use {
                it.write(contents.encodeToByteArray())
                true
            } ?: false
        } catch (e: Exception) {
            Log.w(TAG, "could not publish to $uri", e)
            false
        }

    private companion object {
        const val TAG = "SyncFolder"

        /** The subfolder created inside whatever the user picked, so pointing WebReader at a
         *  whole Nextcloud folder doesn't scatter files across it. Matches `SyncFolder`'s. */
        const val FOLDER_NAME = "WebReader"

        const val JSON_MIME = "application/json"
    }
}
