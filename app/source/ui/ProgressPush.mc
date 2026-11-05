import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// A symbol, so it never collides with book IDs (always strings).
const PROGRESS_ITEM = :sendProgress;

//! Syncs positions both ways over the phone connection, without a full sync.
//!
//! The player holds the phone connection, so it is stopped first. The
//! connection flags are not consulted: they read false in the player context.
//! All pauses and watchdogs share one Timer, since exceeding the device's
//! active timer limit is a fatal error.
class ProgressPush {

    private const SETTLE_MS = 3000;
    private const ATTEMPT_TIMEOUT_MS = 8000;
    private const RETRY_MS = 3000;
    private const MAX_ATTEMPTS = 4;
    private const DEADLINE_MS = 45000;
    private const READ_RESULT_MS = 2500;

    private var _client as ProxyClient;
    private var _timer as Timer.Timer;
    private var _attempts as Number;
    private var _awaiting as Boolean;
    private var _lastCode as Number;

    private var _resumeAfter as String?;
    private var _announce as Boolean;
    private var _ask as Array<String>;
    // Frozen before stopPlayback() can touch the store; every attempt resends it.
    private var _entries as Array?;
    private var _loading as MessageView?;
    private var _startedMs as Number;
    private var _requestMs as Number;

    function initialize() {
        _client = new ProxyClient();
        _timer = new Timer.Timer();
        _attempts = 0;
        _awaiting = false;
        _lastCode = 0;
        _resumeAfter = null;
        _announce = true;
        _ask = [] as Array<String>;
        _entries = null;
        _loading = null;
        _startedMs = 0;
        _requestMs = 0;
    }

    function start() as Void {
        _announce = true;
        _resumeAfter = null;
        _ask = Store.localBooks();
        begin();
    }

    function syncThenPlay(bookId as String) as Void {
        _announce = false;
        _resumeAfter = bookId;
        _ask = [bookId] as Array<String>;
        begin();
    }

    private function begin() as Void {
        _entries = null;
        _loading = null;
        if (!_client.isConfigured()) {
            Log.error("Push: not configured");
            finish(Rez.Strings.notConfigured);
            return;
        }
        _startedMs = System.getTimer();
        _awaiting = false;
        // Before stopPlayback(): its STOP event overwrites the stored position.
        var entries = Store.syncEntries(_ask);
        if (entries.size() == 0) {
            finish(Rez.Strings.syncNothingToDo);
            return;
        }
        _entries = entries;
        Log.debugCode("Push: entries", entries.size());
        Log.info("Push: stopping playback to free the radio");
        Media.stopPlayback();
        _attempts = 0;
        showLoading();
        arm(method(:onAttempt), SETTLE_MS);
    }

    function onAttempt() as Void {
        _attempts += 1;
        Log.code("Push: attempt", _attempts);
        Log.debugCode("Push: ms since start", System.getTimer() - _startedMs);
        logConnection(Log.DEBUG);
        var entries = _entries;
        if (entries == null) {
            finish(Rez.Strings.syncNothingToDo);
            return;
        }
        _requestMs = System.getTimer();
        _awaiting = true;
        arm(method(:onAttemptTimeout), ATTEMPT_TIMEOUT_MS);
        _client.pushProgress(entries, method(:onPushed));
    }

    function onAttemptTimeout() as Void {
        if (!_awaiting) {
            return;
        }
        _awaiting = false;
        _lastCode = 0;
        Log.errorCode("Push: no answer within ms", ATTEMPT_TIMEOUT_MS);
        Communications.cancelAllRequests();
        retryOrGiveUp();
    }

    function onPushed(code as Number, data as Dictionary or String or Null) as Void {
        if (!_awaiting) {
            Log.warnCode("Push: an answer arrived after its attempt was given up", code);
            return;
        }
        _awaiting = false;
        _timer.stop();
        _lastCode = code;
        Log.response("Push: progress", code);
        Log.debugCode("Push: answer after ms", System.getTimer() - _requestMs);
        if (code == 200) {
            var sent = _entries;
            if (sent != null) {
                Progress.settle(sent, data);
            }
            finish(Rez.Strings.progressSent);
            return;
        }
        if (retryable(code)) {
            retryOrGiveUp();
            return;
        }
        Log.errorCode("Push: refused for good", code);
        finishWith("HTTP " + code.toString());
    }

    private static function retryable(code as Number) as Boolean {
        return code <= 0 || code >= 500;
    }

    private function retryOrGiveUp() as Void {
        if (_attempts >= MAX_ATTEMPTS) {
            Log.errorCode("Push: giving up after attempts", _attempts);
            logConnection(Log.ERROR);
            finish(verdict());
            return;
        }
        if (elapsedMs() + RETRY_MS + ATTEMPT_TIMEOUT_MS > DEADLINE_MS) {
            Log.errorCode("Push: out of time after attempts", _attempts);
            logConnection(Log.ERROR);
            finish(verdict());
            return;
        }
        Log.info("Push: trying again");
        arm(method(:onAttempt), RETRY_MS);
    }

    // Stopping first replaces the pending callback instead of adding a timer.
    private function arm(callback as Method() as Void, ms as Number) as Void {
        _timer.stop();
        _timer.start(callback, ms, false);
    }

    private function verdict() as Lang.ResourceId {
        if (_lastCode == Communications.BLE_CONNECTION_UNAVAILABLE) {
            return Rez.Strings.noPhone;
        }
        return Rez.Strings.progressNotSent;
    }

    // A difference, because System.getTimer() wraps.
    private function elapsedMs() as Number {
        var elapsed = System.getTimer() - _startedMs;
        return (elapsed < 0) ? 0 : elapsed;
    }

    private function finish(resource as Lang.ResourceId) as Void {
        if (!_announce) {
            done();
            return;
        }
        finishWith(WatchUi.loadResource(resource) as String);
    }

    // Replaces the wait view only while it is on top; after BACK that would
    // replace the menu.
    private function finishWith(text as String) as Void {
        if (_announce) {
            var result = new MessageView(withAttempts(text));
            result.closeAfter(READ_RESULT_MS);
            var loading = _loading;
            if (loading != null && loading.isShown()) {
                WatchUi.switchToView(result, new BackDelegate(), WatchUi.SLIDE_IMMEDIATE);
            } else {
                WatchUi.pushView(result, new BackDelegate(), WatchUi.SLIDE_IMMEDIATE);
            }
        }
        done();
    }

    private function done() as Void {
        _awaiting = false;
        _loading = null;
        _timer.stop();
        resume();
    }

    private function withAttempts(text as String) as String {
        if (_attempts <= 1) {
            return text;
        }
        return text + " (" + _attempts.toString()
            + " " + (WatchUi.loadResource(Rez.Strings.tries) as String) + ")";
    }

    private function resume() as Void {
        var bookId = _resumeAfter;
        if (bookId == null) {
            Log.debug("Push: nothing to start");
            return;
        }
        Current.set(bookId);
        Log.info("Push: startPlayback " + bookId);
        Media.startPlayback(bookId);
    }

    private static function logConnection(level as Number) as Void {
        if (Log.LEVEL < level) {
            return;
        }
        var settings = System.getDeviceSettings();
        var line = "Push: connection available " + settings.connectionAvailable.toString()
            + ", phone " + settings.phoneConnected.toString();
        if (level <= Log.ERROR) {
            Log.error(line);
        } else {
            Log.debug(line);
        }
    }

    private function showLoading() as Void {
        var view = new MessageView(WatchUi.loadResource(Rez.Strings.loading) as String);
        _loading = view;
        WatchUi.pushView(view, new BackDelegate(), WatchUi.SLIDE_IMMEDIATE);
    }

    static function pending() as Number {
        return Store.pendingEntries().size();
    }

    static function rowSubtitle() as String? {
        var count = pending();
        if (count == 0) {
            return null;
        }
        return count.toString() + " " + (WatchUi.loadResource(Rez.Strings.progressPending) as String);
    }
}
