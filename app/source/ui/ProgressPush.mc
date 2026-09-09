import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! Identifier of the send-progress entry. A symbol, so it can never collide
//! with a book ID — those are always strings.
const PROGRESS_ITEM = :sendProgress;

//! Getting the listening progress to the server without a sync.
//!
//! The small sibling of the Wi-Fi sync: positions only, no downloads, no sync
//! mode. It never calls Communications.startSync(), the one call in this app
//! that puts the watch into sync mode and so brings Wi-Fi up.
//!
//! What stood in the way is that the media player holds the phone connection.
//! Launched from the player, this app reports connectionAvailable false and
//! phoneConnected false, and a request sent anyway comes back -104,
//! BLE_CONNECTION_UNAVAILABLE, with a phone sitting right there. Both flags
//! were honest; there really was no route.
//!
//! So the player is asked to let go first. stopPlayback() does not end the app
//! the way startPlayback() does — the SDK describes it only as stopping
//! playback that the app itself started — so this code survives its own call,
//! waits for the radio to return, sends, and starts the book again.
//!
//! The playing mark alone does not cover this: it says whether sound is
//! coming out, not whether the player holds the radio. A session paused hours
//! ago has no mark and still holds the connection — the push then fails with
//! -104 although "nothing is playing". So a refusal with no route gets one
//! reactive stopPlayback() even when the mark said there was nothing to stop.
class ProgressPush {

    //! How long the radio is given to return once the player lets go of it.
    private const SETTLE_MS = 3000;
    //! How long between further attempts, and how many in all: about fifteen
    //! seconds before giving up.
    private const RETRY_MS = 3000;
    private const MAX_ATTEMPTS = 5;
    //! Long enough to read the result before the book starts again.
    private const READ_RESULT_MS = 2500;

    private var _client as ProxyClient;
    private var _timer as Timer.Timer;
    private var _attempts as Number;
    //! The book to start again when this is over, or null to stay put.
    private var _resumeAfter as String?;
    //! Whether the outcome belongs on screen. The Resume row says nothing and
    //! simply plays; the menu row reports what happened.
    private var _announce as Boolean;
    //! A book to ask the server about even when nothing of it is buffered.
    private var _extra as String?;
    //! Whether this run already asked the player to let go of the radio.
    private var _stoppedPlayback as Boolean;
    //! When the run began and when the current request left. An answer that
    //! comes back within milliseconds was refused on the watch itself — it
    //! never had a route out. A slow one went somewhere and failed there.
    private var _startedMs as Number;
    private var _requestMs as Number;

    function initialize() {
        _client = new ProxyClient();
        _timer = new Timer.Timer();
        _attempts = 0;
        _resumeAfter = null;
        _announce = true;
        _extra = null;
        _stoppedPlayback = false;
        _startedMs = 0;
        _requestMs = 0;
    }

    //! The menu row.
    //!
    //! Everything that happens says so on screen: a press that appears to do
    //! nothing cannot be told from one that failed, and this is pressed
    //! precisely when someone wants to know their progress is safe.
    function start() as Void {
        _announce = true;
        _resumeAfter = null;
        _extra = null;
        begin();
    }

    //! The Resume row: agree with the server, then play.
    //!
    //! Nothing here may keep a book from being listened to. Every way this can
    //! fail ends where success ends — at startPlayback(), with whatever
    //! position the watch holds. Being off the network is not a reason to be
    //! unable to hear a book that is already on the watch.
    function syncThenPlay(bookId as String) as Void {
        _announce = false;
        // This book plays whatever happens, so it is what we come back to —
        // not whatever happened to be playing before.
        _resumeAfter = bookId;
        _extra = bookId;
        begin();
    }

    //! Free the radio, then send.
    private function begin() as Void {
        if (!_client.isConfigured()) {
            Log.line("Push: not configured");
            finish(Rez.Strings.notConfigured);
            return;
        }
        _startedMs = System.getTimer();
        _stoppedPlayback = false;
        var markAge = Store.playingMarkAge();
        Log.line(
            "Push: playing mark "
                + ((markAge == null) ? "absent" : markAge.toString() + " s old")
        );
        if (Store.isPlaying()) {
            // stopPlayback() only ever stops what this app started, so the mark
            // is what says there is anything of ours to stop — and what says
            // there is something to start again afterwards.
            Log.line("Push: stopping playback to free the radio");
            if (_resumeAfter == null) {
                _resumeAfter = Current.bookId();
            }
            _stoppedPlayback = true;
            Media.stopPlayback();
        } else {
            Log.line("Push: nothing playing, the radio should already be free");
        }
        _attempts = 0;
        show(Rez.Strings.loading);
        // The entries are read at the attempt rather than here: stopping fires
        // a STOP event that writes the position, and reading before that lands
        // would send a position several seconds out of date.
        _timer.start(method(:onAttempt), SETTLE_MS, false);
    }

    function onAttempt() as Void {
        _attempts += 1;
        Log.code("Push: attempt", _attempts);
        Log.code("Push: ms since start", System.getTimer() - _startedMs);
        logConnection();
        if (!System.getDeviceSettings().phoneConnected) {
            // The BLE link is down — retrying cannot fix that, the phone has to
            // come back on its own. Say so instead of counting through attempts.
            Log.line("Push: phone not connected, giving up");
            finish(Rez.Strings.noPhone);
            return;
        }
        var extra = _extra;
        var entries = (extra == null) ? Store.progressEntries() : entriesIncluding(extra);
        Log.code("Push: buffered books", entries.size());
        if (entries.size() == 0) {
            finish(Rez.Strings.syncNothingToDo);
            return;
        }
        _requestMs = System.getTimer();
        _client.pushProgress(entries, method(:onPushed));
    }

    function onPushed(code as Number, data as Dictionary or String or Null) as Void {
        Log.code("Push: progress", code);
        Log.code("Push: answer after ms", System.getTimer() - _requestMs);
        if (code == 200) {
            // Only discard after confirmed acceptance — on a failure the
            // listening progress would otherwise be gone for good.
            Store.clearProgress();
            Progress.adopt(data);
            finish(Rez.Strings.progressSent);
            return;
        }
        // Refused with no route although nothing was stopped? Then a player
        // session the mark does not know about — paused long ago, or restarted
        // by the system — is holding the radio. Ask it to let go, once per
        // run. Nothing is resumed here on purpose: the mark said nothing was
        // playing, so there is nothing to start again.
        if (code == Communications.BLE_CONNECTION_UNAVAILABLE
                && !_stoppedPlayback && _attempts < MAX_ATTEMPTS
                && System.getDeviceSettings().phoneConnected) {
            Log.line("Push: no route with nothing playing, stopping playback after all");
            _stoppedPlayback = true;
            Media.stopPlayback();
            _timer.start(method(:onAttempt), SETTLE_MS, false);
            return;
        }
        // A negative code is the radio's, not the server's: no route out. That
        // is the one worth waiting on, because the connection may still be
        // coming back after the player let go of it.
        if (code < 0 && _attempts < MAX_ATTEMPTS) {
            Log.line("Push: no route yet, trying again");
            _timer.start(method(:onAttempt), RETRY_MS, false);
            return;
        }
        if (code < 0) {
            finish(Rez.Strings.noPhone);
            return;
        }
        finishWith("HTTP " + code.toString());
    }

    private function finish(resource as Lang.ResourceId) as Void {
        if (_announce) {
            show(resource);
        }
        resume();
    }

    private function finishWith(text as String) as Void {
        if (_announce) {
            WatchUi.switchToView(new MessageView(text), null, WatchUi.SLIDE_IMMEDIATE);
        }
        resume();
    }

    //! Whatever happened, the book goes back on.
    private function resume() as Void {
        if (_resumeAfter == null) {
            Log.line("Push: nothing to start again");
            return;
        }
        if (!_announce) {
            onResume();
            return;
        }
        // startPlayback() ends this app at once, and a result nobody has read
        // yet would go with it. When there is something on screen it gets its
        // moment first.
        _timer.start(method(:onResume), READ_RESULT_MS, false);
    }

    function onResume() as Void {
        var bookId = _resumeAfter;
        if (bookId == null) {
            return;
        }
        Current.set(bookId);
        // startPlayback() ends the app and restarts it in playback mode;
        // anything after it would no longer run. Where it resumes from is
        // whatever the store now holds — our position, or the server's if the
        // push just found it ahead.
        Log.line("Push: startPlayback " + bookId);
        Media.startPlayback(bookId);
    }

    //! The buffered entries, with this book among them whatever happens.
    //!
    //! /v1/progress answers only about the books it was sent, so a book with
    //! nothing buffered would be pushed and nothing learned back about the one
    //! that is about to play. Sent with timestamp 0 it loses every
    //! reconciliation on purpose: whatever the server holds wins.
    private static function entriesIncluding(bookId as String) as Array {
        var entries = Store.progressEntries();
        for (var i = 0; i < entries.size(); ++i) {
            var known = entries[i]["book_id"];
            if (known instanceof String && bookId.equals(known)) {
                return entries;
            }
        }
        Log.line("Push: asking about " + bookId + " with nothing of our own");
        entries.add({
            "book_id" => bookId,
            "segment" => 0,
            "offset" => 0,
            "ts" => 0
        });
        return entries;
    }

    //! What the device says about its connections, beside what it then does.
    //!
    //! Both flags were once used to refuse the attempt outright, and both were
    //! telling the truth — there was no route out of the media player. They are
    //! logged rather than obeyed so that the claim and the outcome can always
    //! be read next to each other. The per-connection states join them: the
    //! flags say "no", the states say whether "no" means the phone is gone or
    //! the radio is busy.
    private static function logConnection() as Void {
        var settings = System.getDeviceSettings();
        Log.line(
            "Push: connection available " + settings.connectionAvailable.toString()
                + ", phone " + settings.phoneConnected.toString()
        );
        var connections = settings.connectionInfo;
        Log.line(
            "Push: bluetooth " + connectionState(connections, :bluetooth)
                + ", wifi " + connectionState(connections, :wifi)
                + ", lte " + connectionState(connections, :lte)
        );
    }

    //! One connection's state as a word, or "absent" when the device does not
    //! have that path at all.
    private static function connectionState(connections as Dictionary, key as Symbol) as String {
        var info = connections[key];
        if (!(info instanceof System.ConnectionInfo)) {
            return "absent";
        }
        if (info.state == System.CONNECTION_STATE_CONNECTED) {
            return "connected";
        }
        if (info.state == System.CONNECTION_STATE_NOT_CONNECTED) {
            return "not connected";
        }
        return "not initialized";
    }

    private static function show(resource as Lang.ResourceId) as Void {
        WatchUi.switchToView(
            new MessageView(WatchUi.loadResource(resource) as String),
            null,
            WatchUi.SLIDE_IMMEDIATE
        );
    }

    //! How many books are waiting to be reported, for the row that offers this.
    static function pending() as Number {
        return Store.progressEntries().size();
    }
}
