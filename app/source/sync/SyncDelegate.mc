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
    //! From here on the ring follows bytes, not how many segments are left.
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
    //! Gap between two removals of a cached segment. One file per turn: deleting
    //! a whole re-cut book here trips the execution watchdog.
    const DROP_YIELD_MS = 50;
    //! A segment that failed is tried again this many times, after a pause,
    //! before the sync records the failure and moves on.
    const SEGMENT_RETRIES = 2;
    const SEGMENT_RETRY_MS = 3000;

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
    //! The user stopped the sync, or it was cancelled too often to go on. That
    //! says nothing about whether the server could be reached.
    private var _cancelled as Boolean;
    private var _phase as Number;
    private var _reported as Number;
    private var _segmentBytes as Number;
    private var _segmentSize as Number;
    //! Manifest size of the segment in flight. The byte callback is capped here
    //! so a long transfer cannot move the ring past that segment.
    private var _segmentBudget as Number;
    //! Every segment of the current book, and how many of those bytes are
    //! already stored or finished this sync. The ring uses the ratio.
    private var _bookBytesTotal as Float;
    private var _bookBytesDone as Float;
    private var _watchdog as Timer.Timer?;
    private var _activity as Number;
    private var _idleTicks as Number;
    //! Which request to repeat when Back cancels it.
    private var _step as Number;
    //! One shared one-shot timer for the short pauses between steps (cancel
    //! retry, removal of cached files, segment retry). Connect IQ allows only a
    //! few timers, and a fresh Timer for every step used them up ("Too Many
    //! Timers"). The three uses never overlap.
    private var _yield as Timer.Timer?;
    private var _yieldArmed as Boolean;
    private var _cancelRetries as Number;
    //! Cached files the current book no longer matches, removed one per turn.
    private var _staleRefs as Array;
    private var _staleAt as Number;
    //! Whose files the removal timer is working through, and whether that book
    //! is leaving the watch entirely (then the book is forgotten at the end).
    private var _dropBook as String?;
    private var _dropWholeBook as Boolean;
    //! Books no longer in the playlist that still wait to be removed.
    private var _orphans as Array<String>;
    //! Failed attempts at the segment in flight, and which segment that is.
    private var _segmentAttempts as Number;
    private var _attemptIndex as Number;
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
        _cancelled = false;
        _phase = 0;
        _reported = -1;
        _segmentBytes = 0;
        _segmentSize = 0;
        _segmentBudget = 0;
        _bookBytesTotal = 0.0;
        _bookBytesDone = 0.0;
        _watchdog = null;
        _activity = 0;
        _idleTicks = 0;
        _step = 0;
        _yield = null;
        _yieldArmed = false;
        _cancelRetries = 0;
        _staleRefs = [] as Array;
        _staleAt = 0;
        _dropBook = null;
        _dropWholeBook = false;
        _orphans = [] as Array<String>;
        _segmentAttempts = 0;
        _attemptIndex = -1;
        _notePeak = 0;
        _notes = null;
    }

    //! Whether to take part in a sync the system has started.
    //!
    //! The system decides when a sync begins, for instance with the watch on
    //! the cable, and only asks this app whether it has anything to do. A hand
    //! request through the Download books row always counts. Otherwise the
    //! plugged-in setting decides. There is no extra check of the charger or
    //! the time of the last sync: either would only second-guess the system.
    function isSyncNeeded() as Boolean {
        if (Store.syncRequested()) {
            Log.info("Sync: needed, requested");
            return true;
        }
        if (Settings.syncOnPluggedIn()) {
            Log.info("Sync: needed, started by the system");
            return true;
        }
        Log.info("Sync: not needed, plugged-in sync is off");
        return false;
    }

    function onStartSync() as Void {
        Log.info("Sync: onStartSync");
        Store.clearSyncRequest();
        logEnvironment();
        enterPhase(PHASE_START);
        startWatchdog();
        startNoteWatch();
        if (!_client.isConfigured()) {
            finish(Errors.text(Rez.Strings.errNotSetUp));
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
        var dropped = deviceNotificationCount() < _notePeak;
        if (Store.resumeWasCancelled() && !dropped) {
            Log.warn("Sync: onStopSync, cancelled");
            Store.clearResume();
            _stopped = true;
            _cancelled = true;
            Communications.cancelAllRequests();
            finish(null);
            return;
        }
        var echoes = Store.noteResume();
        if (echoes > Store.RESUME_ECHO_LIMIT) {
            Log.warn("Sync: onStopSync, resume gave up");
            Store.clearResume();
            _stopped = true;
            _cancelled = true;
            Communications.cancelAllRequests();
            finish(null);
            return;
        }
        Log.warn("Sync: onStopSync, resuming");
        // The relaunch is a new process. The ticket lets isSyncNeeded() answer
        // yes for it even when the plugged-in setting is off.
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
        if (!_cancelled) {
            Store.noteSyncResult(error);
        }
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
        stopYield();
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
        _notePeak = deviceNotificationCount();
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
        var count = deviceNotificationCount();
        if (count > _notePeak) {
            _notePeak = count;
        }
    }

    //! Named apart from DeviceSettings.notificationCount so `has :notificationCount`
    //! looks up the settings field, not this method.
    private function deviceNotificationCount() as Number {
        var settings = System.getDeviceSettings();
        if (settings has :notificationCount) {
            return settings.notificationCount;
        }
        return 0;
    }

    private function stopYield() as Void {
        var timer = _yield;
        if (timer != null) {
            timer.stop();
        }
        _yieldArmed = false;
    }

    //! Starts the shared timer for one callback. False when no timer could be
    //! started.
    private function arm(callback as Method() as Void, ms as Number) as Boolean {
        try {
            var timer = _yield;
            if (timer == null) {
                timer = new Timer.Timer();
                _yield = timer;
            }
            timer.start(callback, ms, false);
            _yieldArmed = true;
            return true;
        } catch (ex) {
            return false;
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
        Log.error("Sync: no response in phase " + _phase.toString());
        finish(Errors.text(Rez.Strings.errNoResponse));
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

    //! Takes the next book that left the playlist off the watch. Its files go
    //! one per timer turn, like the stale segments of a re-cut book: removing
    //! them all inside one callback trips the execution watchdog.
    private function removeNextOrphan() as Void {
        if (_stopped || _finished) {
            return;
        }
        while (_orphans.size() > 0) {
            var bookId = _orphans[0];
            _orphans.remove(bookId);
            var refIds = Store.localTracks(bookId).keys();
            if (refIds.size() == 0) {
                Store.forgetBook(bookId);
                continue;
            }
            _dropBook = bookId;
            _dropWholeBook = true;
            _staleRefs = refIds;
            _staleAt = 0;
            scheduleStaleDrop();
            return;
        }
        // Listening already agreed with the server is of no use for a book
        // that is not on the watch and not about to be.
        Store.pruneProgress(Store.desired(), Store.knownBooks());
        nextBook();
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
        if (_yieldArmed || _stopped || _finished) {
            return;
        }
        if (!arm(method(:onRetry), 1000)) {
            Log.warn("Sync: no retry timer");
        }
    }

    function onRetry() as Void {
        _yieldArmed = false;
        if (_stopped || _finished) {
            return;
        }
        _cancelRetries += 1;
        if (_cancelRetries > 3) {
            Log.warn("Sync: cancelled too often");
            _cancelled = true;
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
            finish(Errors.fromCode(code));
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
        _orphans = orphans(wanted);

        _bookQueue = wanted;
        _booksTotal = _bookQueue.size();
        Log.code("Sync: per playlist", _booksTotal);
        Log.code("Sync: to remove", _orphans.size());
        enterPhase(PHASE_PLAYLIST);
        removeNextOrphan();
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
            _failure = Errors.fromCode(code);
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

        // A re-cut keeps the old index and changes the length. The file on
        // the watch is the previous cut, so it has to go before the download
        // below treats that index as already present. The removal itself
        // waits for a timer: doing every file in this callback is what
        // tripped the execution watchdog.
        queueSegmentWork(bookId, segments);
    }

    //! Split the listing into files to delete and files still to download.
    //!
    //! Gone means the index is absent, or the duration in whole seconds
    //! differs. That is the same rounding the store used when it saved the
    //! track, so an unchanged segment compares equal and stays.
    private function queueSegmentWork(bookId as String, segments as Array<Dictionary>) as Void {
        var durations = serverDurations(segments);
        var facts = Store.localSegmentFacts(bookId);
        var known = [] as Array<Number>;
        _staleRefs = [] as Array;
        _staleAt = 0;
        _dropBook = bookId;
        _dropWholeBook = false;
        for (var i = 0; i < facts.size(); ++i) {
            var entry = facts[i];
            if (!(entry instanceof Dictionary)) {
                continue;
            }
            var fact = entry as Dictionary;
            var index = fact["index"];
            var duration = fact["duration"];
            if (index instanceof Number && duration instanceof Number && sameSegment(durations, index, duration)) {
                known.add(index);
                continue;
            }
            var ref = fact["ref"];
            if (ref != null) {
                _staleRefs.add(ref);
            }
        }

        _downloads = [] as Array<Dictionary>;
        _bookBytesTotal = 0.0;
        _bookBytesDone = 0.0;
        _segmentBudget = 0;
        // segments is Array<Dictionary>: only Dictionaries were accumulated above.
        for (var i = 0; i < segments.size(); ++i) {
            var segment = segments[i];
            var index = segment["index"];
            if (!(index instanceof Number)) {
                continue;
            }
            var size = numberOf(segment["bytes"]).toFloat();
            _bookBytesTotal += size;
            if (known.indexOf(index) >= 0) {
                _bookBytesDone += size;
            } else {
                _downloads.add(segment);
            }
        }
        _downloadsTotal = _downloads.size();
        _downloadsDone = 0;
        Log.debugCode("Sync: segments total", segments.size());
        Log.code("Sync: stale segments", _staleRefs.size());
        Log.code("Sync: of those to download", _downloadsTotal);
        enterPhase(PHASE_SEGMENTS);
        if (_staleRefs.size() == 0) {
            downloadNext();
            return;
        }
        scheduleStaleDrop();
    }

    //! Removes the next stale file, then waits. One cached file per call.
    function onStaleDrop() as Void {
        _yieldArmed = false;
        if (_stopped || _finished) {
            return;
        }
        var bookId = _dropBook;
        if (bookId == null || _staleAt >= _staleRefs.size()) {
            afterDrop();
            return;
        }
        var ref = _staleRefs[_staleAt];
        _staleAt += 1;
        if (ref != null) {
            Media.deleteCachedItem(new Media.ContentRef(ref, Media.CONTENT_TYPE_AUDIO));
            // A whole book is forgotten in one go at the end; there is no use
            // in rewriting its track list once per file.
            if (!_dropWholeBook) {
                Store.dropLocalTrack(bookId, ref);
            }
        }
        stirred();
        report();
        if (_staleAt < _staleRefs.size()) {
            scheduleStaleDrop();
            return;
        }
        Log.code("Sync: files removed", _staleAt);
        afterDrop();
    }

    //! What follows the last removal: the next book that is leaving, or the
    //! download of the current one.
    private function afterDrop() as Void {
        var bookId = _dropBook;
        _staleRefs = [] as Array;
        _staleAt = 0;
        if (_dropWholeBook) {
            _dropWholeBook = false;
            if (bookId != null) {
                Store.forgetBook(bookId);
            }
            removeNextOrphan();
            return;
        }
        downloadNext();
    }

    private function scheduleStaleDrop() as Void {
        if (_yieldArmed || _stopped || _finished) {
            return;
        }
        if (!arm(method(:onStaleDrop), DROP_YIELD_MS)) {
            Log.warn("Sync: no timer to remove stale segments");
            finish(Errors.text(Rez.Strings.errCleanup));
        }
    }

    //! True when this index is on the server at the same whole-second duration.
    private function sameSegment(durations as Array, index as Number, duration as Number) as Boolean {
        if (index < 0 || index >= durations.size()) {
            return false;
        }
        var serverDuration = durations[index];
        return serverDuration instanceof Number && serverDuration == duration;
    }

    //! Whole-second duration for each server segment index. A hole stays null.
    private function serverDurations(segments as Array<Dictionary>) as Array {
        var highest = -1;
        for (var i = 0; i < segments.size(); ++i) {
            var index = segments[i]["index"];
            if (index instanceof Number && index > highest) {
                highest = index;
            }
        }
        if (highest < 0) {
            return [] as Array;
        }
        var durations = new [highest + 1];
        for (var i = 0; i < segments.size(); ++i) {
            var index = segments[i]["index"];
            if (index instanceof Number && index >= 0) {
                durations[index] = numberOf(segments[i]["duration"]);
            }
        }
        return durations;
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
            _bookBytesTotal -= numberOf(segment["bytes"]).toFloat();
            if (_bookBytesTotal < _bookBytesDone) {
                _bookBytesTotal = _bookBytesDone;
            }
            downloadNext();
            return;
        }
        _pending = segment;
        _segmentBytes = 0;
        _segmentSize = 0;
        _segmentBudget = numberOf(segment["bytes"]);
        _step = STEP_DOWNLOAD;
        Log.info("Sync: downloading " + path);
        _client.downloadSegment(
            path,
            method(:onSegmentDownloaded),
            method(:onSegmentBytes)
        );
    }

    //! Byte count during a segment. The ring is the book's bytes, so this
    //! moves it inside a long file instead of waiting for the file to finish.
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
                _failure = Errors.text(Rez.Strings.errStoreFull);
            }
            _bookBytesDone += _segmentBudget.toFloat();
        } else {
            if (segment != null && worthRetrying(code) && retrySegmentLater(segment, code)) {
                return;
            }
            // Out of attempts: the next sync only fetches the gap.
            _failure = Errors.fromCode(code);
        }
        _downloadsDone += 1;
        _segmentBytes = 0;
        _segmentSize = 0;
        _segmentBudget = 0;
        report();
        downloadNext();
    }

    //! A dropped link or a server hiccup is worth another try. A refusal in the
    //! 4xx range will answer the same way again.
    private function worthRetrying(code as Number) as Boolean {
        return code < 400 || code >= 500;
    }

    //! Puts the failed segment back at the front of the queue and tries it
    //! again after a pause. Returns false when the attempts are used up, or no
    //! timer is available, and the caller then records the failure.
    private function retrySegmentLater(segment as Dictionary, code as Number) as Boolean {
        var index = numberOf(segment["index"]);
        if (index != _attemptIndex) {
            _attemptIndex = index;
            _segmentAttempts = 0;
        }
        if (_segmentAttempts >= SEGMENT_RETRIES || _yieldArmed) {
            return false;
        }
        if (!arm(method(:onSegmentRetry), SEGMENT_RETRY_MS)) {
            Log.warn("Sync: no timer to try the segment again");
            return false;
        }
        _segmentAttempts += 1;
        Log.warnCode("Sync: segment failed, will try again, code", code);
        requeuePending();
        _segmentBytes = 0;
        _segmentSize = 0;
        _segmentBudget = 0;
        return true;
    }

    function onSegmentRetry() as Void {
        _yieldArmed = false;
        if (_stopped || _finished) {
            return;
        }
        downloadNext();
    }

    private function bookDone() as Void {
        _booksDone += 1;
        _downloadsTotal = 0;
        _downloadsDone = 0;
        _staleRefs = [] as Array;
        _staleAt = 0;
        _segmentBytes = 0;
        _segmentSize = 0;
        _segmentBudget = 0;
        _bookBytesTotal = 0.0;
        _bookBytesDone = 0.0;
        // The next book numbers its segments from zero again. The retry count
        // is only cleared when the index changes, so a leftover count for
        // segment N would apply to the next book's segment N.
        _segmentAttempts = 0;
        _attemptIndex = -1;
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
            if (_bookBytesTotal > 0.0) {
                var done = _bookBytesDone + receivedBytes();
                if (done > _bookBytesTotal) {
                    done = _bookBytesTotal;
                }
                withinBook = done / _bookBytesTotal;
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

    //! Bytes of the segment in flight, never more than its listed size.
    private function receivedBytes() as Float {
        if (_segmentBudget <= 0 || _segmentBytes <= 0) {
            return 0.0;
        }
        if (_segmentBytes >= _segmentBudget) {
            return _segmentBudget.toFloat();
        }
        return _segmentBytes.toFloat();
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
