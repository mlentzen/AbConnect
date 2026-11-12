import Toybox.Lang;
import Toybox.Media;
import Toybox.Time;

class AbContentDelegate extends Media.ContentDelegate {

    private const PUSH_THROTTLE_SECONDS = 30;

    private var _iterator as Media.ContentIterator?;
    private var _bookId as String?;
    private var _client as ProxyClient;
    private var _lastPush as Number;
    private var _pushing as Boolean;
    private var _sentEntries as Array;
    private var _playerHasIterator as Boolean;

    function initialize() {
        ContentDelegate.initialize();
        _client = new ProxyClient();
        _lastPush = 0;
        _pushing = false;
        _sentEntries = [] as Array;
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
        _iterator = openIterator(true);
    }

    function getContentIterator() as Media.ContentIterator? {
        _playerHasIterator = true;
        if (_iterator == null) {
            Log.error("Playback: getContentIterator has nothing to hand over");
            _iterator = openIterator(true);
        }
        return _iterator;
    }

    function resetContentIterator() as Media.ContentIterator? {
        var resume = !_playerHasIterator;
        _playerHasIterator = true;
        if (!resume || _iterator == null) {
            _iterator = openIterator(resume);
        }
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
        var bookId = _bookId;
        if (bookId == null) {
            return;
        }
        var parts = Store.trackInfo(bookId, contentRefId);
        if (parts == null) {
            return;
        }
        var segment = Util.toNumber(parts[0]);
        var seconds = (playbackPosition instanceof Number) ? playbackPosition : 0;
        if (songEvent == Media.SONG_EVENT_COMPLETE) {
            seconds = Util.toNumber(parts[1]);
        }
        var now = Time.now().value();
        Store.rememberPosition(bookId, segment, seconds, now);
        Store.notePlayed(bookId, segment, seconds, now);

        if (songEvent == Media.SONG_EVENT_PAUSE || songEvent == Media.SONG_EVENT_STOP) {
            pushOverPhone();
        }
    }

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
        if (code == 200) {
            Progress.settle(_sentEntries, data);
        }
    }
}
