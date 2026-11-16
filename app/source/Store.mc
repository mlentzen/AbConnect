import Toybox.Application;
import Toybox.Lang;
import Toybox.Media;
import Toybox.Time;

module Store {

    const TRACKS_PER_CHUNK = 16;
    const MAX_TRACK_CHUNKS = 40;
    const SYNC_REQUEST_TRUSTED_SECONDS = 120;
    const RESUME_ECHO_SECONDS = 3;
    const RESUME_CANCEL_WINDOW_SECONDS = 20;
    const RESUME_ECHO_LIMIT = 2;

    const SEG_REF = 0;
    const SEG_INDEX = 1;
    const SEG_DURATION = 2;
    const SEG_TITLE = 3;
    const MAX_SEGMENTS = TRACKS_PER_CHUNK * MAX_TRACK_CHUNKS;

    function checkSchema() as Void {
        var version = Application.Storage.getValue(Keys.SCHEMA);
        if (!(version instanceof Number) || version != Keys.SCHEMA_VERSION) {
            try {
                Media.resetContentCache();
            } catch (ex) {
                Log.error("Store: media cache could not be reset");
            }
            Application.Storage.clearValues();
            Application.Storage.setValue(Keys.SCHEMA, Keys.SCHEMA_VERSION);
        }
    }

    function reset() as Void {
        Media.resetContentCache();
        Application.Storage.clearValues();
        Application.Storage.setValue(Keys.SCHEMA, Keys.SCHEMA_VERSION);
    }

    function put(key as String, value as Application.PersistableType) as Boolean {
        try {
            Application.Storage.setValue(key, value);
            return true;
        } catch (ex) {
            Log.error("Store: write refused for " + key);
            return false;
        }
    }

    function now() as Number {
        return Time.now().value();
    }

    function arrayAt(key as String) as Array {
        var stored = Application.Storage.getValue(key);
        if (stored instanceof Array) {
            return stored;
        }
        return [] as Array;
    }

    function desired() as Array<String> {
        return arrayAt(Keys.DESIRED) as Array<String>;
    }

    function rememberPlaylist(books as Array) as Void {
        var rows = [] as Array<String>;
        var ids = [] as Array<String>;
        for (var i = 0; i < books.size(); ++i) {
            var book = books[i];
            if (!(book instanceof Dictionary)) {
                continue;
            }
            var id = book["id"];
            if (!(id instanceof String) || !Util.isSafeId(id)) {
                continue;
            }
            var percent = book["percent"];
            rows.add(
                id
                    + "|" + Util.withoutSeparator(Util.stringOr(book["status"], ""))
                    + "|" + ((percent instanceof Number) ? percent.toString() : "")
                    + "|" + Util.stringOr(book["title"], "")
            );
            ids.add(id);
        }
        put(Keys.PLAYLIST, rows);
        put(Keys.DESIRED, ids);
        put(Keys.LAST_CHECK, now());
    }

    function playlistEntry(row as String) as Array<String> {
        var parts = Util.split(row, "|");
        var entry = ["", "", "", ""] as Array<String>;
        for (var i = 0; i < parts.size(); ++i) {
            if (i < 3) {
                entry[i] = parts[i];
            } else {
                entry[3] = (i == 3) ? parts[i] : entry[3] + "|" + parts[i];
            }
        }
        return entry;
    }

    function playlistRows() as Array<String> {
        return arrayAt(Keys.PLAYLIST) as Array<String>;
    }

    function playlistCounts() as Array<Number> {
        var ids = [] as Array<String>;
        var rows = playlistRows();
        for (var i = 0; i < rows.size(); ++i) {
            ids.add(playlistEntry(rows[i])[0]);
        }
        if (ids.size() == 0) {
            ids = desired();
        }
        if (ids.size() == 0) {
            return [localBooks().size(), 0] as Array<Number>;
        }
        var waiting = 0;
        for (var i = 0; i < ids.size(); ++i) {
            if (ids[i].length() == 0 || !onWatch(ids[i], 0)) {
                waiting += 1;
            }
        }
        return [ids.size(), waiting] as Array<Number>;
    }

    function lastCheck() as Number {
        var stored = Application.Storage.getValue(Keys.LAST_CHECK);
        return (stored instanceof Number) ? stored : 0;
    }

    function readChunk(bookId as String, chunk as Number) as Dictionary? {
        var stored = Application.Storage.getValue(Keys.localChunk(bookId, chunk));
        return (stored instanceof Dictionary) ? stored : null;
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

    function allChunks(bookId as String) as Array<Dictionary> {
        var chunks = [] as Array<Dictionary>;
        for (var chunk = 0; chunk < MAX_TRACK_CHUNKS; ++chunk) {
            var stored = readChunk(bookId, chunk);
            if (stored == null) {
                break;
            }
            chunks.add(stored);
        }
        return chunks;
    }

    function hasTracks(bookId as String) as Boolean {
        for (var chunk = 0; chunk < MAX_TRACK_CHUNKS; ++chunk) {
            var stored = readChunk(bookId, chunk);
            if (stored == null) {
                return false;
            }
            if (stored.size() > 0) {
                return true;
            }
        }
        return false;
    }

    function localTracks(bookId as String) as Dictionary {
        var merged = {};
        var chunks = allChunks(bookId);
        for (var c = 0; c < chunks.size(); ++c) {
            var ids = chunks[c].keys();
            for (var i = 0; i < ids.size(); ++i) {
                merged[ids[i]] = chunks[c][ids[i]];
            }
        }
        return merged;
    }

    function addLocalTrack(
        bookId as String, refId as Object, segment as Number, duration as Number, title as String
    ) as Boolean {
        remember(bookId);
        var record = segment.toString() + "|" + duration.toString() + "|" + Util.withoutSeparator(title);
        var open = -1;
        var openTracks = {};
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
                openTracks = stored;
            }
        }
        if (open < 0) {
            Log.error("Store: no room left in " + bookId);
            return false;
        }
        openTracks[refId] = record;
        return writeChunk(bookId, open, openTracks);
    }

    function dropLocalTrack(bookId as String, refId as Object) as Void {
        for (var chunk = 0; chunk < MAX_TRACK_CHUNKS; ++chunk) {
            var stored = readChunk(bookId, chunk);
            if (stored == null) {
                return;
            }
            if (stored[refId] != null) {
                stored.remove(refId);
                writeChunk(bookId, chunk, stored);
                return;
            }
        }
    }

    function localSegmentFacts(bookId as String) as Array<Array> {
        var facts = [] as Array<Array>;
        var chunks = allChunks(bookId);
        for (var c = 0; c < chunks.size(); ++c) {
            var ids = chunks[c].keys();
            for (var i = 0; i < ids.size(); ++i) {
                var value = chunks[c][ids[i]];
                var parts = (value instanceof String) ? Util.split(value, "|") : null;
                if (parts == null || parts.size() < 3) {
                    Log.error("Store: unreadable entry for " + Log.describe(ids[i]));
                    continue;
                }
                facts.add([ids[i], Util.toNumber(parts[0]), Util.toNumber(parts[1]), parts[2]] as Array);
            }
        }
        return facts;
    }

    function trackInfo(bookId as String, refId as Object) as Array<String>? {
        for (var chunk = 0; chunk < MAX_TRACK_CHUNKS; ++chunk) {
            var stored = readChunk(bookId, chunk);
            if (stored == null) {
                return null;
            }
            var value = stored[refId];
            if (value instanceof String) {
                var parts = Util.split(value, "|");
                return (parts.size() < 3) ? null : parts;
            }
        }
        return null;
    }

    function segmentTimes(bookId as String, segment as Number) as Array<Number> {
        var before = 0;
        var total = 0;
        for (var chunk = 0; chunk < MAX_TRACK_CHUNKS; ++chunk) {
            var stored = readChunk(bookId, chunk);
            if (stored == null) {
                break;
            }
            var records = stored.values();
            for (var i = 0; i < records.size(); ++i) {
                var record = records[i];
                if (!(record instanceof String)) {
                    continue;
                }
                var first = record.find("|");
                if (first == null) {
                    continue;
                }
                var rest = record.substring(first + 1, record.length()) as String;
                var second = rest.find("|");
                if (second == null) {
                    continue;
                }
                var duration = Util.toNumber(rest.substring(0, second) as String);
                total += duration;
                if (Util.toNumber(record.substring(0, first) as String) < segment) {
                    before += duration;
                }
            }
        }
        return [before, total] as Array<Number>;
    }

    function segmentStarts(segments as Array<Array>) as Array<Number> {
        var starts = [] as Array<Number>;
        var total = 0;
        for (var i = 0; i < segments.size(); ++i) {
            starts.add(total);
            total += segments[i][SEG_DURATION] as Number;
        }
        starts.add(total);
        return starts;
    }

    function orderedSegments(bookId as String) as Array<Array> {
        var facts = localSegmentFacts(bookId);
        var highest = -1;
        for (var i = 0; i < facts.size(); ++i) {
            var index = facts[i][SEG_INDEX] as Number;
            if (index > highest && index < MAX_SEGMENTS) {
                highest = index;
            }
        }
        var slots = new [highest + 1] as Array;
        for (var i = 0; i < facts.size(); ++i) {
            var slot = facts[i][SEG_INDEX] as Number;
            if (slot >= 0 && slot < slots.size()) {
                slots[slot] = facts[i];
            }
        }
        var ordered = [] as Array<Array>;
        for (var slot = 0; slot < slots.size(); ++slot) {
            if (slots[slot] != null) {
                ordered.add(slots[slot] as Array);
            }
        }
        if (ordered.size() < slots.size()) {
            Log.warn(
                "Store: only " + ordered.size().toString()
                    + " of " + slots.size().toString() + " segments present"
            );
        }
        return ordered;
    }

    function forgetBook(bookId as String) as Void {
        for (var chunk = 0; chunk < MAX_TRACK_CHUNKS; ++chunk) {
            var key = Keys.localChunk(bookId, chunk);
            if (Application.Storage.getValue(key) != null) {
                Application.Storage.deleteValue(key);
            } else if (chunk > 0) {
                break;
            }
        }
        Application.Storage.deleteValue(Keys.book(bookId));
        if (bookId.equals(Current.bookId())) {
            Current.clear();
        }
        var known = knownBooks();
        if (known.indexOf(bookId) >= 0) {
            known.remove(bookId);
            put(Keys.KNOWN, known);
        }
    }

    function knownBooks() as Array<String> {
        return arrayAt(Keys.KNOWN) as Array<String>;
    }

    function remember(bookId as String) as Void {
        var known = knownBooks();
        if (known.indexOf(bookId) < 0) {
            known.add(bookId);
            put(Keys.KNOWN, known);
        }
    }

    function setBookInfo(bookId as String, title as String, author as String, segments as Number) as Void {
        put(
            Keys.book(bookId),
            Util.withoutSeparator(title) + "|" + Util.withoutSeparator(author) + "|" + segments.toString()
        );
    }

    function bookInfo(bookId as String) as Array<String> {
        var stored = Application.Storage.getValue(Keys.book(bookId));
        if (stored instanceof String) {
            var parts = Util.split(stored, "|");
            if (parts.size() >= 3) {
                return parts;
            }
        }
        return ["", "", "0"] as Array<String>;
    }

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

    function onWatch(bookId as String, expectedHint as Number) as Boolean {
        var expected = Util.toNumber(bookInfo(bookId)[2]);
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
                return false;
            }
            count += stored.size();
            if (count >= expected) {
                return true;
            }
        }
        return false;
    }

    function progress() as Dictionary {
        var stored = Application.Storage.getValue(Keys.PROGRESS);
        return (stored instanceof Dictionary) ? stored : {};
    }

    function rememberPosition(bookId as String, segment as Number, seconds as Number, timestamp as Number) as Void {
        var all = progress();
        all[bookId] = segment.toString() + "|" + seconds.toString() + "|" + timestamp.toString();
        put(Keys.PROGRESS, all);
    }

    function position(bookId as String) as Array<Number>? {
        var stored = progress()[bookId];
        if (!(stored instanceof String)) {
            return null;
        }
        var parts = Util.split(stored, "|");
        if (parts.size() < 3) {
            return null;
        }
        return [Util.toNumber(parts[0]), Util.toNumber(parts[1]), Util.toNumber(parts[2])] as Array<Number>;
    }

    function notePlayed(bookId as String, segment as Number, seconds as Number, timestamp as Number) as Void {
        put(Keys.LAST_PLAYED, [bookId, timestamp, segment, seconds] as Array);
    }

    function idleSecondsAt(bookId as String, segment as Number, seconds as Number) as Number? {
        var stored = Application.Storage.getValue(Keys.LAST_PLAYED);
        if (!(stored instanceof Array) || stored.size() < 4) {
            return null;
        }
        if (!bookId.equals(stored[0]) || stored[2] != segment || stored[3] != seconds) {
            return null;
        }
        var stamp = stored[1];
        if (!(stamp instanceof Number)) {
            return null;
        }
        var idle = now() - stamp;
        return (idle < 0) ? null : idle;
    }

    function markSynced(bookId as String, sentTs as Number) as Void {
        var spot = position(bookId);
        if (spot == null || sentTs == 0 || spot[2] != sentTs) {
            return;
        }
        rememberPosition(bookId, spot[0], spot[1], 0);
    }

    function pruneProgress(wanted as Array<String>, present as Array<String>) as Void {
        var all = progress();
        var bookIds = all.keys();
        var removed = 0;
        for (var i = 0; i < bookIds.size(); ++i) {
            var bookId = bookIds[i];
            if (!(bookId instanceof String) || wanted.indexOf(bookId) >= 0 || present.indexOf(bookId) >= 0) {
                continue;
            }
            var spot = position(bookId);
            if (spot != null && spot[2] > 0) {
                continue;
            }
            all.remove(bookId);
            removed += 1;
        }
        if (removed > 0) {
            put(Keys.PROGRESS, all);
            Log.code("Store: dropped progress entries", removed);
        }
    }

    function progressEntry(bookId as String, segment as Number, offset as Number, ts as Number) as Dictionary {
        return { "book_id" => bookId, "segment" => segment, "offset" => offset, "ts" => ts };
    }

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
                entries.add(progressEntry(bookId, spot[0], spot[1], spot[2]));
            }
        }
        return entries;
    }

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

    function syncEntries(bookIds as Array<String>) as Array<Dictionary> {
        var entries = progressEntries();
        for (var i = 0; i < bookIds.size(); ++i) {
            if (position(bookIds[i]) == null) {
                Log.debug("Store: asking about " + bookIds[i] + " with nothing of our own");
                entries.add(progressEntry(bookIds[i], 0, 0, 0));
            }
        }
        return entries;
    }

    function resumableBook() as String? {
        var current = Current.bookId();
        if (current != null && hasTracks(current)) {
            return current;
        }
        var best = null as String?;
        var bestStamp = -1;
        var bookIds = progress().keys();
        for (var i = 0; i < bookIds.size(); ++i) {
            var bookId = bookIds[i];
            if (!(bookId instanceof String) || !hasTracks(bookId)) {
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

    function requestSync() as Void {
        put(Keys.SYNC_REQUEST, now());
    }

    function syncRequested() as Boolean {
        var stamped = Application.Storage.getValue(Keys.SYNC_REQUEST);
        if (!(stamped instanceof Number)) {
            return false;
        }
        var age = now() - stamped;
        if (age > SYNC_REQUEST_TRUSTED_SECONDS) {
            Log.warnCode("Store: a sync ticket this old is not believed", age);
            return false;
        }
        return true;
    }

    function clearSyncRequest() as Void {
        Application.Storage.deleteValue(Keys.SYNC_REQUEST);
    }

    function noteSyncResult(error as String?) as Void {
        put(Keys.LAST_SYNC, [now(), error] as Array);
    }

    function lastSyncResult() as Array? {
        var stored = Application.Storage.getValue(Keys.LAST_SYNC);
        if (stored instanceof Array && stored.size() >= 2 && stored[0] instanceof Number) {
            return stored;
        }
        return null;
    }

    function noteResume() as Number {
        var stamp = now();
        var count = 1;
        var existing = Application.Storage.getValue(Keys.SYNC_RESUME);
        if (existing instanceof Array && existing.size() >= 2) {
            var stamped = existing[0];
            var previous = existing[1];
            if (stamped instanceof Number && previous instanceof Number && stamp - stamped < RESUME_ECHO_SECONDS) {
                count = previous + 1;
            }
        }
        try {
            Application.Storage.setValue(Keys.SYNC_RESUME, [stamp, count]);
        } catch (ex) {
            Log.error("Store: resume stamp did not fit");
        }
        return count;
    }

    function resumeWasCancelled() as Boolean {
        var existing = Application.Storage.getValue(Keys.SYNC_RESUME);
        if (!(existing instanceof Array) || existing.size() < 1 || !(existing[0] instanceof Number)) {
            return false;
        }
        var age = now() - (existing[0] as Number);
        return age >= RESUME_ECHO_SECONDS && age < RESUME_CANCEL_WINDOW_SECONDS;
    }

    function clearResume() as Void {
        Application.Storage.deleteValue(Keys.SYNC_RESUME);
    }
}

module Current {
    function bookId() as String? {
        var stored = Application.Storage.getValue(Keys.CURRENT);
        if (stored instanceof String && stored.length() > 0) {
            return stored;
        }
        return null;
    }

    function set(bookId as String) as Void {
        Store.put(Keys.CURRENT, bookId);
    }

    function clear() as Void {
        Application.Storage.deleteValue(Keys.CURRENT);
    }
}
