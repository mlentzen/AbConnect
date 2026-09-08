import Toybox.Lang;

//! Schlüssel und Schema des Object Store.
//!
//! Connect IQ begrenzt jeden gespeicherten Wert auf 8 KB. Deshalb liegt pro
//! Buch ein eigener Schlüssel im Store statt einer globalen Struktur, und die
//! Werte sind flache Strings statt verschachtelter Maps.
module Keys {
    //! Array der ausgewählten Buch-IDs.
    const SELECTION = "SEL";
    //! Flache Map bookId -> "segIdx|sekunden|zeitstempel".
    const PROGRESS = "PRG";
    //! Schemaversion; ändert sie sich, wird der Store verworfen.
    const SCHEMA = "VER";
    //! Buch, das der Player gerade abspielt.
    const CURRENT = "CUR";
    //! Bücher, von denen Segmente auf der Uhr liegen.
    //!
    //! Application.Storage kann seine Schlüssel nicht aufzählen. Ohne diese
    //! Liste wäre ein abgewähltes Buch nicht mehr auffindbar und seine
    //! Segmente blieben für immer im Media-Cache liegen.
    const KNOWN = "KNW";

    //! Präfix: Map refId -> "segIdx|dauer" für ein Buch.
    const LOCAL_PREFIX = "L_";
    //! Präfix: "titel|autor|segmentanzahl" für ein Buch.
    const BOOK_PREFIX = "B_";

    //! Beim Erhöhen wird der Store beim nächsten Start geleert.
    const SCHEMA_VERSION = 1;

    function local(bookId as String) as String {
        return LOCAL_PREFIX + bookId;
    }

    function book(bookId as String) as String {
        return BOOK_PREFIX + bookId;
    }
}

//! Namen der App-Einstellungen aus resources/settings/properties.xml.
module Settings {
    const PROXY_URL = "proxyUrl";
    const PROXY_TOKEN = "proxyToken";
    const DELETE_FINISHED = "deleteFinished";
}
