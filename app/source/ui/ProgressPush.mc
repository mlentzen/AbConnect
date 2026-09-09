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
//! Which is why neither flag is ever read before sending. Both have been tried
//! as a gate and both have been taken out again, and the second time it went
//! back in it produced "no phone connection" on a watch with a phone on the
//! table: the flag reads false in the very context this code runs in, so a gate
//! on it refuses every push and, worse, pre-empts the stopPlayback() below that
//! would have made the push work. The flags are logged, never obeyed. If a
//! future reader is tempted again: the answer is in the log, not in the flag.
//!
//! So the player is always asked to let go first. The playing mark was once
//! the trigger for that, but it says whether sound came out recently, not
//! whether the player holds the radio: a session paused hours ago, or one
//! restarted by the system, holds the connection without a mark, and that is
//! exactly the state that answers a request with -104. stopPlayback() costs
//! nothing when nothing is playing — the SDK describes it only as stopping
//! playback that the app itself started — and does not end the app the way
//! startPlayback() does, so this code survives its own call, waits for the
//! radio to return, sends, and starts the book again. The mark still decides
//! whether there is a book to start again: a session stopped although it was
//! paused for hours is not brought back to life.
//!
//! The second thing in the way is silence. makeWebRequest() does not promise a
//! callback: a request that goes out into a connection which then dies is never
//! answered and never refused, and this class had no place at which it could
//! notice. Every attempt therefore carries its own watchdog timer, and the run
//! as a whole carries a deadline — the difference between "it did not work" and
//! a screen that waits forever. Both timers are armed and stopped independently
//! and stopped again when the run ends, so a late tick can never fire into a
//! run that is over.
class ProgressPush {

    //! How long the radio is given to return once the player lets go of it.
    private const SETTLE_MS = 3000;
    //! How long an attempt may stay unanswered before it counts as failed.
    //!
    //! A push is a few hundred bytes over Bluetooth; anything that has not come
    //! back by now is not slow, it is gone. Waiting longer only postpones the
    //! retry that was going to be needed anyway.
    private const ATTEMPT_TIMEOUT_MS = 8000;
    //! How long between attempts, and how many in all.
    private const RETRY_MS = 3000;
    private const MAX_ATTEMPTS = 4;
    //! The run as a whole, however the attempts fall inside it. Someone is
    //! standing there holding their wrist up: the answer may be no, but it has
    //! to arrive.
    private const DEADLINE_MS = 45000;
    //! Long enough to read the result before the book starts again.
    private const READ_RESULT_MS = 2500;

    private var _client as ProxyClient;
    //! The retry and resume timer, and the attempt watchdog beside it: an
    //! attempt is being waited on at the same time as nothing else, but the
    //! two are armed and stopped independently and sharing one would have each
    //! cancel the other.
    private var _timer as Timer.Timer;
    private var _watchdog as Timer.Timer;
    private var _attempts as Number;
    //! Whether a request is out and still owed an answer. What makes a reply
    //! that arrives after its watchdog gave up harmless.
    private var _awaiting as Boolean;
    //! The last thing the radio said, or 0 if it has not said anything yet.
    //! What the closing message is drawn from — "no phone" is a conclusion to
    //! reach after asking, not a precondition to check before.
    private var _lastCode as Number;

    //! The book to start again when this is over, or null to stay put.
    private var _resumeAfter as String?;
    //! Whether the outcome belongs on screen. The Resume row says nothing and
    //! simply plays; the menu row reports what happened.
    private var _announce as Boolean;
    //! A book to ask the server about even when nothing of it is buffered.
    private var _extra as String?;
    //! Whether this run already asked the player to let go of the radio.
    private var _stoppedPlayback as Boolean;
    //! What the run reports, frozen before stopPlayback() has a chance to
    //! touch the store, or null when there is nothing to send. Sent verbatim
    //! on every attempt; the store itself is not read again.
    private var _entries as Array?;
    //! When the run began and when the current request left. An answer that
    //! comes back within milliseconds was refused on the watch itself — it
    //! never had a route out. A slow one went somewhere and failed there.
    private var _startedMs as Number;
    private var _requestMs as Number;

    function initialize() {
        _client = new ProxyClient();
        _timer = new Timer.Timer();
        _watchdog = new Timer.Timer();
        _attempts = 0;
        _awaiting = false;
        _lastCode = 0;
        _resumeAfter = null;
        _announce = true;
        _extra = null;
        _stoppedPlayback = false;
        _entries = null;
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
            Log.error("Push: not configured");
            finish(Rez.Strings.notConfigured);
            return;
        }
        _startedMs = System.getTimer();
        _stoppedPlayback = false;
        _awaiting = false;
        if (Log.LEVEL >= Log.DEBUG) {
            var markAge = Store.playingMarkAge();
            Log.debug(
                "Push: playing mark "
                    + ((markAge == null) ? "absent" : markAge.toString() + " s old")
            );
        }
        // The watch's position is frozen before stopPlayback() can touch the
        // store: stopping fires a STOP event that makes the player write its
        // own position over ours, so whatever the run sends has to be read
        // first. Read at the attempt instead, as it once was, and a paused
        // player that wakes up to stop sends its stale position back instead
        // of the fresh one this run was started to report. Every attempt
        // resends this same snapshot; only what was sent is cleared at the
        // end.
        var extra = _extra;
        _entries = (extra == null) ? Store.progressEntries() : entriesIncluding(extra);
        if (_entries.size() == 0) {
            _entries = null;
            finish(Rez.Strings.syncNothingToDo);
            return;
        }
        Log.debugCode("Push: buffered books", _entries.size());
        // Unconditional, mark or no mark: the mark says whether sound came
        // out, not whether the player holds the radio, and a session paused
        // hours ago or restarted by the system holds it without one. The mark
        // still decides whether there is a book of ours to start again
        // afterwards — a session stopped although it was paused for hours is
        // not brought back to life.
        if (Store.isPlaying() && _resumeAfter == null) {
            _resumeAfter = Current.bookId();
        }
        Log.info("Push: stopping playback to free the radio");
        _stoppedPlayback = true;
        Media.stopPlayback();
        _attempts = 0;
        show(Rez.Strings.loading);
        _timer.start(method(:onAttempt), SETTLE_MS, false);
    }

    function onAttempt() as Void {
        _attempts += 1;
        Log.code("Push: attempt", _attempts);
        Log.debugCode("Push: ms since start", System.getTimer() - _startedMs);
        logConnection(Log.DEBUG);
        // No flag is consulted before sending, and this is the third time that
        // has had to be learned. phoneConnected and connectionAvailable were
        // each tried as a gate and each refused a setup that worked: in the
        // media player context this app runs in, both read false while a
        // request sent anyway goes through as soon as the player lets go of the
        // radio. Whatever they mean on this device, neither means "a request
        // would fail" — so the request goes out and the radio answers. Its
        // answer is evidence; a flag read beforehand is a guess.
        var entries = _entries;
        if (entries == null) {
            // Cannot happen after begin(): a run with nothing to send ends
            // there. Guarded rather than trusted, because the watchdog and
            // the retry timer share this entry point.
            finish(Rez.Strings.syncNothingToDo);
            return;
        }
        _requestMs = System.getTimer();
        _awaiting = true;
        _watchdog.start(method(:onAttemptTimeout), ATTEMPT_TIMEOUT_MS, false);
        _client.pushProgress(entries, method(:onPushed));
    }

    //! An attempt that was never answered.
    //!
    //! makeWebRequest() gives no guarantee of a callback, and a request lost in
    //! a connection that died takes the whole run with it — this is the only
    //! place that can notice. The request is cancelled before the next attempt
    //! so that a stale one cannot come back mid-retry and be mistaken for the
    //! answer to it.
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
            // The watchdog already wrote this attempt off and moved on. Acting
            // on it now would run finish() a second time and call
            // startPlayback() twice over.
            Log.warnCode("Push: an answer arrived after its attempt was given up", code);
            return;
        }
        _awaiting = false;
        _watchdog.stop();
        _lastCode = code;
        Log.response("Push: progress", code);
        Log.debugCode("Push: answer after ms", System.getTimer() - _requestMs);
        if (code == 200) {
            // Only discard after confirmed acceptance, and only what was sent:
            // a position buffered while the request was out stays for the next
            // push. Clearing everything would take it with the rest.
            var sent = _entries;
            if (sent != null) {
                Store.clearSent(sent);
            }
            Progress.adopt(data);
            finish(Rez.Strings.progressSent);
            return;
        }
        if (retryable(code)) {
            retryOrGiveUp();
            return;
        }
        // A code the server chose and meant: 401, 404, 409. A second attempt
        // would be refused in exactly the same way, so the number goes on
        // screen instead of into another fifteen seconds of waiting.
        Log.errorCode("Push: refused for good", code);
        finishWith("HTTP " + code.toString());
    }

    //! Whether trying the same thing again could plausibly work.
    //!
    //! A negative code is the radio's, not the server's: no route out, and the
    //! connection may still be coming back after the player let go of it. A 0
    //! is a request that got nowhere at all. 5xx is the proxy having a bad
    //! moment — restarting, or waiting on Audiobookshelf.
    private static function retryable(code as Number) as Boolean {
        return code <= 0 || code >= 500;
    }

    //! One attempt has failed. Decide whether there is another.
    private function retryOrGiveUp() as Void {
        if (_attempts >= MAX_ATTEMPTS) {
            Log.errorCode("Push: giving up after attempts", _attempts);
            // The state of the connections at the moment of failure, at the
            // level a default build still prints. Without it the log says the
            // push failed and nothing about what the watch thought it had —
            // which is the whole of the evidence for why.
            logConnection(Log.ERROR);
            finish(verdict());
            return;
        }
        // The next attempt has to fit inside what is left, not merely start
        // inside it — otherwise the deadline is a suggestion.
        if (elapsedMs() + RETRY_MS + ATTEMPT_TIMEOUT_MS > DEADLINE_MS) {
            Log.errorCode("Push: out of time after attempts", _attempts);
            logConnection(Log.ERROR);
            finish(verdict());
            return;
        }
        Log.info("Push: trying again");
        _timer.start(method(:onAttempt), RETRY_MS, false);
    }

    //! What to put on screen once the attempts are spent.
    //!
    //! "No phone connection" is said only when the radio itself said so: the
    //! last answer being BLE_CONNECTION_UNAVAILABLE is what no route out looks
    //! like, and the one case in which naming the phone is honest. Everything
    //! else — a timeout, a server that refused, a request that went nowhere —
    //! failed for a reason the wearer cannot mend by fetching their phone, and
    //! saying otherwise sends them after the wrong thing.
    private function verdict() as Lang.ResourceId {
        if (_lastCode == Communications.BLE_CONNECTION_UNAVAILABLE) {
            return Rez.Strings.noPhone;
        }
        return Rez.Strings.progressNotSent;
    }

    //! How long this run has been going.
    //!
    //! Kept as a difference rather than as an absolute deadline because
    //! System.getTimer() counts from device start and wraps: an absolute
    //! deadline computed just before the wrap lands in the past, and the run
    //! would give up on its first hiccup. A run caught by the wrap simply gets
    //! its full time over again, which is the harmless way to be wrong.
    private function elapsedMs() as Number {
        var elapsed = System.getTimer() - _startedMs;
        return (elapsed < 0) ? 0 : elapsed;
    }

    private function finish(resource as Lang.ResourceId) as Void {
        // Loaded only if it will be read: the Resume row says nothing and
        // simply plays.
        if (!_announce) {
            done();
            return;
        }
        finishWith(WatchUi.loadResource(resource) as String);
    }

    //! Every announced ending goes through here, so the attempt count can never
    //! be on the good news and missing from the bad.
    private function finishWith(text as String) as Void {
        if (_announce) {
            WatchUi.switchToView(new MessageView(withAttempts(text)), null, WatchUi.SLIDE_IMMEDIATE);
        }
        done();
    }

    //! The run is over, whichever way it went: nothing more is owed an answer,
    //! and the book goes back on.
    private function done() as Void {
        _awaiting = false;
        _stoppedPlayback = false;
        _timer.stop();
        _watchdog.stop();
        resume();
    }

    //! "Progress sent (3 tries)". Silent about a run that worked first time —
    //! there is nothing to report about the normal case, and the count is only
    //! interesting as the answer to "why did that take so long".
    private function withAttempts(text as String) as String {
        if (_attempts <= 1) {
            return text;
        }
        return text + " (" + _attempts.toString()
            + " " + (WatchUi.loadResource(Rez.Strings.tries) as String) + ")";
    }

    //! Whatever happened, the book goes back on.
    private function resume() as Void {
        if (_resumeAfter == null) {
            Log.debug("Push: nothing to start again");
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
        Log.info("Push: startPlayback " + bookId);
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
        Log.debug("Push: asking about " + bookId + " with nothing of our own");
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
    //! be read next to each other.
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
