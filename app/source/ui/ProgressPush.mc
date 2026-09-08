import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.WatchUi;

//! Identifier of the send-progress entry. A symbol, so it can never collide
//! with a book ID — those are always strings.
const PROGRESS_ITEM = :sendProgress;

//! Sending the buffered listening progress over the phone connection.
//!
//! The small sibling of the sync: positions only, no downloads, no sync mode.
//! It never calls Communications.startSync() — that call is the one thing in
//! this app that puts the watch into sync mode, which is where the system
//! brings Wi-Fi up. What is left is a plain web request, the same one that
//! already goes out when playback pauses.
//!
//! The SDK says a web request "can be used when connected to WiFi or a mobile
//! device over Bluetooth" and offers no way to insist on one of them. The
//! phone check below is as close as the platform gets: it only sends when the
//! phone connection is there, and nothing here ever brings Wi-Fi up.
class ProgressPush {

    private var _client as ProxyClient;
    private var _playAfter as String?;

    function initialize() {
        _client = new ProxyClient();
        _playAfter = null;
    }

    //! Agree with the server first, then play — the Resume row.
    //!
    //! Nothing here may keep a book from being listened to. Every way this can
    //! fail ends where success ends: startPlayback() with whatever position the
    //! watch holds. Being off the network is not a reason to be unable to hear
    //! a book that is already on the watch.
    function syncThenPlay(bookId as String) as Void {
        _playAfter = bookId;
        if (!_client.isConfigured()) {
            Log.line("Push: not configured, playing the local position");
            play();
            return;
        }
        logConnection();
        show(Rez.Strings.loading);
        _client.pushProgress(entriesIncluding(bookId), method(:onSyncedForPlay));
    }

    function onSyncedForPlay(code as Number, data as Dictionary or String or Null) as Void {
        Log.code("Push: agreed with the server", code);
        if (code == 200) {
            Store.clearProgress();
            Progress.adopt(data);
        }
        play();
    }

    private function play() as Void {
        var bookId = _playAfter;
        if (bookId == null) {
            return;
        }
        Current.set(bookId);
        // startPlayback() ends the app and restarts it in playback mode;
        // anything after it would no longer run.
        Log.line("Push: startPlayback " + bookId);
        Media.startPlayback(bookId);
    }

    //! The buffered entries, with this book among them whatever happens.
    //!
    //! /v1/progress answers only about the books it was sent, so a book with
    //! nothing buffered would be pushed and nothing learned back about the one
    //! that is about to play. Sent with timestamp 0, it loses every
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

    //! Everything that can go wrong before a byte moves says so on screen.
    //!
    //! A press that appears to do nothing is indistinguishable from a press
    //! that failed, and this one is pressed precisely when someone wants to
    //! know their progress is safe.
    function start() as Void {
        if (!_client.isConfigured()) {
            Log.line("Push: not configured");
            show(Rez.Strings.notConfigured);
            return;
        }
        var entries = Store.progressEntries();
        Log.code("Push: buffered books", entries.size());
        if (entries.size() == 0) {
            show(Rez.Strings.syncNothingToDo);
            return;
        }
        logConnection();
        show(Rez.Strings.loading);
        _client.pushProgress(entries, method(:onPushed));
    }

    function onPushed(code as Number, data as Dictionary or String or Null) as Void {
        Log.code("Push: progress", code);
        if (code != 200) {
            // A negative code is the radio's, not the server's: no route out.
            // Only then is "no connection" the honest thing to say — before the
            // attempt it was a guess, and twice it was a wrong one.
            if (code < 0) {
                show(Rez.Strings.noPhone);
            } else {
                WatchUi.switchToView(
                    new MessageView("HTTP " + code.toString()), null, WatchUi.SLIDE_IMMEDIATE
                );
            }
            return;
        }
        // Only discard after confirmed acceptance — on a failure the listening
        // progress would otherwise be gone for good.
        Store.clearProgress();
        Progress.adopt(data);
        show(Rez.Strings.progressSent);
    }

    //! What the device says about its connections, next to what it then does.
    //!
    //! Both flags were once used to refuse the attempt, and both turned out to
    //! be telling the truth: launched from the media player, this watch reports
    //! connectionAvailable false and phoneConnected false, and the request that
    //! goes out anyway comes back -104, BLE_CONNECTION_UNAVAILABLE. There is no
    //! route out of that context, and the flags said so.
    //!
    //! The request is sent regardless, because the radio's answer is worth more
    //! than the prediction: it distinguishes no route (-104) from a server that
    //! answered badly, and it costs nothing — the failure comes back at once.
    //! The flags are logged beside it so the two can always be compared.
    private static function logConnection() as Void {
        var settings = System.getDeviceSettings();
        Log.line(
            "Push: connection available " + settings.connectionAvailable.toString()
                + ", phone " + settings.phoneConnected.toString()
        );
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
