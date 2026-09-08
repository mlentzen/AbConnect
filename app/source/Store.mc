import Toybox.Application;
import Toybox.Lang;
import Toybox.Media;
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

    //! Discard everything the app has put on the watch.
    //!
    //! The media cache cannot be cleaned selectively: resetContentCache()
    //! throws it away along with its encryption key. That is exactly what is
    //! wanted here — orphaned segments the store no longer knows an ID for
    //! cannot be got rid of any other way.
    //!
    //! The buffered listening progress is lost with it. Whoever resets wants
    //! precisely that.
    function reset() as Void {
        Media.resetContentCache();
        Application.Storage.clearValues();
        Application.Storage.setValue(Keys.SCHEMA, Keys.SCHEMA_VERSION);
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

    //! The refIds of a book in segment order, gaps left out.
    //!
    //! The Object Store is an unordered map, so entries are placed by their
    //! segment number instead of being sorted — Monkey C has no Array.sort.
    //! Both the player and the chapter menu walk the book in this order; it
    //! lives here so the two can never disagree about what segment 3 is.
    function orderedRefs(bookId as String) as Array {
        var refIds = localTracks(bookId).keys();
        Log.code("Store: entries for the book", refIds.size());
        var highest = -1;
        var indices = [] as Array<Number>;

        for (var i = 0; i < refIds.size(); ++i) {
            var parts = trackInfo(bookId, refIds[i]);
            var index = (parts == null) ? -1 : toNumber(parts[0]);
            indices.add(index);
            // The raw row, before any ordering. If the result comes out shorter
            // than expected, the reason is one of these lines.
            Log.detail(
                "store " + Log.describe(refIds[i])
                    + " segment " + index.toString()
                    + " duration " + ((parts == null) ? "?" : parts[1]) + " s"
                    + " title '" + ((parts == null) ? "" : parts[2]) + "'"
            );
            if (parts == null) {
                Log.line("Store: unreadable entry for " + Log.describe(refIds[i]));
            }
            if (index > highest) {
                highest = index;
            }
        }

        var slots = new [highest + 1] as Array;
        for (var i = 0; i < refIds.size(); ++i) {
            var slot = indices[i];
            if (slot >= 0) {
                if (slots[slot] != null) {
                    // Two files claiming the same segment: the second wins and
                    // the first is silently gone. Not silently, now.
                    Log.line(
                        "Store: segment " + slot.toString() + " claimed twice, "
                            + Log.describe(slots[slot]) + " replaced by " + Log.describe(refIds[i])
                    );
                }
                slots[slot] = refIds[i];
            }
        }

        var ordered = [] as Array;
        for (var slot = 0; slot < slots.size(); ++slot) {
            if (slots[slot] == null) {
                // A hole in the numbering: that segment never made it onto the
                // watch. Everything after it moves up without a word otherwise.
                Log.code("Store: no file for segment", slot);
            } else {
                ordered.add(slots[slot]);
            }
        }
        Log.line(
            "Store: " + ordered.size().toString()
                + " of " + slots.size().toString() + " segments present"
        );
        return ordered;
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

    // --- Is the player playing? -------------------------------------------

    //! How long a "playing" mark is believed without being refreshed.
    //!
    //! The position ticker refreshes it every 30 seconds, so a live player
    //! keeps it fresh with room to spare. Nothing else can clear it when an app
    //! is killed mid-chapter, and after this long a stale mark is more likely
    //! than a listener who has heard nothing move for five minutes.
    const PLAYING_TRUSTED_SECONDS = 300;

    //! The configuration view runs as its own app instance and cannot ask the
    //! player anything. Without this mark, a push that stops playback to free
    //! the radio would not know whether there is anything to start again.
    function markPlaying() as Void {
        Application.Storage.setValue(Keys.PLAYING, Time.now().value());
    }

    function stoppedPlaying() as Void {
        Application.Storage.deleteValue(Keys.PLAYING);
    }

    function isPlaying() as Boolean {
        var stored = Application.Storage.getValue(Keys.PLAYING);
        if (!(stored instanceof Number)) {
            return false;
        }
        var age = Time.now().value() - stored;
        if (age > PLAYING_TRUSTED_SECONDS) {
            Log.code("Store: a playing mark this old is not believed", age);
            return false;
        }
        return true;
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
