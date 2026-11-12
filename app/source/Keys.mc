import Toybox.Application;
import Toybox.Lang;

module Keys {
    //! Array of the book IDs from the most recently read playlist.
    //!
    //! The playlist on the server is the target; this is only its last known
    //! state, so the watch knows what should be on it even without a
    //! connection.
    const DESIRED = "DES";
    //! Time of the last successful playlist query.
    const LAST_CHECK = "CHK";
    //! Flat map bookId -> "segIdx|seconds|timestamp".
    //!
    //! A timestamp above 0 is listening the server has not confirmed yet; 0 is
    //! a position that agrees with the server, adopted from it or accepted by it.
    const PROGRESS = "PRG";
    //! Schema version; if it changes, the store is discarded.
    const SCHEMA = "VER";
    //! Book the player is currently playing.
    const CURRENT = "CUR";
    //! When the Download books row last asked for a sync, as a timestamp.
    //!
    //! startSync() ends the app and relaunches it in sync mode; this stamp is
    //! how isSyncNeeded() can still tell that the sync was asked for by hand.
    const SYNC_REQUEST = "SYN";
    //! [timestamp, count] when a sync was restarted after Back.
    //!
    //! Dismissing a notification with Back ends the sync session. The restart
    //! is how the download continues, and the count stops a restart loop.
    const SYNC_RESUME = "RSM";
    //! Written by older versions, which limited the plugged-in sync to once a
    //! day. Nothing reads it any more; Store.checkSchema() removes it.
    const LEGACY_AUTO_SYNC = "AUT";
    //! [timestamp, error or null] of the last sync that ran to its end.
    //!
    //! A sync the user stopped is not recorded: it says nothing about the server.
    const LAST_SYNC = "SRS";
    //! [bookId, timestamp, segment, seconds] of the last listening on this watch.
    //!
    //! The position's own timestamp cannot say when the user last listened:
    //! it is zeroed once the server agrees. This one is only written by playback,
    //! and the segment and seconds show whether the position is still where
    //! that listening ended.
    const LAST_PLAYED = "LPL";
    //! Last playlist fetched from the proxy: id, status, percent, title.
    //!
    //! Sync configuration is where the simulator shows this list. The watch
    //! never opens that mode from the music menu, so the playback menu reads
    //! the same snapshot.
    const PLAYLIST = "PLS";
    //! Books that have segments on the watch.
    //!
    //! Application.Storage cannot enumerate its keys. Without this list a
    //! deselected book would no longer be findable and its segments would stay
    //! in the media cache forever.
    const KNOWN = "KNW";

    //! Prefix: map refId -> "segIdx|duration|title" for a book.
    //!
    //! Chunk 0 keeps this key. Further chunks append "#n", because one map
    //! is capped at 8 KB and a long book does not fit in it.
    const LOCAL_PREFIX = "L_";
    //! Prefix: "title|author|segmentCount" for a book.
    const BOOK_PREFIX = "B_";

    //! When incremented, the store is cleared on the next start.
    const SCHEMA_VERSION = 1;

    function local(bookId as String) as String {
        return LOCAL_PREFIX + bookId;
    }

    //! Chunk 0 is the original key, so a store written before chunking still loads.
    function localChunk(bookId as String, chunk as Number) as String {
        if (chunk <= 0) {
            return local(bookId);
        }
        return local(bookId) + "#" + chunk.toString();
    }

    function book(bookId as String) as String {
        return BOOK_PREFIX + bookId;
    }
}

//! Names of the app settings from resources/settings/properties.xml.
module Settings {
    const PROXY_URL = "proxyUrl";
    const PROXY_TOKEN = "proxyToken";
    const SYNC_ON_PLUGGED_IN = "syncOnPluggedIn";

    //! Whether AbConnect joins a sync that the watch started by itself, for
    //! example while charging. On unless the user turned it off.
    function syncOnPluggedIn() as Boolean {
        var value = Application.Properties.getValue(SYNC_ON_PLUGGED_IN);
        if (value instanceof Boolean) {
            return value;
        }
        return true;
    }
}
