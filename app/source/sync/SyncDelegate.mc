import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.Timer;
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

    //! The first few percent belong to the preparation steps.
    //!
    //! On the watch the progress ring is the only feedback there is. Without
    //! these marks it would sit at 0 % until the first finished segment — and
    //! 0 % then means either "running" or "stuck for an hour".
    const PHASE_START = 1;
    const PHASE_PROGRESS_PUSHED = 2;
    const PHASE_PLAYLIST = 3;
    const PHASE_SEGMENTS = 4;
    //! From here on the downloads count.
    const PHASE_DOWNLOAD = 5;

    //! Watchdog tick, and the number of ticks without any stirring after which
    //! it ends the sync. Generous, because a segment really does take many
    //! minutes over Bluetooth — the point is only that the watch eventually
    //! shows a message instead of sitting in the sync screen forever.
    const WATCHDOG_TICK_MS = 30000;
    const WATCHDOG_MAX_IDLE_TICKS = 20;

    private var _client as ProxyClient;
    private var _bookQueue as Array<String>;
    private var _downloads as Array<Dictionary>;
    //! The progress entries in flight, so that only what was sent is marked as
    //! agreed, and nothing buffered while the request was out.
    private var _sentEntries as Array;
    private var _pending as Dictionary?;
    private var _currentBook as String?;
    private var _booksTotal as Number;
    private var _booksDone as Number;
    private var _downloadsTotal as Number;
    private var _downloadsDone as Number;
    private var _stillPreparing as Number;
    private var _failure as String?;
    private var _stopped as Boolean;
    private var _phase as Number;
    private var _reported as Number;
    private var _segmentBytes as Number;
    private var _segmentSize as Number;
    private var _watchdog as Timer.Timer?;
    private var _activity as Number;
    private var _idleTicks as Number;

    function initialize() {
        SyncDelegate.initialize();
        _client = new ProxyClient();
        _bookQueue = [] as Array<String>;
        _downloads = [] as Array<Dictionary>;
        _sentEntries = [] as Array;
        _pending = null;
        _currentBook = null;
        _booksTotal = 0;
        _booksDone = 0;
        _downloadsTotal = 0;
        _downloadsDone = 0;
        _stillPreparing = 0;
        _failure = null;
        _stopped = false;
        _phase = 0;
        _reported = -1;
        _segmentBytes = 0;
        _segmentSize = 0;
        _watchdog = null;
        _activity = 0;
        _idleTicks = 0;
    }

    //! Only when someone asked for it — the Sync row stamps a ticket in the
    //! store, and a fresh ticket is the whole of the answer.
    //!
    //! The system asks this on every trigger, its own schedule included, and
    //! the SDK is unambiguous about a false: "onStartSync will not be called
    //! if a sync is triggered for this application." The trigger makes no
    //! distinction between the system's own idea and the Sync row, and
    //! startSync() overrules nothing despite the name — a plain false
    //! therefore does not skip the sync, it freezes the sync screen at 0 %
    //! with this app never hearing about it. (Seen on the fēnix: the screen
    //! sits there, the log says nothing, and no amount of waiting helps.)
    //!
    //! So the answer is true exactly while a manual request is fresh, and no
    //! otherwise — above all not for the playlist simply being old. A sync
    //! brings up Wi-Fi and holds the watch for as long as the downloads take,
    //! and that is not something to start on a schedule.
    function isSyncNeeded() as Boolean {
        var requested = Store.syncRequested();
        Log.debug("Sync: needed " + requested.toString());
        return requested;
    }

    function onStartSync() as Void {
        Log.info("Sync: onStartSync");
        // The ticket brought the sync this far; it does not get to bring the
        // next one.
        Store.clearSyncRequest();
        logEnvironment();
        enterPhase(PHASE_START);
        startWatchdog();
        if (!_client.isConfigured()) {
            finish("Proxy not configured");
            return;
        }
        // Progress first: it is small and must not get stuck behind an
        // aborting download.
        pushProgress();
    }

    function onStopSync() as Void {
        Log.info("Sync: onStopSync");
        _stopped = true;
        Communications.cancelAllRequests();
        finish(null);
    }

    // --- Visibility -----------------------------------------------------------

    //! What the watch actually has available during a sync.
    //!
    //! The difference from the simulator almost always sits here: there the
    //! line is the computer's internet, on the watch it is either Wi-Fi or —
    //! far slower — Bluetooth by way of the phone.
    private function logEnvironment() as Void {
        var connections = System.getDeviceSettings().connectionInfo;
        Log.debugCode("Sync: Wi-Fi", stateOf(connections, :wifi));
        Log.debugCode("Sync: Bluetooth", stateOf(connections, :bluetooth));
        Log.debugCode("Sync: LTE", stateOf(connections, :lte));
        var stats = System.getSystemStats();
        Log.debugCode("Sync: free memory", stats.freeMemory);
    }

    //! -1 means: this path does not exist on the device.
    private function stateOf(connections as Dictionary, key as Symbol) as Number {
        var info = connections[key];
        if (info instanceof System.ConnectionInfo) {
            return info.state;
        }
        return -1;
    }

    //! Every preparation step gets its own mark on the ring.
    private function enterPhase(phase as Number) as Void {
        _phase = phase;
        Log.code("Sync: phase", phase);
        report();
    }

    //! Ends the sync by exactly one route — otherwise the watchdog keeps running.
    private function finish(error as String?) as Void {
        stopWatchdog();
        if (error == null) {
            Log.info("Sync: end, no error");
        } else {
            Log.error("Sync: end, error=" + error);
        }
        Communications.notifySyncComplete(error);
    }

    // --- Watchdog -------------------------------------------------------------

    //! Without it every unanswered request ends in a sync screen that never
    //! closes: Connect IQ simply does not call the callback, and the app is
    //! left with no place at which it could notice.
    private function startWatchdog() as Void {
        try {
            var timer = new Timer.Timer();
            timer.start(method(:onWatchdogTick), WATCHDOG_TICK_MS, true);
            _watchdog = timer;
        } catch (ex) {
            // No timer in sync mode: then without one. That is the state as it
            // was before, not worse.
            Log.warn("Sync: no watchdog available");
            _watchdog = null;
        }
    }

    private function stopWatchdog() as Void {
        var timer = _watchdog;
        if (timer != null) {
            timer.stop();
            _watchdog = null;
        }
    }

    function onWatchdogTick() as Void {
        if (_stopped) {
            return;
        }
        if (_activity > 0) {
            _activity = 0;
            _idleTicks = 0;
            return;
        }
        _idleTicks += 1;
        if (Log.LEVEL >= Log.WARN) {
            Log.warnCode("Sync: quiet in phase " + _phase.toString() + ", ticks", _idleTicks);
        }
        if (_idleTicks < WATCHDOG_MAX_IDLE_TICKS) {
            return;
        }
        _stopped = true;
        Communications.cancelAllRequests();
        finish("No response in phase " + _phase.toString());
    }

    //! Every stirring from outside — a response or a byte — counts.
    private function stirred() as Void {
        _activity += 1;
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
        // Every book on the watch is asked about, not only the ones with
        // something buffered: listening done on the phone comes back this way.
        var entries = Store.syncEntries(Store.localBooks());
        Log.debugCode("Sync: progress entries", entries.size());
        if (entries.size() == 0) {
            enterPhase(PHASE_PROGRESS_PUSHED);
            fetchPlaylist();
            return;
        }
        _sentEntries = entries;
        _client.pushProgress(entries, method(:onProgressPushed));
    }

    function onProgressPushed(code as Number, data as Dictionary or String or Null) as Void {
        stirred();
        Log.response("Sync: progress", code);
        if (code == 200) {
            // Only what the server accepted stops being pending, and only if
            // it has not moved since it was sent.
            Progress.settle(_sentEntries, data);
        }
        enterPhase(PHASE_PROGRESS_PUSHED);
        fetchPlaylist();
    }

    // --- Phase 2: read the playlist ---------------------------------------------

    private function fetchPlaylist() as Void {
        if (_stopped) {
            return;
        }
        Log.info("Sync: fetching playlist");
        _client.playlist(method(:onPlaylist));
    }

    function onPlaylist(code as Number, data as Dictionary or String or Null) as Void {
        stirred();
        Log.response("Sync: playlist", code);
        if (_stopped) {
            return;
        }
        if (code == 409) {
            // Playlist not found. This is a configuration error, not an empty
            // wish — nothing is deleted here.
            finish(WatchUi.loadResource(Rez.Strings.syncNoPlaylist) as String);
            return;
        }
        if (code != 200 || !(data instanceof Dictionary)) {
            // Without a fresh target, everything stays as it is.
            finish("HTTP " + code.toString());
            return;
        }

        var books = data["books"];
        if (!(books instanceof Array)) {
            finish(null);
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
        enterPhase(PHASE_PLAYLIST);
        nextBook();
    }

    // --- Phase 3: fetch the books -----------------------------------------------

    private function nextBook() as Void {
        if (_stopped) {
            return;
        }
        if (_bookQueue.size() == 0) {
            Log.code("Sync: done, still preparing", _stillPreparing);
            finish(_failure);
            return;
        }
        var bookId = _bookQueue[0];
        _bookQueue.remove(bookId);
        _currentBook = bookId;
        Log.info("Sync: segments for " + bookId);
        _client.segments(bookId, method(:onSegments));
    }

    function onSegments(code as Number, data as Dictionary or String or Null) as Void {
        stirred();
        Log.response("Sync: segments", code);
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
        Log.debugCode("Sync: segments total", segments.size());
        Log.code("Sync: of those to download", _downloadsTotal);
        enterPhase(PHASE_SEGMENTS);
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
        _segmentBytes = 0;
        _segmentSize = 0;
        Log.info("Sync: downloading " + path);
        _client.downloadSegment(
            path,
            SyncConfigView.stringOr(segment["encoding"], "m4a"),
            method(:onSegmentDownloaded),
            method(:onSegmentBytes)
        );
    }

    //! Byte count during a segment.
    //!
    //! Without this report the ring stands still from the start of a segment to
    //! its end — with several megabytes over Bluetooth that is minutes to
    //! hours in which the watch looks like it has hung.
    function onSegmentBytes(transferred as Number, size as Number?) as Void {
        stirred();
        _segmentBytes = transferred;
        if (size != null) {
            _segmentSize = size;
        }
        report();
    }

    function onSegmentDownloaded(code as Number, data as Object?) as Void {
        stirred();
        Log.response("Sync: segment downloaded", code);
        Log.debugCode("Sync: bytes", _segmentBytes);
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
        _segmentBytes = 0;
        _segmentSize = 0;
        report();
        downloadNext();
    }

    private function bookDone() as Void {
        _booksDone += 1;
        _downloadsTotal = 0;
        _downloadsDone = 0;
        _segmentBytes = 0;
        _segmentSize = 0;
        report();
        nextBook();
    }

    private function report() as Void {
        var percent = _phase;
        if (_booksTotal > 0) {
            var withinBook = 0.0;
            if (_downloadsTotal > 0) {
                withinBook = (_downloadsDone.toFloat() + segmentShare()) / _downloadsTotal.toFloat();
            }
            var share = (_booksDone.toFloat() + withinBook) / _booksTotal.toFloat();
            if (share > 1.0) {
                share = 1.0;
            }
            percent = PHASE_DOWNLOAD + ((100 - PHASE_DOWNLOAD) * share).toNumber();
        }
        if (percent == _reported) {
            return;
        }
        _reported = percent;
        // The reported number belongs in the log: if the watch shows 0 % while
        // this says 6 %, the fault is not in this calculation.
        Log.debugCode("Sync: reported", percent);
        Communications.notifySyncProgress(percent);
    }

    //! Share of the segment currently in flight.
    private function segmentShare() as Float {
        if (_segmentSize <= 0 || _segmentBytes <= 0) {
            return 0.0;
        }
        if (_segmentBytes >= _segmentSize) {
            return 1.0;
        }
        return _segmentBytes.toFloat() / _segmentSize.toFloat();
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
