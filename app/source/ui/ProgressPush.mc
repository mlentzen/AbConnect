import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

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

    static function pending() as Number {
        return Store.pendingEntries().size();
    }

    static function rowSubtitle() as String? {
        var count = pending();
        if (count == 0) {
            return null;
        }
        return count.toString() + " " + Util.text(Rez.Strings.progressPending);
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
        schedule(method(:onAttempt), SETTLE_MS);
    }

    function onAttempt() as Void {
        _attempts += 1;
        Log.code("Push: attempt", _attempts);
        Log.debugCode("Push: ms since start", System.getTimer() - _startedMs);
        logConnection(false);
        var entries = _entries;
        if (entries == null) {
            finish(Rez.Strings.syncNothingToDo);
            return;
        }
        _requestMs = System.getTimer();
        _awaiting = true;
        schedule(method(:onAttemptTimeout), ATTEMPT_TIMEOUT_MS);
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
        } else if (code <= 0 || code >= 500) {
            retryOrGiveUp();
        } else {
            Log.errorCode("Push: refused for good", code);
            finishWith(Errors.fromCode(code));
        }
    }

    private function retryOrGiveUp() as Void {
        var outOfAttempts = _attempts >= MAX_ATTEMPTS;
        var outOfTime = elapsedMs() + RETRY_MS + ATTEMPT_TIMEOUT_MS > DEADLINE_MS;
        if (outOfAttempts || outOfTime) {
            var reason = outOfAttempts ? "Push: giving up after attempts" : "Push: out of time after attempts";
            Log.errorCode(reason, _attempts);
            logConnection(true);
            var noPhone = _lastCode == Communications.BLE_CONNECTION_UNAVAILABLE;
            finish(noPhone ? Rez.Strings.noPhone : Rez.Strings.progressNotSent);
            return;
        }
        Log.info("Push: trying again");
        schedule(method(:onAttempt), RETRY_MS);
    }

    private function schedule(callback as Method() as Void, ms as Number) as Void {
        _timer.stop();
        _timer.start(callback, ms, false);
    }

    private function elapsedMs() as Number {
        var elapsed = System.getTimer() - _startedMs;
        return (elapsed < 0) ? 0 : elapsed;
    }

    private function finish(resource as Lang.ResourceId) as Void {
        if (_announce) {
            finishWith(Util.text(resource));
        } else {
            done();
        }
    }

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
        var bookId = _resumeAfter;
        if (bookId != null) {
            Current.set(bookId);
            Log.info("Push: startPlayback " + bookId);
            Media.startPlayback(bookId);
        }
    }

    private function withAttempts(text as String) as String {
        if (_attempts <= 1) {
            return text;
        }
        return text + " (" + _attempts.toString() + " " + Util.text(Rez.Strings.tries) + ")";
    }

    private function showLoading() as Void {
        var view = new MessageView(Util.text(Rez.Strings.loading));
        _loading = view;
        WatchUi.pushView(view, new BackDelegate(), WatchUi.SLIDE_IMMEDIATE);
    }

    private static function logConnection(isError as Boolean) as Void {
        if (Log.LEVEL < (isError ? Log.ERROR : Log.DEBUG)) {
            return;
        }
        var settings = System.getDeviceSettings();
        var line = "Push: connection available " + settings.connectionAvailable.toString()
            + ", phone " + settings.phoneConnected.toString();
        if (isError) {
            Log.error(line);
        } else {
            Log.debug(line);
        }
    }
}
