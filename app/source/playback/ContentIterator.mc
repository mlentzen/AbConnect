import Toybox.Lang;
import Toybox.Media;

//! Reihenfolge und Metadaten der Segmente eines Buchs.
//!
//! Zwei Dinge machen den Unterschied zwischen Musikplayer und Hörbuch:
//! die Metadaten kommen aus dem Object Store statt aus den Tags der Datei,
//! und das laufende Segment wird als ActiveContent mit gemerkter Position
//! zurückgegeben — nur so setzt der Player mitten im Kapitel fort.
class AbContentIterator extends Media.ContentIterator {

    private var _bookId as String;
    private var _refs as Array;
    private var _titles as Array<String>;
    private var _album as String;
    private var _artist as String;
    private var _index as Number;
    private var _startPosition as Number;

    function initialize(bookId as String) {
        ContentIterator.initialize();
        _bookId = bookId;
        _refs = [] as Array;
        _titles = [] as Array<String>;

        var info = Store.bookInfo(bookId);
        _album = info[0];
        _artist = info[1];

        buildPlaylist();

        _index = 0;
        _startPosition = 0;
        var position = Store.position(bookId);
        if (position != null) {
            var wanted = indexOfSegment(position[0]);
            if (wanted >= 0) {
                _index = wanted;
                _startPosition = position[1];
            }
        }
    }

    //! Segmente in ihre Reihenfolge bringen.
    //!
    //! Der Object Store ist eine Map ohne Ordnung, deshalb wird über ein Feld
    //! einsortiert statt sortiert — Monkey C hat kein Array.sort.
    private function buildPlaylist() as Void {
        var tracks = Store.localTracks(_bookId);
        var refIds = tracks.keys();
        var highest = -1;
        var indices = [] as Array<Number>;
        var titles = [] as Array<String>;

        for (var i = 0; i < refIds.size(); ++i) {
            var parts = Store.trackInfo(_bookId, refIds[i]);
            var index = (parts == null) ? -1 : Store.toNumber(parts[0]);
            indices.add(index);
            titles.add((parts == null) ? "" : parts[2]);
            if (index > highest) {
                highest = index;
            }
        }

        var slots = new [highest + 1] as Array;
        var slotTitles = new [highest + 1] as Array<String>;
        for (var i = 0; i < refIds.size(); ++i) {
            var slot = indices[i];
            if (slot >= 0) {
                slots[slot] = refIds[i];
                slotTitles[slot] = titles[i];
            }
        }
        for (var slot = 0; slot < slots.size(); ++slot) {
            if (slots[slot] != null) {
                _refs.add(slots[slot]);
                _titles.add(slotTitles[slot] == null ? "" : slotTitles[slot]);
            }
        }
    }

    private function indexOfSegment(segment as Number) as Number {
        for (var i = 0; i < _refs.size(); ++i) {
            var parts = Store.trackInfo(_bookId, _refs[i]);
            if (parts != null && Store.toNumber(parts[0]) == segment) {
                return i;
            }
        }
        return -1;
    }

    private function metadataFor(position as Number) as Media.ContentMetadata {
        var metadata = new Media.ContentMetadata();
        metadata.title = _titles[position];
        metadata.album = _album;
        metadata.artist = _artist;
        metadata.trackNumber = position + 1;
        return metadata;
    }

    private function contentAt(position as Number) as Media.Content? {
        if (position < 0 || position >= _refs.size()) {
            return null;
        }
        var ref = new Media.ContentRef(_refs[position], Media.CONTENT_TYPE_AUDIO);
        return new Media.Content(ref, metadataFor(position));
    }

    function get() as Media.Content? {
        if (_index < 0 || _index >= _refs.size()) {
            return null;
        }
        // Nur das laufende Segment trägt eine Startposition — alle folgenden
        // beginnen von vorn.
        var ref = new Media.ContentRef(_refs[_index], Media.CONTENT_TYPE_AUDIO);
        return new Media.ActiveContent(ref, metadataFor(_index), _startPosition);
    }

    function next() as Media.Content? {
        if (_index + 1 >= _refs.size()) {
            return null;
        }
        _index += 1;
        _startPosition = 0;
        return contentAt(_index);
    }

    function previous() as Media.Content? {
        if (_index - 1 < 0) {
            return null;
        }
        _index -= 1;
        _startPosition = 0;
        return contentAt(_index);
    }

    function peekNext() as Media.Content? {
        return contentAt(_index + 1);
    }

    function peekPrevious() as Media.Content? {
        return contentAt(_index - 1);
    }

    function shuffling() as Boolean {
        // Ein Hörbuch in zufälliger Reihenfolge ist kein Hörbuch mehr.
        return false;
    }

    function canSkip() as Boolean {
        return true;
    }

    function getPlaybackProfile() as Media.PlaybackProfile? {
        var profile = new Media.PlaybackProfile();
        profile.playbackControls = [
            Media.PLAYBACK_CONTROL_PLAYBACK,
            Media.PLAYBACK_CONTROL_PREVIOUS,
            Media.PLAYBACK_CONTROL_NEXT,
            Media.PLAYBACK_CONTROL_SKIP_FORWARD,
            Media.PLAYBACK_CONTROL_SKIP_BACKWARD
        ] as Array<Media.PlaybackControl>;
        // Hörbuchmaße statt der Musik-Vorgabe von zweimal 30 Sekunden.
        profile.skipForwardTimeDelta = 30;
        profile.skipBackwardTimeDelta = 15;
        profile.attemptSkipAfterThumbsDown = false;
        // Ohne diese Meldungen erführe die App nie, wo der Hörer steht.
        profile.requirePlaybackNotification = true;
        profile.playbackNotificationThreshold = 30;
        profile.skipPreviousThreshold = 4;
        return profile;
    }
}
