import Toybox.Lang;
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

    function initialize() {
        _client = new ProxyClient();
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
        if (!System.getDeviceSettings().phoneConnected) {
            Log.line("Push: no phone connection");
            show(Rez.Strings.noPhone);
            return;
        }
        show(Rez.Strings.loading);
        _client.pushProgress(entries, method(:onPushed));
    }

    function onPushed(code as Number, data as Dictionary or String or Null) as Void {
        Log.code("Push: progress", code);
        if (code != 200) {
            WatchUi.switchToView(
                new MessageView("HTTP " + code.toString()), null, WatchUi.SLIDE_IMMEDIATE
            );
            return;
        }
        // Only discard after confirmed acceptance — on a failure the listening
        // progress would otherwise be gone for good.
        Store.clearProgress();
        Progress.adopt(data);
        show(Rez.Strings.progressSent);
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
