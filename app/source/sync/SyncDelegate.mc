import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;
import Toybox.Time;
import Toybox.WatchUi;

//! Der Sync selbst.
//!
//! Connect IQ ist einfädig und callbackbasiert — auf eine Antwort lässt sich
//! nicht warten. Der Ablauf ist deshalb ein Zustandsautomat, in dem jede
//! Antwort den nächsten Schritt auslöst.
//!
//! Reihenfolge: freigeben, Fortschritt melden, Bücher holen. Der Fortschritt
//! geht zuerst raus, damit er auch dann ankommt, wenn die Downloads später
//! abbrechen.
class AbSyncDelegate extends Communications.SyncDelegate {

    private var _client as ProxyClient;
    private var _bookQueue as Array<String>;
    private var _downloads as Array<Dictionary>;
    private var _pending as Dictionary?;
    private var _currentBook as String?;
    private var _booksTotal as Number;
    private var _booksDone as Number;
    private var _downloadsTotal as Number;
    private var _downloadsDone as Number;
    private var _stillPreparing as Number;
    private var _failure as String?;
    private var _stopped as Boolean;

    function initialize() {
        SyncDelegate.initialize();
        _client = new ProxyClient();
        _bookQueue = [] as Array<String>;
        _downloads = [] as Array<Dictionary>;
        _pending = null;
        _currentBook = null;
        _booksTotal = 0;
        _booksDone = 0;
        _downloadsTotal = 0;
        _downloadsDone = 0;
        _stillPreparing = 0;
        _failure = null;
        _stopped = false;
    }

    //! Ein Sync lohnt sich, wenn Fortschritt aussteht, der letzte bekannte
    //! Stand der Playlist nicht zum lokalen Bestand passt — oder wenn dieser
    //! Stand schlicht zu alt ist.
    //!
    //! Der letzte Punkt ist der wichtige: ohne ihn bliebe ein neu in die
    //! Playlist gelegtes Buch unbemerkt, weil die Uhr offline nichts davon weiß.
    function isSyncNeeded() as Boolean {
        if (Store.progress().size() > 0) {
            return true;
        }
        if (Time.now().value() - Store.lastCheck() > Keys.PLAYLIST_MAX_AGE_SECONDS) {
            return true;
        }
        var wanted = Store.desired();
        for (var i = 0; i < wanted.size(); ++i) {
            if (Store.localTracks(wanted[i]).size() == 0) {
                return true;
            }
        }
        return orphans(wanted).size() > 0;
    }

    function onStartSync() as Void {
        if (!_client.isConfigured()) {
            Communications.notifySyncComplete("Proxy nicht konfiguriert");
            return;
        }
        // Fortschritt zuerst: er ist klein und darf nicht an einem
        // abbrechenden Download hängen bleiben.
        pushProgress();
    }

    function onStopSync() as Void {
        _stopped = true;
        Communications.cancelAllRequests();
        Communications.notifySyncComplete(null);
    }

    // --- Aufräumen ------------------------------------------------------------

    //! Bücher, von denen Segmente liegen, die aber nicht mehr in der Playlist
    //! stehen.
    private function orphans(wanted as Array<String>) as Array<String> {
        var result = [] as Array<String>;
        var known = Store.knownBooks();
        for (var i = 0; i < known.size(); ++i) {
            if (wanted.indexOf(known[i]) < 0) {
                result.add(known[i]);
            }
        }
        return result;
    }

    private function deleteLocal(bookId as String) as Void {
        var refIds = Store.localTracks(bookId).keys();
        for (var i = 0; i < refIds.size(); ++i) {
            Media.deleteCachedItem(new Media.ContentRef(refIds[i], Media.CONTENT_TYPE_AUDIO));
        }
        Store.forgetBook(bookId);
    }

    // --- Phase 1: Hörfortschritt melden --------------------------------------

    private function pushProgress() as Void {
        if (_stopped) {
            return;
        }
        var entries = Store.progressEntries();
        if (entries.size() == 0) {
            fetchPlaylist();
            return;
        }
        _client.pushProgress(entries, method(:onProgressPushed));
    }

    function onProgressPushed(code as Number, data as Dictionary or String or Null) as Void {
        if (code == 200) {
            // Erst nach bestätigter Übernahme verwerfen — bei einem Abbruch
            // wäre der Hörfortschritt sonst weg.
            Store.clearProgress();
            adoptServerPositions(data);
        }
        fetchPlaylist();
    }

    //! Wo der Server weiter war als die Uhr, springt die Uhr nach.
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
                    Store.rememberPosition(bookId, segment, numberOf(resume["offset"]), 0);
                }
            }
        }
    }

    // --- Phase 2: Playlist lesen ---------------------------------------------

    private function fetchPlaylist() as Void {
        if (_stopped) {
            return;
        }
        _client.playlist(method(:onPlaylist));
    }

    function onPlaylist(code as Number, data as Dictionary or String or Null) as Void {
        if (_stopped) {
            return;
        }
        if (code == 409) {
            // Playlist nicht gefunden. Das ist ein Konfigurationsfehler, kein
            // leerer Wunsch — hier wird nichts gelöscht.
            Communications.notifySyncComplete(
                WatchUi.loadResource(Rez.Strings.syncNoPlaylist) as String
            );
            return;
        }
        if (code != 200 || !(data instanceof Dictionary)) {
            // Ohne frische Vorgabe bleibt alles, wie es ist.
            Communications.notifySyncComplete("HTTP " + code.toString());
            return;
        }

        var books = data["books"];
        if (!(books instanceof Array)) {
            Communications.notifySyncComplete(null);
            return;
        }

        var wanted = [] as Array<String>;
        for (var i = 0; i < books.size(); ++i) {
            var book = books[i];
            if (book instanceof Dictionary && book["id"] instanceof String) {
                wanted.add(book["id"] as String);
            }
        }
        Store.setDesired(wanted);

        // Was nicht mehr in der Playlist steht, verschwindet auch von der Uhr.
        var gone = orphans(wanted);
        for (var i = 0; i < gone.size(); ++i) {
            deleteLocal(gone[i]);
        }

        _bookQueue = wanted;
        _booksTotal = _bookQueue.size();
        nextBook();
    }

    // --- Phase 3: Bücher holen -----------------------------------------------

    private function nextBook() as Void {
        if (_stopped) {
            return;
        }
        if (_bookQueue.size() == 0) {
            Communications.notifySyncComplete(_failure);
            return;
        }
        var bookId = _bookQueue[0];
        _bookQueue.remove(bookId);
        _currentBook = bookId;
        _client.segments(bookId, method(:onSegments));
    }

    function onSegments(code as Number, data as Dictionary or String or Null) as Void {
        if (_stopped) {
            return;
        }
        if (code == 409) {
            // Der Proxy schneidet noch. Kein Fehler — beim nächsten Sync wieder.
            _stillPreparing += 1;
            bookDone();
            return;
        }
        var bookId = _currentBook;
        if (code != 200 || !(data instanceof Dictionary) || bookId == null) {
            _failure = "HTTP " + code.toString();
            bookDone();
            return;
        }

        var segments = data["segments"];
        if (!(segments instanceof Array)) {
            bookDone();
            return;
        }

        Store.setBookInfo(
            bookId,
            SyncConfigView.stringOr(data["title"], bookId),
            SyncConfigView.stringOr(data["author"], ""),
            segments.size()
        );

        var known = knownSegments(bookId);
        _downloads = [] as Array<Dictionary>;
        for (var i = 0; i < segments.size(); ++i) {
            var segment = segments[i];
            if (!(segment instanceof Dictionary)) {
                continue;
            }
            var index = segment["index"];
            if (index instanceof Number && known.indexOf(index) < 0) {
                _downloads.add(segment);
            }
        }
        _downloadsTotal = _downloads.size();
        _downloadsDone = 0;
        downloadNext();
    }

    private function knownSegments(bookId as String) as Array<Number> {
        var result = [] as Array<Number>;
        var refIds = Store.localTracks(bookId).keys();
        for (var i = 0; i < refIds.size(); ++i) {
            var parts = Store.trackInfo(bookId, refIds[i]);
            if (parts != null) {
                result.add(Store.toNumber(parts[0]));
            }
        }
        return result;
    }

    private function downloadNext() as Void {
        if (_stopped) {
            return;
        }
        if (_downloads.size() == 0) {
            bookDone();
            return;
        }
        var segment = _downloads[0];
        _downloads.remove(segment);
        var path = segment["url"];
        if (!(path instanceof String)) {
            downloadNext();
            return;
        }
        _pending = segment;
        _client.downloadSegment(
            path,
            SyncConfigView.stringOr(segment["encoding"], "m4a"),
            method(:onSegmentDownloaded)
        );
    }

    function onSegmentDownloaded(code as Number, data as Object?) as Void {
        if (_stopped) {
            return;
        }
        var segment = _pending;
        var bookId = _currentBook;
        if (code == 200 && data instanceof Media.ContentRef && segment != null && bookId != null) {
            Store.addLocalTrack(
                bookId,
                data.getId(),
                numberOf(segment["index"]),
                numberOf(segment["duration"]),
                SyncConfigView.stringOr(segment["title"], "")
            );
        } else {
            // Ein einzelnes Segment reißt nicht das ganze Buch mit: der nächste
            // Sync holt nur die Lücke nach.
            _failure = "HTTP " + code.toString();
        }
        _downloadsDone += 1;
        report();
        downloadNext();
    }

    private function bookDone() as Void {
        _booksDone += 1;
        _downloadsTotal = 0;
        _downloadsDone = 0;
        report();
        nextBook();
    }

    private function report() as Void {
        if (_booksTotal <= 0) {
            return;
        }
        var withinBook = 0.0;
        if (_downloadsTotal > 0) {
            withinBook = _downloadsDone.toFloat() / _downloadsTotal.toFloat();
        }
        var share = (_booksDone.toFloat() + withinBook) / _booksTotal.toFloat();
        if (share > 1.0) {
            share = 1.0;
        }
        Communications.notifySyncProgress((share * 100).toNumber());
    }

    static function numberOf(value as Object?) as Number {
        if (value instanceof Number) {
            return value;
        }
        if (value instanceof Float) {
            return value.toNumber();
        }
        if (value instanceof Double) {
            return value.toNumber();
        }
        return 0;
    }
}
