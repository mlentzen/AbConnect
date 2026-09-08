import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.Time;

//! Bindeglied zum System-Player.
//!
//! Die Position wird bei jedem Ereignis gemerkt. Beim Pausieren wird zusätzlich
//! versucht, sie sofort über die Telefonverbindung zu melden — das ist der
//! einzige Moment während der Wiedergabe, in dem ein Funkzugriff niemanden
//! stört. Klappt es nicht, bleibt alles gepuffert und geht beim nächsten Sync
//! über WLAN raus. Verloren geht dabei nichts.
class AbContentDelegate extends Media.ContentDelegate {

    //! Pause und Fortsetzen kommen in Serie; ohne Bremse liefe der Funk mit.
    private const PUSH_THROTTLE_SECONDS = 30;

    private var _iterator as AbContentIterator?;
    private var _bookId as String?;
    private var _client as ProxyClient;
    private var _lastPush as Number;
    private var _pushing as Boolean;

    function initialize() {
        ContentDelegate.initialize();
        _client = new ProxyClient();
        _lastPush = 0;
        _pushing = false;
        _bookId = Current.bookId();
        if (_bookId == null) {
            var books = Store.localBooks();
            if (books.size() > 0) {
                _bookId = books[0];
            }
        }
        resetContentIterator();
    }

    function getContentIterator() as Media.ContentIterator? {
        return _iterator;
    }

    function resetContentIterator() as Media.ContentIterator? {
        if (_bookId != null) {
            _iterator = new AbContentIterator(_bookId);
        }
        return _iterator;
    }

    function onSong(
        contentRefId as Object, songEvent as Media.SongEvent, playbackPosition as Number or Media.PlaybackPosition
    ) as Void {
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
            // Am Ende des Segments zählt dessen volle Dauer, sonst ginge bei
            // jedem Kapitelwechsel eine Handvoll Sekunden verloren.
            seconds = Store.toNumber(parts[1]);
        }
        Store.rememberPosition(bookId, Store.toNumber(parts[0]), seconds, Time.now().value());

        if (songEvent == Media.SONG_EVENT_PAUSE || songEvent == Media.SONG_EVENT_STOP) {
            pushOverPhone();
        }
    }

    //! Versuch, den Stand sofort loszuwerden — über die Telefonverbindung.
    //!
    //! Jeder Grund, es zu lassen, führt hier nur zum Rücksprung: der gepufferte
    //! Stand bleibt liegen und geht spätestens beim nächsten Sync raus.
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
            // Nichts verwerfen: der Sync über WLAN holt es nach.
            return;
        }
        Store.clearProgress();
        adoptServerPositions(data);
    }

    //! War das Handy weiter als die Uhr, springt die Uhr nach — dieselbe Regel
    //! wie beim Sync, damit beide Wege zum selben Ergebnis führen.
    private function adoptServerPositions(data as Dictionary or String or Null) as Void {
        if (!(data instanceof Dictionary)) {
            return;
        }
        var books = data["books"];
        if (!(books instanceof Array)) {
            return;
        }
        for (var i = 0; i < books.size(); ++i) {
            var entry = books[i];
            if (!(entry instanceof Dictionary)) {
                continue;
            }
            var resume = entry["resume"];
            var bookId = entry["id"];
            if (resume instanceof Dictionary && bookId instanceof String) {
                var segment = resume["segment"];
                if (segment instanceof Number) {
                    Store.rememberPosition(bookId, segment, AbSyncDelegate.numberOf(resume["offset"]), 0);
                }
            }
        }
    }

    function onShuffle() as Void {
        // Hörbücher werden nicht gemischt.
    }
}
