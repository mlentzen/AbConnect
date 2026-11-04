import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.Time;

//! Link to the system player.
//!
//! The position is remembered on every playback event (about every 30 seconds,
//! and on pause, skip, and chapter change). On pause it also tries to push it
//! over the phone connection; if that fails, it stays buffered for the next
//! Wi-Fi sync.
class AbContentDelegate extends Media.ContentDelegate {

    private const PUSH_THROTTLE_SECONDS = 30;

    private var _iterator as Media.ContentIterator?;
    private var _bookId as String?;
    private var _client as ProxyClient;
    private var _lastPush as Number;
    private var _pushing as Boolean;
    private var _sentEntries as Array;
    private var _lastEvent as Number;
    //! Set once the player has asked for an iterator. The opening request
    //! follows the stored position. A later reset starts the book over.
    private var _playerHasIterator as Boolean;

    function initialize() {
        ContentDelegate.initialize();
        _client = new ProxyClient();
        _lastPush = 0;
        _pushing = false;
        _sentEntries = [] as Array;
        _lastEvent = System.getTimer();
        _playerHasIterator = false;
        _bookId = Current.bookId();
        if (_bookId == null) {
            var books = Store.localBooks();
            if (books.size() > 0) {
                _bookId = books[0];
            }
        }
        if (_bookId == null) {
            Log.error("Playback: no book to play");
        } else {
            Log.info("Playback: book " + _bookId);
        }
        // Ready for getContentIterator(). Not marked as taken: if the player
        // resets before it has asked for one, that reset is this playback
        // opening, and the stored position (resume, chapter, or the start)
        // still applies.
        _iterator = openIterator(true);
    }

    function getContentIterator() as Media.ContentIterator? {
        _playerHasIterator = true;
        if (_iterator == null) {
            // Still hand back an iterator. null is invoked by the player and
            // becomes the IQ screen.
            Log.error("Playback: getContentIterator has nothing to hand over");
            _iterator = openIterator(true);
        } else if (Log.LEVEL >= Log.DEBUG) {
            Log.debug("Playback: getContentIterator");
        }
        return _iterator;
    }

    //! The first call of a playback keeps the iterator built above. After the
    //! player has taken one, this builds another at the first segment.
    function resetContentIterator() as Media.ContentIterator? {
        if (!_playerHasIterator) {
            _playerHasIterator = true;
            if (_iterator == null) {
                _iterator = openIterator(true);
            } else if (Log.LEVEL >= Log.DEBUG) {
                Log.debug("Playback: resetContentIterator keeps the stored position");
            }
            return _iterator;
        }
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debug("Playback: resetContentIterator from the beginning");
        }
        _iterator = openIterator(false);
        return _iterator;
    }

    private function openIterator(resume as Boolean) as Media.ContentIterator {
        var bookId = _bookId;
        if (bookId == null) {
            return new EmptyIterator();
        }
        return new AbContentIterator(bookId, resume);
    }

    function onSong(
        contentRefId as Object, songEvent as Media.SongEvent, playbackPosition as Number or Media.PlaybackPosition
    ) as Void {
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debug(
                "Playback: onSong " + eventName(songEvent)
                    + " ref " + ((contentRefId instanceof Number) ? contentRefId.toString() : "?")
                    + " at " + ((playbackPosition instanceof Number) ? playbackPosition.toString() : "?")
                    + " after " + sinceLastEvent().toString() + " ms"
            );
        }
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
            // Count the full duration, or seconds are lost at every chapter change.
            seconds = Store.toNumber(parts[1]);
        }
        Store.rememberPosition(bookId, Store.toNumber(parts[0]), seconds, Time.now().value());

        if (songEvent == Media.SONG_EVENT_PAUSE || songEvent == Media.SONG_EVENT_STOP) {
            pushOverPhone();
        }
    }

    //! Readable names for the SDK's event numbers, for the log.
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

    //! Try to push the position over the phone connection. Any reason not to
    //! just returns; the buffer goes out on the next sync.
    private function pushOverPhone() as Void {
        if (_pushing || !_client.isConfigured()) {
            return;
        }
        var now = Time.now().value();
        if (now - _lastPush < PUSH_THROTTLE_SECONDS) {
            return;
        }
        var entries = Store.pendingEntries();
        if (entries.size() == 0) {
            return;
        }
        _lastPush = now;
        _pushing = true;
        _sentEntries = entries;
        _client.pushProgress(entries, method(:onPushed));
    }

    function onPushed(code as Number, data as Dictionary or String or Null) as Void {
        _pushing = false;
        if (code != 200) {
            // Keep the buffer; the Wi-Fi sync catches up.
            return;
        }
        Progress.settle(_sentEntries, data);
    }

    function onShuffle() as Void {
        // Audiobooks are not shuffled.
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debug("Playback: onShuffle");
        }
    }

    function onRepeat() as Void {
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debug("Playback: onRepeat");
        }
    }

    function onThumbsUp(contentRefId as Object) as Void {
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debug("Playback: onThumbsUp");
        }
    }

    function onThumbsDown(contentRefId as Object) as Void {
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debug("Playback: onThumbsDown");
        }
    }

    function onCustomButton(button as Media.CustomButton) as Void {
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debug("Playback: onCustomButton");
        }
    }

    function onAdAction(adContext as Object) as Void {
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debug("Playback: onAdAction");
        }
    }
}
