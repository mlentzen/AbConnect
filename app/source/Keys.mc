import Toybox.Application;
import Toybox.Lang;

module Keys {
    const DESIRED = "DES";
    const LAST_CHECK = "CHK";
    const PROGRESS = "PRG";
    const SCHEMA = "VER";
    const CURRENT = "CUR";
    const SYNC_REQUEST = "SYN";
    const SYNC_RESUME = "RSM";
    const LEGACY_AUTO_SYNC = "AUT";
    const LAST_SYNC = "SRS";
    const LAST_PLAYED = "LPL";
    const PLAYLIST = "PLS";
    const KNOWN = "KNW";
    const LOCAL_PREFIX = "L_";
    const BOOK_PREFIX = "B_";

    const SCHEMA_VERSION = 1;

    function localChunk(bookId as String, chunk as Number) as String {
        if (chunk <= 0) {
            return LOCAL_PREFIX + bookId;
        }
        return LOCAL_PREFIX + bookId + "#" + chunk.toString();
    }

    function book(bookId as String) as String {
        return BOOK_PREFIX + bookId;
    }
}

module Settings {
    const PROXY_URL = "proxyUrl";
    const PROXY_TOKEN = "proxyToken";
    const SYNC_ON_PLUGGED_IN = "syncOnPluggedIn";

    function syncOnPluggedIn() as Boolean {
        var value = Application.Properties.getValue(SYNC_ON_PLUGGED_IN);
        return (value instanceof Boolean) ? value : true;
    }
}
