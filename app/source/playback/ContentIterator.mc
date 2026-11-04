import Toybox.Lang;
import Toybox.Media;
import Toybox.Time;

class AbContentIterator extends Media.ContentIterator {

    private var _bookId as String;
    private var _refs as Array;
    private var _titles as Array<String>;
    private var _album as String;
    private var _artist as String;
    private var _index as Number;
    private var _startPosition as Number;
    private var _startApplied as Boolean;
    private var _profile as Media.PlaybackProfile;

    //! resume: follow the stored position. Otherwise this is a playlist reset
    //! and playback starts at the first segment.
    function initialize(bookId as String, resume as Boolean) {
        ContentIterator.initialize();
        _bookId = bookId;
        _refs = [] as Array;
        _titles = [] as Array<String>;
        _index = 0;
        _startPosition = 0;
        _startApplied = false;
        _profile = PlaybackProfile.standard();
        Log.info("Iterator: opening book " + bookId);

        var info = Store.bookInfo(bookId);
        _album = info[0];
        _artist = info[1];
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debug(
                "Iterator: album '" + _album + "'"
                    + " artist '" + _artist + "'"
                    + " segments on the server " + info[2]
            );
        }

        buildPlaylist();
        if (_refs.size() == 0) {
            Log.error("Iterator: the book has no segments on the watch");
        } else if (Log.LEVEL >= Log.DEBUG) {
            Log.debugCode("Iterator: segments", _refs.size());
        }

        if (resume) {
            applyStoredPosition();
        } else {
            rememberBeginning();
        }
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debugCode("Iterator: starting at", _index);
            Log.debugCode("Iterator: start position", _startPosition);
        }
    }

    private function applyStoredPosition() as Void {
        var position = Store.position(_bookId);
        if (position == null) {
            if (Log.LEVEL >= Log.DEBUG) {
                Log.debug("Iterator: nothing remembered, starting at the beginning");
            }
            return;
        }
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debug(
                "Iterator: remembered segment " + position[0].toString()
                    + " offset " + position[1].toString() + " s"
                    + " stamped " + position[2].toString()
            );
        }
        var wanted = indexOfSegment(position[0]);
        if (wanted >= 0) {
            _index = wanted;
            _startPosition = position[1];
            skipFinishedSegment();
        } else {
            // Segment not on the watch: fall back to the start.
            Log.errorCode("Iterator: no local segment numbered", position[0]);
        }
    }

    //! A reset is the start of the book, including the next time playback opens.
    private function rememberBeginning() as Void {
        Log.info("Iterator: reset to the beginning");
        if (_refs.size() == 0) {
            return;
        }
        var parts = Store.trackInfo(_bookId, _refs[0]);
        if (parts == null) {
            Log.error("Iterator: the first segment has no store entry");
            return;
        }
        Store.rememberPosition(_bookId, Store.toNumber(parts[0]), 0, Time.now().value());
    }

    //! A finished segment is not a starting point: its remembered position is
    //! the full duration, so playback would end immediately.
    private function skipFinishedSegment() as Void {
        var duration = durationAt(_index);
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debug(
                "Iterator: resume check at " + _index.toString()
                    + ", offset " + _startPosition.toString()
                    + " of " + duration.toString() + " s"
            );
        }
        if (duration <= 0 || _startPosition < duration) {
            if (Log.LEVEL >= Log.DEBUG) {
                Log.debugCode("Iterator: segment still has sound left", _index);
            }
            return;
        }
        if (_index + 1 < _refs.size()) {
            _index += 1;
            _startPosition = 0;
            if (Log.LEVEL >= Log.DEBUG) {
                Log.debugCode("Iterator: segment was finished, moving on to", _index);
            }
            return;
        }
        // Book finished: start over rather than end in silence.
        Log.info("Iterator: last segment finished, starting the book over");
        _index = 0;
        _startPosition = 0;
    }

    private function durationAt(position as Number) as Number {
        if (position < 0 || position >= _refs.size()) {
            Log.errorCode("Iterator: duration asked outside the playlist for", position);
            return 0;
        }
        var parts = Store.trackInfo(_bookId, _refs[position]);
        if (parts == null) {
            Log.error("Iterator: no store entry for " + Log.describe(_refs[position]));
            return 0;
        }
        return Store.toNumber(parts[1]);
    }

    //! Ordering lives in Store.orderedRefs(), shared with the chapter menu.
    private function buildPlaylist() as Void {
        _refs = Store.orderedRefs(_bookId);
        for (var i = 0; i < _refs.size(); ++i) {
            var parts = Store.trackInfo(_bookId, _refs[i]);
            _titles.add((parts == null) ? "" : parts[2]);
            if (Log.LEVEL >= Log.DEBUG) {
                Log.debug(
                    "playlist " + i.toString()
                        + " " + Log.describe(_refs[i])
                        + " '" + _titles[i] + "'"
                );
            }
        }
    }

    private function indexOfSegment(segment as Number) as Number {
        for (var i = 0; i < _refs.size(); ++i) {
            var parts = Store.trackInfo(_bookId, _refs[i]);
            if (parts != null && Store.toNumber(parts[0]) == segment) {
                if (Log.LEVEL >= Log.DEBUG) {
                    Log.debugCode(
                        "Iterator: segment " + segment.toString() + " is playlist position", i
                    );
                }
                return i;
            }
        }
        Log.errorCode("Iterator: the playlist has no segment numbered", segment);
        return -1;
    }

    //! Sets our titles on the cache's own metadata object, never a fresh one:
    //! a fresh ContentMetadata drops the protected duration and the player
    //! skips through the book.
    private function applyMetadata(content as Media.Content, position as Number) as Void {
        var metadata = content.getMetadata();
        if (metadata == null) {
            Log.warn("Iterator: cache metadata is null, building one");
            content.setMetadata(metadataFor(position));
            return;
        }
        metadata.title = _titles[position];
        metadata.album = _album;
        metadata.artist = _artist;
        metadata.trackNumber = position + 1;
        content.setMetadata(metadata);
    }

    //! Fallback for content without metadata; lacks the duration.
    private function metadataFor(position as Number) as Media.ContentMetadata {
        var metadata = new Media.ContentMetadata();
        metadata.title = _titles[position];
        metadata.album = _album;
        metadata.artist = _artist;
        metadata.trackNumber = position + 1;
        return metadata;
    }

    //! null when the index is outside the playlist. A PlaybackFailure when the
    //! segment should be there and the cache cannot provide it. Content otherwise.
    //!
    //! The content object must come from getCachedContentObj(). A hand-made
    //! `new Media.Content(ref, metadata)` is accepted but never starts decoding.
    private function contentAt(position as Number) as Object? {
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debugCode("Iterator: content asked for", position);
        }
        if (position < 0 || position >= _refs.size()) {
            return null;
        }
        var content = null as Media.Content?;
        try {
            content = Media.getCachedContentObj(
                new Media.ContentRef(_refs[position], Media.CONTENT_TYPE_AUDIO)
            );
        } catch (ex) {
            var message = ex.getErrorMessage();
            return failure("Iterator: cache threw " + ((message == null) ? "?" : message));
        }
        if (content == null) {
            return failure("Iterator: nothing in cache at " + position.toString());
        }
        if (Log.LEVEL >= Log.DEBUG) {
            describeResolved(content, position);
            describeMetadata("before", content);
        }
        applyMetadata(content, position);
        if (Log.LEVEL >= Log.DEBUG) {
            describeMetadata("after", content);
        }
        return content;
    }

    //! Only called while debugging. The player asks for content often, and
    //! each of these strings is an object.
    private function describeResolved(content as Media.Content, position as Number) as Void {
        var carried = null as Object?;
        var startAt = "?";
        var kind = "Content";
        try {
            carried = content.getContentRef().getId();
            // Declared as Number, but a plain Content need not carry one.
            var where = content.getPlaybackStartPosition();
            startAt = (where == null) ? "null" : where.toString();
            if (content instanceof Media.ActiveContent) {
                kind = "ActiveContent";
            }
        } catch (ex) {
            Log.warn("Iterator: inspecting the content threw");
        }
        Log.debug(
            "Iterator: resolved " + position.toString()
                + " asked " + Log.describe(_refs[position])
                + " carries " + Log.describe(carried)
                + " start " + startAt
                + " kind " + kind
        );
    }

    private function failure(message as String) as PlaybackFailure {
        Log.error(message);
        return new PlaybackFailure(message);
    }

    //! Logs what the player will show, to verify our metadata write survived.
    private function describeMetadata(when as String, content as Media.Content) as Void {
        var meta = content.getMetadata();
        if (meta == null) {
            Log.warn("Iterator: metadata " + when + " is null");
            return;
        }
        Log.debug(
            "Iterator: metadata " + when
                + " title=" + ((meta.title == null) ? "null" : meta.title)
                + " album=" + ((meta.album == null) ? "null" : meta.album)
                + " track=" + ((meta.trackNumber == null) ? "null" : meta.trackNumber.toString())
        );
        Log.debug(
            "metadata " + when
                + " artist=" + ((meta.artist == null) ? "null" : meta.artist)
                + " genre=" + ((meta.genre == null) ? "null" : meta.genre)
        );
    }

    function get() as Media.Content? {
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debugCode("Iterator: get at", _index);
        }
        var found = contentAt(_index);
        if (!(found instanceof Media.Content)) {
            if (found == null) {
                Log.error("Iterator: get returns null");
                return null;
            }
            return hand(found);
        }
        var content = found as Media.Content;
        // ActiveContent only for a mid-segment resume, and only once, so a later
        // jump back to this segment starts at its beginning.
        if (_startPosition > 0 && !_startApplied) {
            _startApplied = true;
            if (Log.LEVEL >= Log.DEBUG) {
                Log.debugCode("Iterator: ActiveContent from", _startPosition);
            }
            // Reuse the cached Content's ref; a hand-built ContentRef is untested.
            return new Media.ActiveContent(
                content.getContentRef(),
                content.getMetadata(),
                _startPosition
            );
        }
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debug(
                "Iterator: get returns the cache object for " + _index.toString()
                    + " (offset " + _startPosition.toString()
                    + ", start " + (_startApplied ? "already used" : "not used") + ")"
            );
        }
        return content;
    }

    function next() as Media.Content? {
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debugCode("Iterator: next from", _index);
        }
        if (_index + 1 >= _refs.size()) {
            Log.info("Iterator: next returns null (end of book)");
            return null;
        }
        _index += 1;
        _startPosition = 0;
        return foundAt("next");
    }

    function previous() as Media.Content? {
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debugCode("Iterator: previous from", _index);
        }
        if (_index - 1 < 0) {
            if (Log.LEVEL >= Log.DEBUG) {
                Log.debug("Iterator: previous returns null (start of book)");
            }
            return null;
        }
        _index -= 1;
        _startPosition = 0;
        return foundAt("previous");
    }

    function peekNext() as Media.Content? {
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debugCode("Iterator: peekNext after", _index);
        }
        return hand(contentAt(_index + 1));
    }

    function peekPrevious() as Media.Content? {
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debugCode("Iterator: peekPrevious before", _index);
        }
        return hand(contentAt(_index - 1));
    }

    //! The API allows an error object here, but the override has to be declared
    //! as Content. `as Content` would throw on the error object, so the check
    //! is turned off for this return only.
    (:typecheck(false))
    private function hand(found as Object?) as Media.Content? {
        return found;
    }

    private function foundAt(which as String) as Media.Content? {
        var found = contentAt(_index);
        if (Log.LEVEL >= Log.DEBUG) {
            var kind = "an error";
            if (found == null) {
                kind = "null";
            } else if (found instanceof Media.Content) {
                kind = "content";
            }
            Log.debug("Iterator: " + which + " returns " + kind + " for " + _index.toString());
        }
        return hand(found);
    }

    function shuffling() as Boolean {
        return false;
    }

    //! Must not return null: that made selecting a book do nothing.
    function repeatMode() as Media.RepeatMode? {
        return Media.REPEAT_MODE_OFF;
    }

    function canSkip() as Boolean {
        return true;
    }

    //! Never return null: the native player dereferences it and fails with
    //! "Error starting music app". Built once; the controls do not change.
    function getPlaybackProfile() as Media.PlaybackProfile? {
        return _profile;
    }
}

//! The player calls methods on whatever getContentIterator() returns. null
//! is a Null Reference on the watch ("Failed invoking <symbol>"), which is
//! the IQ screen when playback starts and no book is stored.
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

//! Shared so the empty iterator and a real book expose the same controls.
module PlaybackProfile {

    function standard() as Media.PlaybackProfile {
        var profile = new Media.PlaybackProfile();
        // The first entry may act as a hotkey, so skip forward goes first.
        // PLAYBACK must stay, or no play/pause is rendered; first, it binds a
        // second play button to the hotkey.
        profile.playbackControls = [
            Media.PLAYBACK_CONTROL_SKIP_FORWARD,
            Media.PLAYBACK_CONTROL_PLAYBACK,
            Media.PLAYBACK_CONTROL_SKIP_BACKWARD,
            Media.PLAYBACK_CONTROL_PREVIOUS,
            Media.PLAYBACK_CONTROL_NEXT
        ] as Array<Media.PlaybackControl>;
        // 30 both ways so the stock skip icons (which say 30) stay correct.
        profile.skipForwardTimeDelta = 30;
        profile.skipBackwardTimeDelta = 30;
        profile.attemptSkipAfterThumbsDown = false;
        // Without these notifications the app would never learn where the listener is.
        profile.requirePlaybackNotification = true;
        profile.playbackNotificationThreshold = 30;
        profile.skipPreviousThreshold = 4;
        return profile;
    }
}
