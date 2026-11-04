import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! The sync itself.
//!
//! Order: report progress, read playlist, fetch books. Progress goes first so
//! it arrives even when the downloads abort later.
class AbSyncDelegate extends Communications.SyncDelegate {

    //! The first few percent belong to the preparation steps, so the ring does
    //! not sit at 0 % until the first segment finishes.
    const PHASE_START = 1;
    const PHASE_PROGRESS_PUSHED = 2;
    const PHASE_PLAYLIST = 3;
    const PHASE_SEGMENTS = 4;
    //! From here on the downloads count.
    const PHASE_DOWNLOAD = 5;

    //! Which request is in flight, so a cancel can repeat that request.
    const STEP_PROGRESS = 1;
    const STEP_PLAYLIST = 2;
    const STEP_SEGMENTS = 3;
    const STEP_DOWNLOAD = 4;

    //! Watchdog tick, and the idle ticks after which it ends the sync. Generous,
    //! because a segment can take many minutes over Bluetooth.
    const WATCHDOG_TICK_MS = 30000;
    const WATCHDOG_MAX_IDLE_TICKS = 20;

    private var _client as ProxyClient;
    private var _bookQueue as Array<String>;
    private var _downloads as Array<Dictionary>;
    //! Progress entries in flight, so only what was sent is marked as agreed.
    private var _sentEntries as Array;
    private var _pending as Dictionary?;
    private var _currentBook as String?;
    //! Segments collected so far for the current book, across all pages.
    private var _segmentsAccum as Array<Dictionary>;
    //! Cursor for the next segments page, -1 for the first.
    private var _segmentsAfter as Number;
    private var _booksTotal as Number;
    private var _booksDone as Number;
    private var _downloadsTotal as Number;
    private var _downloadsDone as Number;
    private var _stillPreparing as Number;
    private var _failure as String?;
    private var _stopped as Boolean;
    //! Set before notifySyncComplete. Back during a notification calls
    //! onStopSync, and that completion can call onStopSync again.
    private var _finished as Boolean;
    private var _phase as Number;
    private var _reported as Number;
    private var _segmentBytes as Number;
    private var _segmentSize as Number;
    private var _watchdog as Timer.Timer?;
    private var _activity as Number;
    private var _idleTicks as Number;
    //! Which request to repeat when Back cancels it.
    private var _step as Number;
    private var _retry as Timer.Timer?;
    private var _cancelRetries as Number;
    //! Highest notification count seen this session. A drop means one was
    //! dismissed, which is the Back press that should not end the sync.
    private var _notePeak as Number;
    private var _notes as Timer.Timer?;

    function initialize() {
        SyncDelegate.initialize();
        _client = new ProxyClient();
        _bookQueue = [] as Array<String>;
        _downloads = [] as Array<Dictionary>;
        _sentEntries = [] as Array;
        _pending = null;
        _currentBook = null;
        _segmentsAccum = [] as Array<Dictionary>;
        _segmentsAfter = -1;
        _booksTotal = 0;
        _booksDone = 0;
        _downloadsTotal = 0;
        _downloadsDone = 0;
        _stillPreparing = 0;
        _failure = null;
        _stopped = false;
        _finished = false;
        _phase = 0;
        _reported = -1;
        _segmentBytes = 0;
        _segmentSize = 0;
        _watchdog = null;
        _activity = 0;
        _idleTicks = 0;
        _step = 0;
        _retry = null;
        _cancelRetries = 0;
        _notePeak = 0;
        _notes = null;
    }

    //! Manual request, or a plugged-in watch that has not synced in a day.
    //!
    //! The system asks on its own when the watch is on the cable. A download
    //! holds the watch for the whole transfer, so that path runs once a day.
    //! Anything else, including an old ticket, answers no and onStartSync is
    //! not called.
    function isSyncNeeded() as Boolean {
        if (Store.syncRequested()) {
            Log.info("Sync: needed, requested");
            return true;
        }
        if (!System.getSystemStats().charging) {
            Log.debug("Sync: not plugged in");
            return false;
        }
        if (!Store.dailySyncDue()) {
            Log.debug("Sync: plugged in, already synced today");
            return false;
        }
        Log.info("Sync: needed, plugged in");
        return true;
    }

    function onStartSync() as Void {
        Log.info("Sync: onStartSync");
        var manual = Store.syncRequested();
        Store.clearSyncRequest();
        if (!manual) {
            Store.noteDailySync();
        }
        logEnvironment();
        enterPhase(PHASE_START);
        startWatchdog();
        startNoteWatch();
        if (!_client.isConfigured()) {
            finish("Proxy not configured");
            return;
        }
        pushProgress();
    }

    function onStopSync() as Void {
        if (_finished) {
            return;
        }
        // Back on the sync screen and Back on a notification both land here.
        // A notification also lowers the count sampled while the sync ran, and
        // that stop restarts the download. A second Back soon after a restart,
        // with no notification dismissed, is the user stopping for real.
        sampleNotifications();
        var dropped = notificationCount() < _notePeak;
        if (Store.resumeWasCancelled() && !dropped) {
            Log.warn("Sync: onStopSync, cancelled");
            Store.clearResume();
            _stopped = true;
            Communications.cancelAllRequests();
            finish(null);
            return;
        }
        var echoes = Store.noteResume();
        if (echoes > Store.RESUME_ECHO_LIMIT) {
            Log.warn("Sync: onStopSync, resume gave up");
            Store.clearResume();
            _stopped = true;
            Communications.cancelAllRequests();
            finish(null);
            return;
        }
        Log.warn("Sync: onStopSync, resuming");
        // The relaunch is a new process. isSyncNeeded() only continues when
        // this ticket is set, including when the watch is not on the charger.
        Store.requestSync();
        complete(null);
        Communications.startSync2({
            :message => WatchUi.loadResource(Rez.Strings.AppName) as String
        });
    }

    // --- Visibility -----------------------------------------------------------

    //! Logs the connections available during a sync; this is where the watch
    //! differs from the simulator.
    private function logEnvironment() as Void {
        var connections = System.getDeviceSettings().connectionInfo;
        Log.debugCode("Sync: Wi-Fi", stateOf(connections, :wifi));
        Log.debugCode("Sync: Bluetooth", stateOf(connections, :bluetooth));
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

    private function enterPhase(phase as Number) as Void {
        _phase = phase;
        Log.code("Sync: phase", phase);
        report();
    }

    //! Ends the sync by exactly one route. Otherwise the watchdog keeps running.
    //!
    //! The flag is raised before the system call. On this watch, dismissing a
    //! notification with Back cancels the sync, and notifySyncComplete calls
    //! onStopSync again. A second completion crashes.
    //!
    //! This clears the restart stamp. A restart must go through complete() so
    //! the new process still sees why it was launched.
    private function finish(error as String?) as Void {
        if (_finished) {
            return;
        }
        Store.clearResume();
        if (error == null) {
            Log.info("Sync: end, no error");
        } else {
            Log.error("Sync: end, error=" + error);
        }
        complete(error);
    }

    //! Notifies the system once. A restart uses this directly so the restart
    //! stamp survives; finish() clears that stamp before it gets here.
    private function complete(error as String?) as Void {
        if (_finished) {
            return;
        }
        _finished = true;
        _stopped = true;
        stopWatchdog();
        stopNoteWatch();
        stopRetry();
        Communications.notifySyncComplete(error);
    }

    // --- Watchdog -------------------------------------------------------------

    //! Connect IQ does not call back on an unanswered request, which would leave
    //! the sync screen open forever.
    private function startWatchdog() as Void {
        try {
            var timer = new Timer.Timer();
            timer.start(method(:onWatchdogTick), WATCHDOG_TICK_MS, true);
            _watchdog = timer;
        } catch (ex) {
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

    //! Samples the notification count so a dismiss can be told from Back on
    //! the sync screen. The count only rises while the notification is up.
    private function startNoteWatch() as Void {
        _notePeak = notificationCount();
        try {
            var timer = new Timer.Timer();
            timer.start(method(:onNoteSample), 1000, true);
            _notes = timer;
        } catch (ex) {
            _notes = null;
        }
    }

    private function stopNoteWatch() as Void {
        var timer = _notes;
        if (timer != null) {
            timer.stop();
            _notes = null;
        }
    }

    function onNoteSample() as Void {
        sampleNotifications();
    }

    private function sampleNotifications() as Void {
        var count = notificationCount();
        if (count > _notePeak) {
            _notePeak = count;
        }
    }

    private function notificationCount() as Number {
        var settings = System.getDeviceSettings();
        if (settings has :notificationCount) {
            return settings.notificationCount;
        }
        return 0;
    }

    private function stopRetry() as Void {
        var timer = _retry;
        if (timer != null) {
            timer.stop();
            _retry = null;
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

    //! Any response or received byte counts as activity.
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
        // Every book with something stored, including a partial download, so
        // listening done on the phone comes back too. localBooks() is only the
        // finished ones.
        var entries = Store.syncEntries(Store.knownBooks());
        Log.debugCode("Sync: progress entries", entries.size());
        if (entries.size() == 0) {
            enterPhase(PHASE_PROGRESS_PUSHED);
            fetchPlaylist();
            return;
        }
        _sentEntries = entries;
        _step = STEP_PROGRESS;
        _client.pushProgress(entries, method(:onProgressPushed));
    }

    function onProgressPushed(code as Number, data as Dictionary or String or Null) as Void {
        stirred();
        Log.response("Sync: progress", code);
        // Back cancels the request with -1003 while the sync screen is going
        // away. Reporting progress from here is the crash.
        if (gaveUp(code)) {
            return;
        }
        if (code == 200) {
            Progress.settle(_sentEntries, data);
        }
        enterPhase(PHASE_PROGRESS_PUSHED);
        fetchPlaylist();
    }

    //! True when this callback must not start further work.
    //!
    //! Back on a notification cancels the request in flight with -1003, and
    //! reporting progress from that callback crashes. The request is repeated
    //! a moment later, once the notification is gone. A cancel that arrives
    //! while onStopSync is already running just returns.
    private function gaveUp(code as Number) as Boolean {
        if (_stopped || _finished) {
            return true;
        }
        if (code == Communications.REQUEST_CANCELLED) {
            scheduleRetry();
            return true;
        }
        _cancelRetries = 0;
        return false;
    }

    //! Repeats the cancelled request after the notification has closed.
    //! Doing it inside the cancel callback is what used to crash.
    private function scheduleRetry() as Void {
        if (_retry != null || _stopped || _finished) {
            return;
        }
        try {
            var timer = new Timer.Timer();
            timer.start(method(:onRetry), 1000, false);
            _retry = timer;
        } catch (ex) {
            Log.warn("Sync: no retry timer");
        }
    }

    function onRetry() as Void {
        _retry = null;
        if (_stopped || _finished) {
            return;
        }
        _cancelRetries += 1;
        if (_cancelRetries > 3) {
            Log.warn("Sync: cancelled too often");
            finish(null);
            return;
        }
        Log.warnCode("Sync: retry", _step);
        if (_step == STEP_DOWNLOAD) {
            requeuePending();
            downloadNext();
            return;
        }
        if (_step == STEP_SEGMENTS) {
            fetchSegmentsPage();
            return;
        }
        if (_step == STEP_PLAYLIST) {
            fetchPlaylist();
            return;
        }
        pushProgress();
    }

    //! downloadNext() already took the segment off the queue. A cancel has to
    //! put it back, or that segment is skipped.
    private function requeuePending() as Void {
        var segment = _pending;
        if (!(segment instanceof Dictionary)) {
            return;
        }
        _pending = null;
        var restored = [segment] as Array<Dictionary>;
        for (var i = 0; i < _downloads.size(); ++i) {
            restored.add(_downloads[i]);
        }
        _downloads = restored;
    }

    // --- Phase 2: read the playlist ---------------------------------------------

    private function fetchPlaylist() as Void {
        if (_stopped) {
            return;
        }
        Log.info("Sync: fetching playlist");
        _step = STEP_PLAYLIST;
        _client.playlist(method(:onPlaylist));
    }

    function onPlaylist(code as Number, data as Dictionary or String or Null) as Void {
        stirred();
        Log.response("Sync: playlist", code);
        if (gaveUp(code)) {
            return;
        }
        if (code == 409) {
            // Playlist not found: a configuration error, nothing is deleted.
            finish(WatchUi.loadResource(Rez.Strings.syncNoPlaylist) as String);
            return;
        }
        if (code != 200 || !(data instanceof Dictionary)) {
            finish("HTTP " + code.toString());
            return;
        }

        var books = data["books"];
        if (!(books instanceof Array)) {
            finish(null);
            return;
        }

        Store.rememberPlaylist(books as Array);
        var wanted = Store.desired();

        // Books no longer in the playlist are removed from the watch.
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
        _segmentsAccum = [] as Array<Dictionary>;
        _segmentsAfter = -1;
        Log.info("Sync: segments for " + bookId);
        fetchSegmentsPage();
    }

    //! One page of the current book's segment listing; see ProxyClient.segments.
    //! Repeated with the cursor until the server has no more.
    private function fetchSegmentsPage() as Void {
        var bookId = _currentBook;
        if (bookId == null) {
            return;
        }
        _step = STEP_SEGMENTS;
        _client.segments(bookId, _segmentsAfter, method(:onSegments));
    }

    function onSegments(code as Number, data as Dictionary or String or Null) as Void {
        stirred();
        Log.response("Sync: segments", code);
        if (gaveUp(code)) {
            return;
        }
        if (code == 409) {
            // The proxy is still cutting; not an error, retried on the next sync.
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

        var page = data["segments"];
        if (!(page instanceof Array)) {
            bookDone();
            return;
        }
        for (var i = 0; i < page.size(); ++i) {
            var entry = page[i];
            if (entry instanceof Dictionary) {
                _segmentsAccum.add(entry);
            }
        }

        var next = data["next"];
        if (next instanceof Number) {
            _segmentsAfter = next;
            fetchSegmentsPage();
            return;
        }

        var segments = _segmentsAccum;
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
        _step = STEP_DOWNLOAD;
        Log.info("Sync: downloading " + path);
        _client.downloadSegment(
            path,
            method(:onSegmentDownloaded),
            method(:onSegmentBytes)
        );
    }

    //! Byte count during a segment, so the ring moves within a long download.
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
        if (gaveUp(code)) {
            return;
        }
        var segment = _pending;
        var bookId = _currentBook;
        if (code == 200 && data instanceof Media.ContentRef && segment != null && bookId != null) {
            var segmentTitle = SyncConfigView.stringOr(segment["title"], "");
            if (segmentTitle.length() == 0) {
                segmentTitle = numberOf(segment["index"]).toString();
            }
            // A full map used to throw here and take the rest of the sync with it.
            if (!Store.addLocalTrack(
                bookId,
                data.getId(),
                numberOf(segment["index"]),
                numberOf(segment["duration"]),
                segmentTitle
            )) {
                _failure = "Store full";
            }
        } else {
            // The next sync only fetches the gap.
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
        // A byte callback can still be running while Back tears the sync down.
        // notifySyncProgress from there crashes.
        if (_stopped || _finished) {
            return;
        }
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
