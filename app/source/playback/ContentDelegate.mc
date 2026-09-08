import Toybox.Lang;
import Toybox.Media;
import Toybox.Time;

//! Bindeglied zum System-Player.
//!
//! Während der Wiedergabe gibt es kein WLAN, deshalb wird die Position nur
//! gemerkt. Übertragen wird sie beim nächsten Sync.
class AbContentDelegate extends Media.ContentDelegate {

    private var _iterator as AbContentIterator?;
    private var _bookId as String?;

    function initialize() {
        ContentDelegate.initialize();
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
    }

    function onShuffle() as Void {
        // Hörbücher werden nicht gemischt.
    }
}
