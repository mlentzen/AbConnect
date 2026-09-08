import Toybox.Application;
import Toybox.Lang;
import Toybox.Time;

//! Access to the Object Store.
//!
//! All values are deliberately flat: nested dictionaries blow past the 8 KB
//! per-value limit long before a larger library would fit in one.
module Store {

    //! Discards the store if it comes from an older schema version.
    function checkSchema() as Void {
        var version = Application.Storage.getValue(Keys.SCHEMA);
        if (!(version instanceof Number) || version != Keys.SCHEMA_VERSION) {
            Application.Storage.clearValues();
            Application.Storage.setValue(Keys.SCHEMA, Keys.SCHEMA_VERSION);
        }
    }

    // --- Target from the playlist ----------------------------------------

    //! Last known state of the playlist.
    function desired() as Array<String> {
        var stored = Application.Storage.getValue(Keys.DESIRED);
        if (stored instanceof Array) {
            return stored as Array<String>;
        }
        return [] as Array<String>;
    }

    //! Only call after a *successful* query. An unreachable or unfindable
    //! playlist must never pass as an empty target — otherwise the next sync
    //! wipes the watch.
    function setDesired(ids as Array<String>) as Void {
        Application.Storage.setValue(Keys.DESIRED, ids);
        Application.Storage.setValue(Keys.LAST_CHECK, Time.now().value());
    }

    function lastCheck() as Number {
        var stored = Application.Storage.getValue(Keys.LAST_CHECK);
        if (stored instanceof Number) {
            return stored;
        }
        return 0;
    }

    // --- Local inventory -----------------------------------------------------

    //! Map refId -> "segIdx|duration|title" for a book.
    function localTracks(bookId as String) as Dictionary {
        var stored = Application.Storage.getValue(Keys.local(bookId));
        if (stored instanceof Dictionary) {
            return stored;
        }
        return {};
    }

    function addLocalTrack(
        bookId as String, refId as Object, segment as Number, duration as Number, title as String
    ) as Void {
        remember(bookId);
        var tracks = localTracks(bookId);
        tracks[refId] = segment.toString() + "|" + duration.toString() + "|" + title;
        Application.Storage.setValue(Keys.local(bookId), tracks);
    }

    //! [segIdx, duration, title] of a local track, or null.
    function trackInfo(bookId as String, refId as Object) as Array<String>? {
        var stored = localTracks(bookId)[refId];
        if (!(stored instanceof String)) {
            return null;
        }
        var parts = split(stored, "|");
        if (parts.size() < 3) {
            return null;
        }
        return parts;
    }

    function forgetBook(bookId as String) as Void {
        Application.Storage.deleteValue(Keys.local(bookId));
        Application.Storage.deleteValue(Keys.book(bookId));
        var known = knownBooks();
        if (known.indexOf(bookId) >= 0) {
            known.remove(bookId);
            Application.Storage.setValue(Keys.KNOWN, known);
        }
    }

    //! All books that have segments on the watch — including deselected ones.
    function knownBooks() as Array<String> {
        var stored = Application.Storage.getValue(Keys.KNOWN);
        if (stored instanceof Array) {
            return stored as Array<String>;
        }
        return [] as Array<String>;
    }

    function remember(bookId as String) as Void {
        var known = knownBooks();
        if (known.indexOf(bookId) < 0) {
            known.add(bookId);
            Application.Storage.setValue(Keys.KNOWN, known);
        }
    }

    //! Book title, author and segment count in one flat value.
    function setBookInfo(bookId as String, title as String, author as String, segments as Number) as Void {
        Application.Storage.setValue(Keys.book(bookId), title + "|" + author + "|" + segments.toString());
    }

    function bookInfo(bookId as String) as Array<String> {
        var stored = Application.Storage.getValue(Keys.book(bookId));
        if (stored instanceof String) {
            var parts = split(stored, "|");
            if (parts.size() >= 3) {
                return parts;
            }
        }
        return ["", "", "0"] as Array<String>;
    }

    //! Books that have at least one playable segment on the watch.
    function localBooks() as Array<String> {
        var books = [] as Array<String>;
        var ids = knownBooks();
        for (var i = 0; i < ids.size(); ++i) {
            if (localTracks(ids[i]).size() > 0) {
                books.add(ids[i]);
            }
        }
        return books;
    }

    // --- Progress ---------------------------------------------------------

    function progress() as Dictionary {
        var stored = Application.Storage.getValue(Keys.PROGRESS);
        if (stored instanceof Dictionary) {
            return stored;
        }
        return {};
    }

    //! Remember the position. Sent to the proxy on the next sync.
    function rememberPosition(bookId as String, segment as Number, seconds as Number, timestamp as Number) as Void {
        var all = progress();
        all[bookId] = segment.toString() + "|" + seconds.toString() + "|" + timestamp.toString();
        Application.Storage.setValue(Keys.PROGRESS, all);
    }

    //! [segIdx, seconds, timestamp] or null.
    function position(bookId as String) as Array<Number>? {
        var stored = progress()[bookId];
        if (!(stored instanceof String)) {
            return null;
        }
        var parts = split(stored, "|");
        if (parts.size() < 3) {
            return null;
        }
        return [toNumber(parts[0]), toNumber(parts[1]), toNumber(parts[2])] as Array<Number>;
    }

    //! The buffered progress in the shape that /v1/progress expects.
    //! Sync and pause push send the same data — hence here and not twice at
    //! the call sites.
    function progressEntries() as Array<Dictionary> {
        var entries = [] as Array<Dictionary>;
        var bookIds = progress().keys();
        for (var i = 0; i < bookIds.size(); ++i) {
            var bookId = bookIds[i];
            if (!(bookId instanceof String)) {
                continue;
            }
            var spot = position(bookId);
            if (spot != null) {
                entries.add({
                    "book_id" => bookId,
                    "segment" => spot[0],
                    "offset" => spot[1],
                    "ts" => spot[2]
                });
            }
        }
        return entries;
    }

    function clearProgress() as Void {
        Application.Storage.deleteValue(Keys.PROGRESS);
    }

    // --- Helpers --------------------------------------------------------------

    //! String.toNumber() returns null when the value is unreadable. A
    //! corrupted store entry must not take the app down with it.
    function toNumber(value as String) as Number {
        var number = value.toNumber();
        return (number == null) ? 0 : number;
    }

    //! Monkey C has no String.split; the flat values need one.
    function split(value as String, separator as String) as Array<String> {
        var parts = [] as Array<String>;
        var rest = value;
        var cut = rest.find(separator);
        while (cut != null) {
            parts.add(rest.substring(0, cut) as String);
            rest = rest.substring(cut + separator.length(), rest.length()) as String;
            cut = rest.find(separator);
        }
        parts.add(rest);
        return parts;
    }
}

//! The book the player is currently playing.
module Current {
    function bookId() as String? {
        var stored = Application.Storage.getValue(Keys.CURRENT);
        if (stored instanceof String && stored.length() > 0) {
            return stored;
        }
        return null;
    }

    function set(bookId as String) as Void {
        Application.Storage.setValue(Keys.CURRENT, bookId);
    }
}
