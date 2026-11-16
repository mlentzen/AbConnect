import Toybox.Lang;
import Toybox.Media;
import Toybox.Time;

class AbContentIterator extends Media.ContentIterator {

    private var _bookId as String;
    private var _refs as Array;
    private var _titles as Array<String>;
    private var _numbers as Array<Number>;
    private var _lengths as Array<Number>;
    private var _starts as Array<Number>;
    private var _total as Number;
    private var _album as String;
    private var _artist as String;
    private var _index as Number;
    private var _startPosition as Number;
    private var _startApplied as Boolean;
    private var _profile as Media.PlaybackProfile;

    function initialize(bookId as String, resume as Boolean) {
        ContentIterator.initialize();
        _bookId = bookId;
        _refs = [] as Array;
        _titles = [] as Array<String>;
        _numbers = [] as Array<Number>;
        _lengths = [] as Array<Number>;
        _starts = [] as Array<Number>;
        _total = 0;
        _index = 0;
        _startPosition = 0;
        _startApplied = false;
        _profile = PlaybackProfile.standard();
        Log.info("Iterator: opening book " + bookId);

        var info = Store.bookInfo(bookId);
        _album = info[0];
        _artist = info[1];

        buildPlaylist();
        if (_refs.size() == 0) {
            Log.error("Iterator: the book has no segments on the watch");
        }
        Log.debugCode("Iterator: segments", _refs.size());

        if (resume) {
            applyStoredPosition();
        } else {
            rememberBeginning();
        }
        Log.debugCode("Iterator: starting at", _index);
        Log.debugCode("Iterator: start position", _startPosition);
    }

    private function buildPlaylist() as Void {
        var segments = Store.orderedSegments(_bookId);
        for (var i = 0; i < segments.size(); ++i) {
            var segment = segments[i];
            _refs.add(segment[Store.SEG_REF]);
            _titles.add(segment[Store.SEG_TITLE] as String);
            _numbers.add(segment[Store.SEG_INDEX] as Number);
            _lengths.add(segment[Store.SEG_DURATION] as Number);
        }
        _starts = Store.segmentStarts(segments);
        _total = _starts[segments.size()];
    }

    private function applyStoredPosition() as Void {
        var position = Store.position(_bookId);
        if (position == null) {
            return;
        }
        var wanted = _numbers.indexOf(position[0]);
        if (wanted < 0) {
            Log.errorCode("Iterator: no local segment numbered", position[0]);
            return;
        }
        _index = wanted;
        _startPosition = position[1];
        skipFinishedSegment();
        if (_index == wanted && _startPosition == position[1]) {
            rewindAfterBreak(position[0], position[1]);
        }
    }

    private function rewindAfterBreak(segment as Number, seconds as Number) as Void {
        if (seconds <= 0) {
            return;
        }
        var idle = Store.idleSecondsAt(_bookId, segment, seconds);
        if (idle == null) {
            return;
        }
        var back = Rewind.secondsFor(idle);
        if (back <= 0) {
            return;
        }
        _startPosition = (seconds > back) ? seconds - back : 0;
        Log.info("Iterator: stepping back " + back.toString() + " s after " + idle.toString() + " s");
    }

    private function rememberBeginning() as Void {
        Log.info("Iterator: reset to the beginning");
        if (_refs.size() > 0) {
            Store.rememberPosition(_bookId, _numbers[0], 0, Time.now().value());
        }
    }

    private function skipFinishedSegment() as Void {
        var duration = _lengths[_index];
        if (duration <= 0 || _startPosition < duration) {
            return;
        }
        if (_index + 1 < _refs.size()) {
            _index += 1;
        } else {
            Log.info("Iterator: last segment finished, starting the book over");
            _index = 0;
        }
        _startPosition = 0;
    }

    private function artistLine(position as Number) as String {
        if (_total <= 0 || position < 0 || position >= _starts.size()) {
            return _artist;
        }
        var seconds = _starts[position];
        if (position == _index && !_startApplied) {
            seconds += _startPosition;
        }
        var percent = (seconds * 100) / _total;
        if (percent > 100) {
            percent = 100;
        }
        var text = percent.toString() + " %";
        return (_artist.length() > 0) ? _artist + " · " + text : text;
    }

    private function applyMetadata(content as Media.Content, position as Number) as Void {
        var metadata = content.getMetadata();
        if (metadata == null) {
            metadata = new Media.ContentMetadata();
        }
        metadata.title = _titles[position];
        metadata.album = _album;
        metadata.artist = artistLine(position);
        metadata.trackNumber = position + 1;
        content.setMetadata(metadata);
    }

    private function contentAt(position as Number) as Object? {
        if (position < 0 || position >= _refs.size()) {
            return null;
        }
        try {
            var content = Media.getCachedContentObj(
                new Media.ContentRef(_refs[position], Media.CONTENT_TYPE_AUDIO)
            );
            applyMetadata(content, position);
            return content;
        } catch (ex) {
            var message = ex.getErrorMessage();
            message = "Iterator: cache threw " + ((message == null) ? "?" : message);
            Log.error(message);
            return new PlaybackFailure(message);
        }
    }

    (:typecheck(false))
    private function asContent(found as Object?) as Media.Content? {
        return found;
    }

    function get() as Media.Content? {
        var found = contentAt(_index);
        if (found == null) {
            Log.error("Iterator: get returns null");
            return null;
        }
        if (!(found instanceof Media.Content)) {
            return asContent(found);
        }
        if (_startPosition > 0 && !_startApplied) {
            _startApplied = true;
            Log.debugCode("Iterator: ActiveContent from", _startPosition);
            return new Media.ActiveContent(found.getContentRef(), found.getMetadata(), _startPosition);
        }
        return found;
    }

    function next() as Media.Content? {
        if (_index + 1 >= _refs.size()) {
            Log.info("Iterator: next returns null (end of book)");
            return null;
        }
        _index += 1;
        _startPosition = 0;
        return asContent(contentAt(_index));
    }

    function previous() as Media.Content? {
        if (_index < 1) {
            return null;
        }
        _index -= 1;
        _startPosition = 0;
        return asContent(contentAt(_index));
    }

    function peekNext() as Media.Content? {
        return asContent(contentAt(_index + 1));
    }

    function peekPrevious() as Media.Content? {
        return asContent(contentAt(_index - 1));
    }

    function shuffling() as Boolean {
        return false;
    }

    function repeatMode() as Media.RepeatMode? {
        return Media.REPEAT_MODE_OFF;
    }

    function canSkip() as Boolean {
        return true;
    }

    function getPlaybackProfile() as Media.PlaybackProfile? {
        return _profile;
    }
}

class EmptyIterator extends Media.ContentIterator {

    private var _profile as Media.PlaybackProfile;

    function initialize() {
        ContentIterator.initialize();
        _profile = PlaybackProfile.standard();
    }

    function get() as Media.Content? {
        return null;
    }

    function next() as Media.Content? {
        return null;
    }

    function previous() as Media.Content? {
        return null;
    }

    function peekNext() as Media.Content? {
        return null;
    }

    function peekPrevious() as Media.Content? {
        return null;
    }

    function shuffling() as Boolean {
        return false;
    }

    function repeatMode() as Media.RepeatMode? {
        return Media.REPEAT_MODE_OFF;
    }

    function canSkip() as Boolean {
        return false;
    }

    function getPlaybackProfile() as Media.PlaybackProfile? {
        return _profile;
    }
}

module PlaybackProfile {

    function standard() as Media.PlaybackProfile {
        var profile = new Media.PlaybackProfile();
        profile.playbackControls = [
            Media.PLAYBACK_CONTROL_SKIP_FORWARD,
            Media.PLAYBACK_CONTROL_SKIP_BACKWARD,
            Media.PLAYBACK_CONTROL_PREVIOUS,
            Media.PLAYBACK_CONTROL_NEXT
        ] as Array<Media.PlaybackControl>;
        profile.skipForwardTimeDelta = 30;
        profile.skipBackwardTimeDelta = 30;
        profile.attemptSkipAfterThumbsDown = false;
        profile.requirePlaybackNotification = true;
        profile.playbackNotificationThreshold = 30;
        profile.skipPreviousThreshold = 4;
        return profile;
    }
}
