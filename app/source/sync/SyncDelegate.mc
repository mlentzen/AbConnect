import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;
import Toybox.Time;
import Toybox.WatchUi;

//! The sync itself.
//!
//! Connect IQ is single-threaded and callback-based — you cannot wait for a
//! response. The flow is therefore a state machine in which each response
//! triggers the next step.
//!
//! Order: release, report progress, fetch books. Progress goes out first so it
//! arrives even when the downloads abort later.
class AbSyncDelegate extends Communications.SyncDelegate {

    private var _client as ProxyClient;
    private var _bookQueue as Array<String>;
    private var _downloads as Array<Dictionary>;
    private var _pending as Dictionary?;
    private var _currentBook as String?;
    private var _booksTotal as Number;
    private var _booksDone as Number;
    private var _downloadsTotal as Number;
    private var _downloadsDone as Number;
    private var _stillPreparing as Number;
    private var _failure as String?;
    private var _stopped as Boolean;

    function initialize() {
        SyncDelegate.initialize();
        _client = new ProxyClient();
        _bookQueue = [] as Array<String>;
        _downloads = [] as Array<Dictionary>;
        _pending = null;
        _currentBook = null;
        _booksTotal = 0;
        _booksDone = 0;
        _downloadsTotal = 0;
        _downloadsDone = 0;
        _stillPreparing = 0;
        _failure = null;
        _stopped = false;
    }

    //! A sync is worthwhile when progress is pending, the last known state of
    //! the playlist does not match the local inventory — or when that state is
    //! simply too old.
    //!
    //! The last point is the important one: without it a book newly added to
    //! the playlist would go unnoticed, because the watch knows nothing about
    //! it while offline.
    function isSyncNeeded() as Boolean {
        Log.code("Sync: playlist state", Store.desired().size());
        Log.code("Sync: known", Store.knownBooks().size());
        if (Store.progress().size() > 0) {
            return true;
        }
        if (Time.now().value() - Store.lastCheck() > Keys.PLAYLIST_MAX_AGE_SECONDS) {
            return true;
        }
        var wanted = Store.desired();
        for (var i = 0; i < wanted.size(); ++i) {
            if (Store.localTracks(wanted[i]).size() == 0) {
                return true;
            }
        }
        return orphans(wanted).size() > 0;
    }

    function onStartSync() as Void {
        Log.line("Sync: onStartSync");
        if (!_client.isConfigured()) {
            Communications.notifySyncComplete("Proxy not configured");
            return;
        }
        // Progress first: it is small and must not get stuck behind an
        // aborting download.
        pushProgress();
    }

    function onStopSync() as Void {
        Log.line("Sync: onStopSync");
        _stopped = true;
        Communications.cancelAllRequests();
        Communications.notifySyncComplete(null);
    }

    // --- Cleanup ------------------------------------------------------------

    //! Books that have segments but are no longer in the playlist.
    private function orphans(wanted as Array<String>) as Array<String> {
        var result = [] as Array<String>;
        var known = Store.knownBooks();
        for (var i = 0; i < known.size(); ++i) {
            if (wanted.indexOf(known[i]) < 0) {
                result.add(known[i]);
            }
        }
        return result;
    }

    private function deleteLocal(bookId as String) as Void {
        var refIds = Store.localTracks(bookId).keys();
        for (var i = 0; i < refIds.size(); ++i) {
            Media.deleteCachedItem(new Media.ContentRef(refIds[i], Media.CONTENT_TYPE_AUDIO));
        }
        Store.forgetBook(bookId);
    }

    // --- Phase 1: report listening progress --------------------------------------

    private function pushProgress() as Void {
        if (_stopped) {
            return;
        }
        var entries = Store.progressEntries();
        Log.code("Sync: progress entries", entries.size());
        if (entries.size() == 0) {
            fetchPlaylist();
            return;
        }
        _client.pushProgress(entries, method(:onProgressPushed));
    }

    function onProgressPushed(code as Number, data as Dictionary or String or Null) as Void {
        Log.code("Sync: progress", code);
        if (code == 200) {
            // Only discard after confirmed acceptance — on an abort the
            // listening progress would otherwise be gone.
            Store.clearProgress();
            adoptServerPositions(data);
        }
        fetchPlaylist();
    }

    //! Where the server was ahead of the watch, the watch jumps to it.
    private function adoptServerPositions(data as Dictionary or String or Null) as Void {
        if (!(data instanceof Dictionary)) {
            return;
        }
        var books = data["books"];
        if (!(books instanceof Array)) {
            return;
        }
        for (var i = 0; i < books.size(); ++i) {
            var entry = books[i];
            if (!(entry instanceof Dictionary)) {
                continue;
            }
            var resume = entry["resume"];
            var bookId = entry["id"];
            if (resume instanceof Dictionary && bookId instanceof String) {
                var segment = resume["segment"];
                if (segment instanceof Number) {
                    Store.rememberPosition(bookId, segment, numberOf(resume["offset"]), 0);
                }
            }
        }
    }

    // --- Phase 2: read the playlist ---------------------------------------------

    private function fetchPlaylist() as Void {
        if (_stopped) {
            return;
        }
        _client.playlist(method(:onPlaylist));
    }

    function onPlaylist(code as Number, data as Dictionary or String or Null) as Void {
        Log.code("Sync: playlist", code);
        if (_stopped) {
            return;
        }
        if (code == 409) {
            // Playlist not found. This is a configuration error, not an empty
            // wish — nothing is deleted here.
            Communications.notifySyncComplete(
                WatchUi.loadResource(Rez.Strings.syncNoPlaylist) as String
            );
            return;
        }
        if (code != 200 || !(data instanceof Dictionary)) {
            // Without a fresh target, everything stays as it is.
            Communications.notifySyncComplete("HTTP " + code.toString());
            return;
        }

        var books = data["books"];
        if (!(books instanceof Array)) {
            Communications.notifySyncComplete(null);
            return;
        }

        var wanted = [] as Array<String>;
        for (var i = 0; i < books.size(); ++i) {
            var book = books[i];
            if (book instanceof Dictionary && book["id"] instanceof String) {
                wanted.add(book["id"] as String);
            }
        }
        Store.setDesired(wanted);

        // Whatever is no longer in the playlist also disappears from the watch.
        var gone = orphans(wanted);
        for (var i = 0; i < gone.size(); ++i) {
            deleteLocal(gone[i]);
        }

        _bookQueue = wanted;
        _booksTotal = _bookQueue.size();
        Log.code("Sync: per playlist", _booksTotal);
        Log.code("Sync: removed", gone.size());
        nextBook();
    }

    // --- Phase 3: fetch the books -----------------------------------------------

    private function nextBook() as Void {
        if (_stopped) {
            return;
        }
        if (_bookQueue.size() == 0) {
            Log.line("Sync: done, error=" + ((_failure == null) ? "none" : _failure));
            Communications.notifySyncComplete(_failure);
            return;
        }
        var bookId = _bookQueue[0];
        _bookQueue.remove(bookId);
        _currentBook = bookId;
        Log.line("Sync: segments for " + bookId);
        _client.segments(bookId, method(:onSegments));
    }

    function onSegments(code as Number, data as Dictionary or String or Null) as Void {
        Log.code("Sync: segments", code);
        if (_stopped) {
            return;
        }
        if (code == 409) {
            // The proxy is still cutting. Not an error — try again on the next sync.
            _stillPreparing += 1;
            bookDone();
            return;
        }
        var bookId = _currentBook;
        if (code != 200 || !(data instanceof Dictionary) || bookId == null) {
            _failure = "HTTP " + code.toString();
            bookDone();
            return;
        }

        var segments = data["segments"];
        if (!(segments instanceof Array)) {
            bookDone();
            return;
        }

        Store.setBookInfo(
            bookId,
            SyncConfigView.stringOr(data["title"], bookId),
            SyncConfigView.stringOr(data["author"], ""),
            segments.size()
        );

        var known = knownSegments(bookId);
        _downloads = [] as Array<Dictionary>;
        for (var i = 0; i < segments.size(); ++i) {
            var segment = segments[i];
            if (!(segment instanceof Dictionary)) {
                continue;
            }
            var index = segment["index"];
            if (index instanceof Number && known.indexOf(index) < 0) {
                _downloads.add(segment);
            }
        }
        _downloadsTotal = _downloads.size();
        _downloadsDone = 0;
        Log.code("Sync: segments total", segments.size());
        Log.code("Sync: of those to download", _downloadsTotal);
        downloadNext();
    }

    private function knownSegments(bookId as String) as Array<Number> {
        var result = [] as Array<Number>;
        var refIds = Store.localTracks(bookId).keys();
        for (var i = 0; i < refIds.size(); ++i) {
            var parts = Store.trackInfo(bookId, refIds[i]);
            if (parts != null) {
                result.add(Store.toNumber(parts[0]));
            }
        }
        return result;
    }

    private function downloadNext() as Void {
        if (_stopped) {
            return;
        }
        if (_downloads.size() == 0) {
            bookDone();
            return;
        }
        var segment = _downloads[0];
        _downloads.remove(segment);
        var path = segment["url"];
        if (!(path instanceof String)) {
            downloadNext();
            return;
        }
        _pending = segment;
        Log.line("Sync: downloading " + path);
        _client.downloadSegment(
            path,
            SyncConfigView.stringOr(segment["encoding"], "m4a"),
            method(:onSegmentDownloaded)
        );
    }

    function onSegmentDownloaded(code as Number, data as Object?) as Void {
        Log.code("Sync: segment downloaded", code);
        if (_stopped) {
            return;
        }
        var segment = _pending;
        var bookId = _currentBook;
        if (code == 200 && data instanceof Media.ContentRef && segment != null && bookId != null) {
            Store.addLocalTrack(
                bookId,
                data.getId(),
                numberOf(segment["index"]),
                numberOf(segment["duration"]),
                SyncConfigView.stringOr(segment["title"], "")
            );
        } else {
            // A single segment does not take the whole book down with it: the
            // next sync only fetches the gap.
            _failure = "HTTP " + code.toString();
        }
        _downloadsDone += 1;
        report();
        downloadNext();
    }

    private function bookDone() as Void {
        _booksDone += 1;
        _downloadsTotal = 0;
        _downloadsDone = 0;
        report();
        nextBook();
    }

    private function report() as Void {
        if (_booksTotal <= 0) {
            return;
        }
        var withinBook = 0.0;
        if (_downloadsTotal > 0) {
            withinBook = _downloadsDone.toFloat() / _downloadsTotal.toFloat();
        }
        var share = (_booksDone.toFloat() + withinBook) / _booksTotal.toFloat();
        if (share > 1.0) {
            share = 1.0;
        }
        Communications.notifySyncProgress((share * 100).toNumber());
    }

    static function numberOf(value as Object?) as Number {
        if (value instanceof Number) {
            return value;
        }
        if (value instanceof Float) {
            return value.toNumber();
        }
        if (value instanceof Double) {
            return value.toNumber();
        }
        return 0;
    }
}
