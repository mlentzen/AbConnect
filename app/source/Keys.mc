import Toybox.Lang;

//! Keys and schema of the Object Store.
//!
//! Connect IQ limits every stored value to 8 KB. That is why each book has its
//! own key in the store instead of one global structure, and the values are
//! flat strings instead of nested maps.
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
    //! When a plugged-in sync last started. Manual syncs do not write this.
    const LAST_AUTO_SYNC = "AUT";
    //! Books that have segments on the watch.
    //!
    //! Application.Storage cannot enumerate its keys. Without this list a
    //! deselected book would no longer be findable and its segments would stay
    //! in the media cache forever.
    const KNOWN = "KNW";

    //! Prefix: map refId -> "segIdx|duration" for a book.
    const LOCAL_PREFIX = "L_";
    //! Prefix: "title|author|segmentCount" for a book.
    const BOOK_PREFIX = "B_";

    //! When incremented, the store is cleared on the next start.
    const SCHEMA_VERSION = 1;

    function local(bookId as String) as String {
        return LOCAL_PREFIX + bookId;
    }

    function book(bookId as String) as String {
        return BOOK_PREFIX + bookId;
    }
}

//! Names of the app settings from resources/settings/properties.xml.
module Settings {
    const PROXY_URL = "proxyUrl";
    const PROXY_TOKEN = "proxyToken";
}
