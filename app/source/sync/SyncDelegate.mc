import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

class AbSyncDelegate extends Communications.SyncDelegate {

    const PHASE_START = 1;
    const PHASE_PROGRESS_PUSHED = 2;
    const PHASE_PLAYLIST = 3;
    const PHASE_SEGMENTS = 4;
    const PHASE_DOWNLOAD = 5;

    const STEP_PROGRESS = 1;
    const STEP_PLAYLIST = 2;
    const STEP_SEGMENTS = 3;
    const STEP_DOWNLOAD = 4;

    const WATCHDOG_TICK_MS = 30000;
    const WATCHDOG_MAX_IDLE_TICKS = 20;
    const DROP_YIELD_MS = 50;
    const CANCEL_RETRY_MS = 1000;
    const MAX_CANCEL_RETRIES = 3;
    const SEGMENT_RETRIES = 2;
    const SEGMENT_RETRY_MS = 3000;

    private var _client as ProxyClient;
    private var _bookQueue as Array<String>;
    private var _downloads as Array<Dictionary>;
    private var _sentEntries as Array;
    private var _pending as Dictionary?;
    private var _currentBook as String?;
    private var _segmentsAccum as Array<Dictionary>;
    private var _segmentsAfter as Number;
    private var _booksTotal as Number;
    private var _booksDone as Number;
    private var _stillPreparing as Number;
    private var _failure as String?;
    private var _stopped as Boolean;
    private var _finished as Boolean;
    private var _cancelled as Boolean;
    private var _phase as Number;
    private var _reported as Number;
    private var _segmentBytes as Number;
    private var _segmentBudget as Number;
    private var _bookBytesTotal as Float;
    private var _bookBytesDone as Float;
    private var _watchdog as Timer.Timer?;
    private var _activity as Number;
    private var _idleTicks as Number;
    private var _step as Number;
    private var _pauseTimer as Timer.Timer?;
    private var _paused as Boolean;
    private var _cancelRetries as Number;
    private var _staleRefs as Array;
    private var _staleAt as Number;
    private var _dropBook as String?;
    private var _dropWholeBook as Boolean;
    private var _orphans as Array<String>;
    private var _segmentAttempts as Number;
    private var _attemptIndex as Number;
    private var _notificationPeak as Number;
    private var _noteTimer as Timer.Timer?;

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
        _stillPreparing = 0;
        _failure = null;
        _stopped = false;
        _finished = false;
        _cancelled = false;
        _phase = 0;
        _reported = -1;
        _segmentBytes = 0;
        _segmentBudget = 0;
        _bookBytesTotal = 0.0;
        _bookBytesDone = 0.0;
        _watchdog = null;
        _activity = 0;
        _idleTicks = 0;
        _step = 0;
        _pauseTimer = null;
        _paused = false;
        _cancelRetries = 0;
        _staleRefs = [] as Array;
        _staleAt = 0;
        _dropBook = null;
        _dropWholeBook = false;
        _orphans = [] as Array<String>;
        _segmentAttempts = 0;
        _attemptIndex = -1;
        _notificationPeak = 0;
        _noteTimer = null;
    }

    function isSyncNeeded() as Boolean {
        if (Store.syncRequested()) {
            Log.info("Sync: needed, requested");
            return true;
        }
        if (Settings.followSystemSync()) {
            Log.info("Sync: needed, started by the system");
            return true;
        }
        Log.info("Sync: not needed, system sync is off");
        return false;
    }

    function onStartSync() as Void {
        Log.info("Sync: onStartSync");
        Store.clearSyncRequest();
        logEnvironment();
        enterPhase(PHASE_START);
        startWatchdog();
        startNotificationWatch();
        if (!_client.isConfigured()) {
            finish(Util.text(_client.setupProblem(Rez.Strings.errNotSetUp)));
            return;
        }
        pushProgress();
    }

    function onStopSync() as Void {
        if (_finished) {
            return;
        }
        sampleNotifications();
        var notificationDismissed = deviceNotificationCount() < _notificationPeak;
        if (Store.resumeWasCancelled() && !notificationDismissed) {
            stopForGood("Sync: onStopSync, cancelled");
            return;
        }
        if (Store.noteResume() > Store.RESUME_ECHO_LIMIT) {
            stopForGood("Sync: onStopSync, resume gave up");
            return;
        }
        Log.warn("Sync: onStopSync, resuming");
        Store.requestSync();
        complete(null);
        Communications.startSync2({ :message => Util.text(Rez.Strings.AppName) });
    }

    private function stopForGood(message as String) as Void {
        Log.warn(message);
        Store.clearResume();
        _stopped = true;
        _cancelled = true;
        Communications.cancelAllRequests();
        finish(null);
    }

    private function logEnvironment() as Void {
        var connections = System.getDeviceSettings().connectionInfo;
        Log.debugCode("Sync: Wi-Fi", connectionState(connections, :wifi));
        Log.debugCode("Sync: Bluetooth", connectionState(connections, :bluetooth));
        Log.debugCode("Sync: free memory", System.getSystemStats().freeMemory);
    }

    private function connectionState(connections as Dictionary, key as Symbol) as Number {
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

    private function complete(error as String?) as Void {
        if (_finished) {
            return;
        }
        _finished = true;
        _stopped = true;
        stopWatchdog();
        stopNotificationWatch();
        stopPause();
        Communications.notifySyncComplete(error);
    }

    private function isDone() as Boolean {
        return _stopped || _finished;
    }

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
        finish(Util.text(Rez.Strings.errNoResponse));
    }

    private function markActivity() as Void {
        _activity += 1;
    }

    private function startNotificationWatch() as Void {
        _notificationPeak = deviceNotificationCount();
        try {
            var timer = new Timer.Timer();
            timer.start(method(:onNotificationSample), 1000, true);
            _noteTimer = timer;
        } catch (ex) {
            _noteTimer = null;
        }
    }

    private function stopNotificationWatch() as Void {
        var timer = _noteTimer;
        if (timer != null) {
            timer.stop();
            _noteTimer = null;
        }
    }

    function onNotificationSample() as Void {
        sampleNotifications();
    }

    private function sampleNotifications() as Void {
        var count = deviceNotificationCount();
        if (count > _notificationPeak) {
            _notificationPeak = count;
        }
    }

    private function deviceNotificationCount() as Number {
        var settings = System.getDeviceSettings();
        if (settings has :notificationCount) {
            return settings.notificationCount;
        }
        return 0;
    }

    private function startPause(callback as Method() as Void, ms as Number) as Boolean {
        try {
            var timer = _pauseTimer;
            if (timer == null) {
                timer = new Timer.Timer();
                _pauseTimer = timer;
            }
            timer.start(callback, ms, false);
            _paused = true;
            return true;
        } catch (ex) {
            return false;
        }
    }

    private function stopPause() as Void {
        var timer = _pauseTimer;
        if (timer != null) {
            timer.stop();
        }
        _paused = false;
    }

    private function isCancelledOrStopped(code as Number) as Boolean {
        if (isDone()) {
            return true;
        }
        if (code == Communications.REQUEST_CANCELLED) {
            scheduleRetry();
            return true;
        }
        _cancelRetries = 0;
        return false;
    }

    private function scheduleRetry() as Void {
        if (_paused || isDone()) {
            return;
        }
        if (!startPause(method(:onRetry), CANCEL_RETRY_MS)) {
            Log.warn("Sync: no retry timer");
        }
    }

    function onRetry() as Void {
        _paused = false;
        if (isDone()) {
            return;
        }
        _cancelRetries += 1;
        if (_cancelRetries > MAX_CANCEL_RETRIES) {
            Log.warn("Sync: cancelled too often");
            _cancelled = true;
            finish(null);
            return;
        }
        Log.warnCode("Sync: retry", _step);
        if (_step == STEP_DOWNLOAD) {
            requeuePending();
            downloadNext();
        } else if (_step == STEP_SEGMENTS) {
            fetchSegmentsPage();
        } else if (_step == STEP_PLAYLIST) {
            fetchPlaylist();
        } else {
            pushProgress();
        }
    }

    private function requeuePending() as Void {
        var segment = _pending;
        if (!(segment instanceof Dictionary)) {
            return;
        }
        _pending = null;
        var restored = [segment] as Array<Dictionary>;
        restored.addAll(_downloads);
        _downloads = restored;
    }

    private function pushProgress() as Void {
        if (_stopped) {
            return;
        }
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
        markActivity();
        Log.response("Sync: progress", code);
        if (isCancelledOrStopped(code)) {
            return;
        }
        if (code == 200) {
            Progress.settle(_sentEntries, data);
        }
        enterPhase(PHASE_PROGRESS_PUSHED);
        fetchPlaylist();
    }

    private function fetchPlaylist() as Void {
        if (_stopped) {
            return;
        }
        Log.info("Sync: fetching playlist");
        _step = STEP_PLAYLIST;
        _client.playlist(method(:onPlaylist));
    }

    function onPlaylist(code as Number, data as Dictionary or String or Null) as Void {
        markActivity();
        Log.response("Sync: playlist", code);
        if (isCancelledOrStopped(code)) {
            return;
        }
        if (code == 409) {
            finish(Util.text(Rez.Strings.syncNoPlaylist));
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
        if (books.size() == 0) {
            finish(Util.text(Rez.Strings.playlistEmpty));
            return;
        }
        Store.rememberPlaylist(books as Array);
        var wanted = Store.desired();
        _orphans = booksNotIn(wanted);
        _bookQueue = wanted;
        _booksTotal = _bookQueue.size();
        Log.code("Sync: per playlist", _booksTotal);
        Log.code("Sync: to remove", _orphans.size());
        enterPhase(PHASE_PLAYLIST);
        removeNextOrphan();
    }

    private function booksNotIn(wanted as Array<String>) as Array<String> {
        var result = [] as Array<String>;
        var known = Store.knownBooks();
        for (var i = 0; i < known.size(); ++i) {
            if (wanted.indexOf(known[i]) < 0) {
                result.add(known[i]);
            }
        }
        return result;
    }

    private function removeNextOrphan() as Void {
        if (isDone()) {
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
            startDropping(bookId, refIds, true);
            scheduleStaleDrop();
            return;
        }
        Store.pruneProgress(Store.desired(), Store.knownBooks());
        nextBook();
    }

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

    private function fetchSegmentsPage() as Void {
        var bookId = _currentBook;
        if (bookId == null) {
            return;
        }
        _step = STEP_SEGMENTS;
        _client.segments(bookId, _segmentsAfter, method(:onSegments));
    }

    function onSegments(code as Number, data as Dictionary or String or Null) as Void {
        markActivity();
        Log.response("Sync: segments", code);
        if (isCancelledOrStopped(code)) {
            return;
        }
        if (code == 409) {
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
            if (page[i] instanceof Dictionary && inRange((page[i] as Dictionary)["index"])) {
                _segmentsAccum.add(page[i] as Dictionary);
            }
        }
        var next = data["next"];
        if (next instanceof Number && next > _segmentsAfter && _segmentsAccum.size() < Store.MAX_SEGMENTS) {
            _segmentsAfter = next;
            fetchSegmentsPage();
            return;
        }
        var segments = _segmentsAccum;
        Store.setBookInfo(
            bookId,
            Util.stringOr(data["title"], bookId),
            Util.stringOr(data["author"], ""),
            segments.size()
        );
        queueSegmentWork(bookId, segments);
    }

    private function inRange(index as Object?) as Boolean {
        return index instanceof Number && index >= 0 && index < Store.MAX_SEGMENTS;
    }

    private function queueSegmentWork(bookId as String, segments as Array<Dictionary>) as Void {
        var durations = serverDurations(segments);
        var facts = Store.localSegmentFacts(bookId);
        var kept = [] as Array<Number>;
        startDropping(bookId, [] as Array, false);
        for (var i = 0; i < facts.size(); ++i) {
            var fact = facts[i];
            var index = fact[Store.SEG_INDEX];
            var duration = fact[Store.SEG_DURATION];
            if (index instanceof Number && duration instanceof Number && sameSegment(durations, index, duration)) {
                kept.add(index);
            } else if (fact[Store.SEG_REF] != null) {
                _staleRefs.add(fact[Store.SEG_REF]);
            }
        }

        _downloads = [] as Array<Dictionary>;
        _bookBytesTotal = 0.0;
        _bookBytesDone = 0.0;
        _segmentBudget = 0;
        for (var i = 0; i < segments.size(); ++i) {
            var segment = segments[i];
            var index = segment["index"];
            if (!(index instanceof Number)) {
                continue;
            }
            var size = Util.numberOf(segment["bytes"]).toFloat();
            _bookBytesTotal += size;
            if (kept.indexOf(index) >= 0) {
                _bookBytesDone += size;
            } else {
                _downloads.add(segment);
            }
        }
        Log.debugCode("Sync: segments total", segments.size());
        Log.code("Sync: stale segments", _staleRefs.size());
        Log.code("Sync: of those to download", _downloads.size());
        enterPhase(PHASE_SEGMENTS);
        if (_staleRefs.size() == 0) {
            downloadNext();
            return;
        }
        scheduleStaleDrop();
    }

    private function sameSegment(durations as Array, index as Number, duration as Number) as Boolean {
        if (index < 0 || index >= durations.size()) {
            return false;
        }
        var serverDuration = durations[index];
        return serverDuration instanceof Number && serverDuration == duration;
    }

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
                durations[index] = Util.numberOf(segments[i]["duration"]);
            }
        }
        return durations;
    }

    private function startDropping(bookId as String, refs as Array, wholeBook as Boolean) as Void {
        _dropBook = bookId;
        _dropWholeBook = wholeBook;
        _staleRefs = refs;
        _staleAt = 0;
    }

    private function scheduleStaleDrop() as Void {
        if (_paused || isDone()) {
            return;
        }
        if (!startPause(method(:onStaleDrop), DROP_YIELD_MS)) {
            Log.warn("Sync: no timer to remove stale segments");
            finish(Util.text(Rez.Strings.errCleanup));
        }
    }

    function onStaleDrop() as Void {
        _paused = false;
        if (isDone()) {
            return;
        }
        var bookId = _dropBook;
        if (bookId == null || _staleAt >= _staleRefs.size()) {
            onStaleDropDone();
            return;
        }
        var ref = _staleRefs[_staleAt];
        _staleAt += 1;
        if (ref != null) {
            Media.deleteCachedItem(new Media.ContentRef(ref, Media.CONTENT_TYPE_AUDIO));
            Store.dropLocalTrack(bookId, ref);
        }
        markActivity();
        report();
        if (_staleAt < _staleRefs.size()) {
            scheduleStaleDrop();
            return;
        }
        Log.code("Sync: files removed", _staleAt);
        onStaleDropDone();
    }

    private function onStaleDropDone() as Void {
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
        if (!(path instanceof String) || path.find("/") != 0) {
            _bookBytesTotal -= Util.numberOf(segment["bytes"]).toFloat();
            if (_bookBytesTotal < _bookBytesDone) {
                _bookBytesTotal = _bookBytesDone;
            }
            downloadNext();
            return;
        }
        _pending = segment;
        _segmentBytes = 0;
        _segmentBudget = Util.numberOf(segment["bytes"]);
        _step = STEP_DOWNLOAD;
        Log.info("Sync: downloading " + path);
        _client.downloadSegment(path, method(:onSegmentDownloaded), method(:onSegmentBytes));
    }

    function onSegmentBytes(transferred as Number, size as Number?) as Void {
        markActivity();
        _segmentBytes = transferred;
        report();
    }

    function onSegmentDownloaded(code as Number, data as Object?) as Void {
        markActivity();
        Log.response("Sync: segment downloaded", code);
        Log.debugCode("Sync: bytes", _segmentBytes);
        if (isCancelledOrStopped(code)) {
            return;
        }
        var segment = _pending;
        var bookId = _currentBook;
        if (code == 200 && data instanceof Media.ContentRef && segment != null && bookId != null) {
            var index = Util.numberOf(segment["index"]);
            var title = Util.stringOr(segment["title"], index.toString());
            if (!Store.addLocalTrack(bookId, data.getId(), index, Util.numberOf(segment["duration"]), title)) {
                _failure = Util.text(Rez.Strings.errStoreFull);
                Media.deleteCachedItem(data);
                _downloads = [] as Array<Dictionary>;
            }
            _bookBytesDone += _segmentBudget.toFloat();
        } else {
            if (segment != null && worthRetrying(code) && retrySegmentLater(segment, code)) {
                return;
            }
            _failure = Errors.fromCode(code);
            if (code == Communications.STORAGE_FULL) {
                Log.error("Sync: media cache is full, nothing more to fetch");
                _downloads = [] as Array<Dictionary>;
                _bookQueue = [] as Array<String>;
            }
        }
        clearSegmentProgress();
        report();
        downloadNext();
    }

    private function worthRetrying(code as Number) as Boolean {
        if (code == Communications.STORAGE_FULL
            || code == Communications.SECURE_CONNECTION_REQUIRED
            || code == Communications.UNSUPPORTED_CONTENT_TYPE_IN_RESPONSE
            || code == Communications.UNABLE_TO_PROCESS_MEDIA) {
            return false;
        }
        return code < 400 || code >= 500;
    }

    private function retrySegmentLater(segment as Dictionary, code as Number) as Boolean {
        var index = Util.numberOf(segment["index"]);
        if (index != _attemptIndex) {
            _attemptIndex = index;
            _segmentAttempts = 0;
        }
        if (_segmentAttempts >= SEGMENT_RETRIES || _paused) {
            return false;
        }
        if (!startPause(method(:onSegmentRetry), SEGMENT_RETRY_MS)) {
            Log.warn("Sync: no timer to try the segment again");
            return false;
        }
        _segmentAttempts += 1;
        Log.warnCode("Sync: segment failed, will try again, code", code);
        requeuePending();
        clearSegmentProgress();
        return true;
    }

    function onSegmentRetry() as Void {
        _paused = false;
        if (isDone()) {
            return;
        }
        downloadNext();
    }

    private function clearSegmentProgress() as Void {
        _segmentBytes = 0;
        _segmentBudget = 0;
    }

    private function bookDone() as Void {
        _booksDone += 1;
        _staleRefs = [] as Array;
        _staleAt = 0;
        clearSegmentProgress();
        _bookBytesTotal = 0.0;
        _bookBytesDone = 0.0;
        _segmentAttempts = 0;
        _attemptIndex = -1;
        report();
        nextBook();
    }

    private function report() as Void {
        if (isDone()) {
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

    private function receivedBytes() as Float {
        if (_segmentBudget <= 0 || _segmentBytes <= 0) {
            return 0.0;
        }
        if (_segmentBytes >= _segmentBudget) {
            return _segmentBudget.toFloat();
        }
        return _segmentBytes.toFloat();
    }
}
