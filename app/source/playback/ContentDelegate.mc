import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.Time;

//! Link to the system player.
//!
//! The position is remembered on every event. On pause it additionally tries
//! to report it immediately over the phone connection — that is the only
//! moment during playback when a radio access disturbs nobody. If it fails,
//! everything stays buffered and goes out on the next sync over Wi-Fi. Nothing
//! is lost in the process.
class AbContentDelegate extends Media.ContentDelegate {

    //! Pause and resume come in series; without a throttle the radio would run along.
    private const PUSH_THROTTLE_SECONDS = 30;

    private var _iterator as AbContentIterator?;
    private var _bookId as String?;
    private var _client as ProxyClient;
    private var _lastPush as Number;
    private var _pushing as Boolean;
    private var _lastEvent as Number;

    function initialize() {
        ContentDelegate.initialize();
        _client = new ProxyClient();
        _lastPush = 0;
        _pushing = false;
        _lastEvent = System.getTimer();
        _bookId = Current.bookId();
        if (_bookId == null) {
            var books = Store.localBooks();
            if (books.size() > 0) {
                _bookId = books[0];
            }
        }
        Log.line("Playback: book " + ((_bookId == null) ? "none" : _bookId));
        resetContentIterator();
    }

    function getContentIterator() as Media.ContentIterator? {
        // A null iterator goes back to the system as soon as there is no book.
        // Whether it can cope with that, only the watch will tell.
        Log.line("Playback: getContentIterator " + ((_iterator == null) ? "null" : "present"));
        return _iterator;
    }

    function resetContentIterator() as Media.ContentIterator? {
        Log.line("Playback: resetContentIterator");
        if (_bookId != null) {
            _iterator = new AbContentIterator(_bookId);
        }
        Log.line("Playback: iterator " + ((_iterator == null) ? "null" : "present"));
        return _iterator;
    }

    function onSong(
        contentRefId as Object, songEvent as Media.SongEvent, playbackPosition as Number or Media.PlaybackPosition
    ) as Void {
        // The gap between events is the proof of whether sound actually
        // played: a segment lasts minutes. If COMPLETE arrives a few
        // milliseconds after START, the player only passed the file through
        // instead of playing it.
        Log.line(
            "Playback: onSong " + eventName(songEvent)
                + " ref " + ((contentRefId instanceof Number) ? contentRefId.toString() : "?")
                + " at " + ((playbackPosition instanceof Number) ? playbackPosition.toString() : "?")
                + " after " + sinceLastEvent().toString() + " ms"
        );
        var bookId = _bookId;
        if (bookId == null) {
            return;
        }
        var parts = Store.trackInfo(bookId, contentRefId);
        if (parts == null) {
            return;
        }
        var seconds = 0;
        if (playbackPosition instanceof Number) {
            seconds = playbackPosition;
        }
        if (songEvent == Media.SONG_EVENT_COMPLETE) {
            // At the end of the segment its full duration counts, otherwise a
            // handful of seconds would be lost on every chapter change.
            seconds = Store.toNumber(parts[1]);
        }
        Store.rememberPosition(bookId, Store.toNumber(parts[0]), seconds, Time.now().value());

        if (songEvent == Media.SONG_EVENT_PAUSE || songEvent == Media.SONG_EVENT_STOP) {
            pushOverPhone();
        }
    }

    //! Event numbers alone are unreadable, and reading them wrong sends the
    //! search off in the wrong direction. Values from the SDK docs.
    private function eventName(event as Media.SongEvent) as String {
        var names = [
            "START", "SKIP_NEXT", "SKIP_PREVIOUS", "PLAYBACK_NOTIFY", "COMPLETE",
            "STOP", "PAUSE", "RESUME", "SKIP_FORWARD", "SKIP_BACKWARD"
        ] as Array<String>;
        if (event instanceof Number && event >= 0 && event < names.size()) {
            return names[event] + "(" + event.toString() + ")";
        }
        return "?(" + event.toString() + ")";
    }

    //! Milliseconds since the previous playback event.
    private function sinceLastEvent() as Number {
        var now = System.getTimer();
        var delta = now - _lastEvent;
        _lastEvent = now;
        return delta;
    }

    //! Attempt to get the position out immediately — over the phone connection.
    //!
    //! Every reason not to do so just returns here: the buffered position stays
    //! and goes out on the next sync at the latest.
    private function pushOverPhone() as Void {
        if (_pushing || !_client.isConfigured()) {
            return;
        }
        var now = Time.now().value();
        if (now - _lastPush < PUSH_THROTTLE_SECONDS) {
            return;
        }
        if (!System.getDeviceSettings().phoneConnected) {
            return;
        }
        var entries = Store.progressEntries();
        if (entries.size() == 0) {
            return;
        }
        _lastPush = now;
        _pushing = true;
        _client.pushProgress(entries, method(:onPushed));
    }

    function onPushed(code as Number, data as Dictionary or String or Null) as Void {
        _pushing = false;
        if (code != 200) {
            // Discard nothing: the sync over Wi-Fi catches up on it.
            return;
        }
        Store.clearProgress();
        Progress.adopt(data);
    }

    function onShuffle() as Void {
        // Audiobooks are not shuffled.
        Log.line("Playback: onShuffle");
    }

    // --- Remaining ContentDelegate contract ----------------------------------
    //
    // None of these carried an implementation before. They are here to be seen
    // in the log: an unimplemented callback the player invokes on its way to
    // starting a track is exactly the kind of thing that produces silence and
    // leaves no trace.

    function onRepeat() as Void {
        Log.line("Playback: onRepeat");
    }

    function onThumbsUp(contentRefId as Object) as Void {
        Log.line("Playback: onThumbsUp");
    }

    function onThumbsDown(contentRefId as Object) as Void {
        Log.line("Playback: onThumbsDown");
    }

    function onCustomButton(button as Media.CustomButton) as Void {
        Log.line("Playback: onCustomButton");
    }

    function onAdAction(adContext as Object) as Void {
        Log.line("Playback: onAdAction");
    }
}
