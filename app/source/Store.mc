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
    //! wanted here. Orphaned segments the store no longer knows an ID for
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
    //! playlist must never pass as an empty target. Otherwise the next sync
    //! wipes the watch.
    function setDesired(ids as Array<String>) as Void {
        Application.Storage.setValue(Keys.DESIRED, ids);
        Application.Storage.setValue(Keys.LAST_CHECK, Time.now().value());
    }

    //! Remember the server playlist so Info and the Books page can show it
    //! without opening sync configuration. Title is last because it may contain "|".
    function rememberPlaylist(books as Array) as Void {
        var rows = [] as Array<String>;
        var ids = [] as Array<String>;
        for (var i = 0; i < books.size(); ++i) {
            var book = books[i];
            if (!(book instanceof Dictionary)) {
                continue;
            }
            var id = book["id"];
            if (!(id instanceof String)) {
                continue;
            }
            var status = book["status"];
            var percent = book["percent"];
            var title = book["title"];
            rows.add(
                (id as String)
                    + "|" + ((status instanceof String) ? status as String : "")
                    + "|" + ((percent instanceof Number) ? (percent as Number).toString() : "")
                    + "|" + ((title instanceof String) ? title as String : "")
            );
            ids.add(id as String);
        }
        Application.Storage.setValue(Keys.PLAYLIST, rows);
        setDesired(ids);
    }

    //! [id, status, percent, title] of one stored playlist row.
    function playlistEntry(row as String) as Array<String> {
        var parts = split(row, "|");
        var title = "";
        for (var i = 3; i < parts.size(); ++i) {
            if (i > 3) {
                title += "|";
            }
            title += parts[i];
        }
        return [
            (parts.size() > 0) ? parts[0] : "",
            (parts.size() > 1) ? parts[1] : "",
            (parts.size() > 2) ? parts[2] : "",
            title
        ] as Array<String>;
    }

    function playlistRows() as Array<String> {
        var stored = Application.Storage.getValue(Keys.PLAYLIST);
        if (stored instanceof Array) {
            return stored as Array<String>;
        }
        return [] as Array<String>;
    }

    //! [books in the playlist, books not on the watch yet].
    //!
    //! Without a fetched playlist, the books already stored are the whole count
    //! and nothing is waiting.
    function playlistCounts() as Array<Number> {
        var rows = playlistRows();
        var total = rows.size();
        var waiting = 0;
        if (total == 0) {
            var ids = desired();
            total = ids.size();
            for (var i = 0; i < ids.size(); ++i) {
                if (!onWatch(ids[i], 0)) {
                    waiting += 1;
                }
            }
            if (total == 0) {
                return [localBooks().size(), 0] as Array<Number>;
            }
            return [total, waiting] as Array<Number>;
        }
        for (var i = 0; i < rows.size(); ++i) {
            var id = playlistEntry(rows[i])[0];
            if (id.length() == 0 || !onWatch(id, 0)) {
                waiting += 1;
            }
        }
        return [total, waiting] as Array<Number>;
    }

    function lastCheck() as Number {
        var stored = Application.Storage.getValue(Keys.LAST_CHECK);
        if (stored instanceof Number) {
            return stored;
        }
        return 0;
    }

    // --- Local inventory -----------------------------------------------------

    //! How many tracks go into one stored map. The watch rejected a single map
    //! at about sixty segments (System Error in setValue), which killed the
    //! sync before the remaining books were reached.
    const TRACKS_PER_CHUNK = 16;
    const MAX_TRACK_CHUNKS = 40;

    function readChunk(bookId as String, chunk as Number) as Dictionary? {
        var stored = Application.Storage.getValue(Keys.localChunk(bookId, chunk));
        if (stored instanceof Dictionary) {
            return stored;
        }
        return null;
    }

    function writeChunk(bookId as String, chunk as Number, tracks as Dictionary) as Boolean {
        try {
            Application.Storage.setValue(Keys.localChunk(bookId, chunk), tracks);
            return true;
        } catch (ex) {
            Log.error("Store: segment did not fit for " + bookId);
            return false;
        }
    }

    //! Map refId -> "segIdx|duration|title" for a book, across every chunk.
    function localTracks(bookId as String) as Dictionary {
        var merged = {};
        for (var chunk = 0; chunk < MAX_TRACK_CHUNKS; ++chunk) {
            var stored = readChunk(bookId, chunk);
            if (stored == null) {
                break;
            }
            var ids = stored.keys();
            for (var i = 0; i < ids.size(); ++i) {
                merged[ids[i]] = stored[ids[i]];
            }
        }
        return merged;
    }

    //! False when the store refused the write. The caller keeps syncing.
    function addLocalTrack(
        bookId as String, refId as Object, segment as Number, duration as Number, title as String
    ) as Boolean {
        remember(bookId);
        var record = segment.toString() + "|" + duration.toString() + "|" + title;
        var open = -1;
        for (var chunk = 0; chunk < MAX_TRACK_CHUNKS; ++chunk) {
            var stored = readChunk(bookId, chunk);
            if (stored == null) {
                if (open < 0) {
                    open = chunk;
                }
                break;
            }
            if (stored[refId] != null) {
                stored[refId] = record;
                return writeChunk(bookId, chunk, stored);
            }
            if (open < 0 && stored.size() < TRACKS_PER_CHUNK) {
                open = chunk;
            }
        }
        if (open < 0) {
            Log.error("Store: no room left in " + bookId);
            return false;
        }
        var tracks = readChunk(bookId, open);
        if (tracks == null) {
            tracks = {};
        }
        tracks[refId] = record;
        return writeChunk(bookId, open, tracks);
    }

    //! [segIdx, duration, title] of a local track, or null.
    function trackInfo(bookId as String, refId as Object) as Array<String>? {
        for (var chunk = 0; chunk < MAX_TRACK_CHUNKS; ++chunk) {
            var stored = readChunk(bookId, chunk);
            if (stored == null) {
                break;
            }
            var value = stored[refId];
            if (value instanceof String) {
                var parts = split(value, "|");
                if (parts.size() < 3) {
                    return null;
                }
                return parts;
            }
        }
        return null;
    }

    //! The refIds of a book in segment order, gaps left out.
    //!
    //! The Object Store is an unordered map, so entries are placed by their
    //! segment number instead of being sorted. Monkey C has no Array.sort.
    //! Both the player and the chapter menu walk the book in this order; it
    //! lives here so the two can never disagree about what segment 3 is.
    function orderedRefs(bookId as String) as Array {
        var refIds = localTracks(bookId).keys();
        Log.debugCode("Store: entries for the book", refIds.size());
        var highest = -1;
        var indices = [] as Array<Number>;

        for (var i = 0; i < refIds.size(); ++i) {
            var parts = trackInfo(bookId, refIds[i]);
            var index = (parts == null) ? -1 : toNumber(parts[0]);
            indices.add(index);
            // Guarded: Monkey C builds the message even when nothing prints it,
            // and this loop runs once per segment.
            if (Log.LEVEL >= Log.DEBUG) {
                Log.debug(
                    "store " + Log.describe(refIds[i])
                        + " segment " + index.toString()
                        + " duration " + ((parts == null) ? "?" : parts[1]) + " s"
                        + " title '" + ((parts == null) ? "" : parts[2]) + "'"
                );
            }
            if (parts == null) {
                Log.error("Store: unreadable entry for " + Log.describe(refIds[i]));
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
                    // Two files claim the same segment: the second wins.
                    Log.warn(
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
                Log.warnCode("Store: no file for segment", slot);
            } else {
                ordered.add(slots[slot]);
            }
        }
        if (ordered.size() < slots.size()) {
            // Fewer files than segment numbers: the book has gaps, and that is
            // the reason a chapter goes missing mid-listen.
            Log.warn(
                "Store: only " + ordered.size().toString()
                    + " of " + slots.size().toString() + " segments present"
            );
        } else {
            Log.debugCode("Store: segments present", ordered.size());
        }
        return ordered;
    }

    function forgetBook(bookId as String) as Void {
        for (var chunk = 0; chunk < MAX_TRACK_CHUNKS; ++chunk) {
            var key = Keys.localChunk(bookId, chunk);
            if (Application.Storage.getValue(key) == null) {
                if (chunk > 0) {
                    break;
                }
                continue;
            }
            Application.Storage.deleteValue(key);
        }
        Application.Storage.deleteValue(Keys.book(bookId));
        var known = knownBooks();
        if (known.indexOf(bookId) >= 0) {
            known.remove(bookId);
            Application.Storage.setValue(Keys.KNOWN, known);
        }
    }

    //! All books that have segments on the watch, including deselected ones.
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

    //! Books whose every segment is stored. A partial download is not on the watch.
    function localBooks() as Array<String> {
        var books = [] as Array<String>;
        var ids = knownBooks();
        for (var i = 0; i < ids.size(); ++i) {
            if (onWatch(ids[i], 0)) {
                books.add(ids[i]);
            }
        }
        return books;
    }

    //! True when at least as many segments are stored as the book is supposed to have.
    //!
    //! The menu calls this once per playlist row. Walking every segment and
    //! splitting its record trips the watchdog ("Code Executed Too Long"),
    //! so this only counts entries. expectedHint is the server's segment
    //! count when the caller has it. The stored book info is used as well,
    //! and the larger of the two wins, so a short local list cannot pass
    //! for a finished book. A count of 0 means the length is not known yet,
    //! and the book stays off the watch.
    function onWatch(bookId as String, expectedHint as Number) as Boolean {
        var expected = toNumber(bookInfo(bookId)[2]);
        if (expectedHint > expected) {
            expected = expectedHint;
        }
        if (expected <= 0) {
            return false;
        }
        var count = 0;
        for (var chunk = 0; chunk < MAX_TRACK_CHUNKS; ++chunk) {
            var stored = readChunk(bookId, chunk);
            if (stored == null) {
                break;
            }
            count += stored.size();
            if (count >= expected) {
                return true;
            }
        }
        return false;
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

    //! Every stored position in the shape that /v1/progress expects, pending
    //! or not. pendingEntries() and syncEntries() build on it, so the three
    //! paths that push can never disagree about the shape.
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

    // --- The manual sync ticket --------------------------------------------

    //! How long a manual sync request is believed.
    //!
    //! startSync() ends the app and relaunches it in sync mode; the ticket is
    //! how isSyncNeeded() can still tell that this sync was asked for by hand.
    //! The relaunch takes seconds, so anything older is a leftover from an
    //! attempt that never made it into sync mode, and must not bless a later
    //! sync the system started on its own.
    const SYNC_REQUEST_TRUSTED_SECONDS = 120;

    //! The Download books row's half of the ticket, stamped just before
    //! startSync2().
    function requestSync() as Void {
        Application.Storage.setValue(Keys.SYNC_REQUEST, Time.now().value());
    }

    //! isSyncNeeded()'s half: true only while a manual request is fresh.
    function syncRequested() as Boolean {
        var stamped = Application.Storage.getValue(Keys.SYNC_REQUEST);
        if (!(stamped instanceof Number)) {
            return false;
        }
        var age = Time.now().value() - stamped;
        if (age > SYNC_REQUEST_TRUSTED_SECONDS) {
            Log.warnCode("Store: a sync ticket this old is not believed", age);
            return false;
        }
        return true;
    }

    //! Once the sync is actually running the ticket is spent: whatever the
    //! system asks later must be decided without it.
    function clearSyncRequest() as Void {
        Application.Storage.deleteValue(Keys.SYNC_REQUEST);
    }

    //! A stop this soon after a restart is the same Back press arriving again.
    const RESUME_ECHO_SECONDS = 3;
    //! After a restart, a second stop inside this window is the user cancelling.
    //! A later stop is treated as a notification dismiss and the sync restarts.
    const RESUME_CANCEL_WINDOW_SECONDS = 20;
    //! Restarts of one dismiss. Past this the restart gives up, so a Back press
    //! the system keeps repeating cannot loop forever.
    const RESUME_ECHO_LIMIT = 2;

    //! Record a restart. The count grows only inside the echo window and
    //! starts over after it, so a later dismiss is a new case.
    function noteResume() as Number {
        var now = Time.now().value();
        var count = 1;
        var existing = Application.Storage.getValue(Keys.SYNC_RESUME);
        if (existing instanceof Array && existing.size() >= 2) {
            var stamped = existing[0];
            var previous = existing[1];
            if (stamped instanceof Number && previous instanceof Number) {
                if (now - stamped < RESUME_ECHO_SECONDS) {
                    count = previous + 1;
                }
            }
        }
        try {
            Application.Storage.setValue(Keys.SYNC_RESUME, [now, count]);
        } catch (ex) {
            Log.error("Store: resume stamp did not fit");
        }
        return count;
    }

    //! True when this stop is a second Back soon after a restart.
    function resumeWasCancelled() as Boolean {
        var existing = Application.Storage.getValue(Keys.SYNC_RESUME);
        if (!(existing instanceof Array) || existing.size() < 1) {
            return false;
        }
        var stamped = existing[0];
        if (!(stamped instanceof Number)) {
            return false;
        }
        var age = Time.now().value() - stamped;
        return age >= RESUME_ECHO_SECONDS && age < RESUME_CANCEL_WINDOW_SECONDS;
    }

    function clearResume() as Void {
        Application.Storage.deleteValue(Keys.SYNC_RESUME);
    }

    //! A day, for the plugged-in sync. A manual request is not limited by this.
    const DAY_SECONDS = 86400;

    //! True when no plugged-in sync has started in the last day.
    function dailySyncDue() as Boolean {
        var stamped = Application.Storage.getValue(Keys.LAST_AUTO_SYNC);
        if (!(stamped instanceof Number)) {
            return true;
        }
        return Time.now().value() - stamped >= DAY_SECONDS;
    }

    //! Called when a plugged-in sync starts, so a later check the same day
    //! does not start another. A manual sync does not call this.
    function noteDailySync() as Void {
        Application.Storage.setValue(Keys.LAST_AUTO_SYNC, Time.now().value());
    }

    //! The server now holds this position: keep it, stop reporting it.
    //!
    //! The position is kept with timestamp 0, the mark for "same as the
    //! server" (also used for positions adopted from it). Only while the stored
    //! stamp is still the one that was sent: a position written while the
    //! request was out stays pending.
    function markSynced(bookId as String, sentTs as Number) as Void {
        var spot = position(bookId);
        if (spot == null || sentTs == 0 || spot[2] != sentTs) {
            return;
        }
        rememberPosition(bookId, spot[0], spot[1], 0);
    }

    //! The positions the server has not confirmed yet: listened to here, with
    //! a real timestamp. What the pause push sends and what "waiting" counts.
    function pendingEntries() as Array<Dictionary> {
        var pending = [] as Array<Dictionary>;
        var entries = progressEntries();
        for (var i = 0; i < entries.size(); ++i) {
            if ((entries[i]["ts"] as Number) > 0) {
                pending.add(entries[i]);
            }
        }
        return pending;
    }

    //! Everything the watch knows, plus a question about each of these books.
    //!
    //! /v1/progress only answers about the books it was sent, so a book with
    //! nothing stored is sent with timestamp 0. The newer timestamp wins, so
    //! this report loses and the server's position comes back.
    function syncEntries(bookIds as Array<String>) as Array<Dictionary> {
        var entries = progressEntries();
        for (var i = 0; i < bookIds.size(); ++i) {
            if (position(bookIds[i]) != null) {
                continue;
            }
            Log.debug("Store: asking about " + bookIds[i] + " with nothing of our own");
            entries.add({
                "book_id" => bookIds[i],
                "segment" => 0,
                "offset" => 0,
                "ts" => 0
            });
        }
        return entries;
    }

    //! The book that "Continue" offers, or null when there is nothing to carry
    //! on with.
    //!
    //! Current.bookId() is what the player last opened, and it is the answer
    //! whenever it still means anything, but it can name a book that has since
    //! left the playlist and been deleted from the watch, so it only counts
    //! while segments of it are still here.
    //!
    //! Failing that, the newest position stamped on this watch. Positions at
    //! timestamp 0 agree with the server (see Progress.settle) and may be where
    //! the phone got to, and being told that is not the same as having
    //! listened here.
    function resumableBook() as String? {
        var current = Current.bookId();
        if (current != null && localTracks(current).size() > 0) {
            return current;
        }
        var best = null as String?;
        var bestStamp = 0;
        var bookIds = progress().keys();
        for (var i = 0; i < bookIds.size(); ++i) {
            var bookId = bookIds[i];
            if (!(bookId instanceof String) || localTracks(bookId).size() == 0) {
                continue;
            }
            var spot = position(bookId);
            if (spot != null && spot[2] > bestStamp) {
                best = bookId;
                bestStamp = spot[2];
            }
        }
        return best;
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
