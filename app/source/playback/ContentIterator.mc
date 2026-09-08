import Toybox.Lang;
import Toybox.Media;

//! Order and metadata of a book's segments.
//!
//! Two things make the difference between a music player and an audiobook:
//! the metadata comes from the Object Store instead of the file's tags, and
//! the current segment is returned as ActiveContent with a remembered
//! position — only then does the player resume in the middle of a chapter.
class AbContentIterator extends Media.ContentIterator {

    private var _bookId as String;
    private var _refs as Array;
    private var _titles as Array<String>;
    private var _album as String;
    private var _artist as String;
    private var _index as Number;
    private var _startPosition as Number;
    private var _startApplied as Boolean;

    function initialize(bookId as String) {
        ContentIterator.initialize();
        _bookId = bookId;
        _refs = [] as Array;
        _titles = [] as Array<String>;

        var info = Store.bookInfo(bookId);
        _album = info[0];
        _artist = info[1];

        buildPlaylist();
        Log.code("Iterator: segments", _refs.size());
        probeCache();

        _index = 0;
        _startPosition = 0;
        _startApplied = false;
        var position = Store.position(bookId);
        if (position != null) {
            var wanted = indexOfSegment(position[0]);
            if (wanted >= 0) {
                _index = wanted;
                _startPosition = position[1];
                skipFinishedSegment();
            }
        }
        Log.code("Iterator: starting at", _index);
        Log.code("Iterator: start position", _startPosition);
    }

    //! A segment listened to the end is not a starting point.
    //!
    //! When a segment completes, its full duration is remembered as the
    //! position — right for reporting to the server, but as a starting point
    //! exactly the end. Without this step playback would begin past the last
    //! sound of the segment and be over immediately.
    private function skipFinishedSegment() as Void {
        var duration = durationAt(_index);
        if (duration <= 0 || _startPosition < duration) {
            return;
        }
        if (_index + 1 < _refs.size()) {
            _index += 1;
            _startPosition = 0;
            return;
        }
        // The last segment was listened through: the book is finished.
        // Starting over is the only choice that does not end in silence.
        _index = 0;
        _startPosition = 0;
    }

    private function durationAt(position as Number) as Number {
        if (position < 0 || position >= _refs.size()) {
            return 0;
        }
        var parts = Store.trackInfo(_bookId, _refs[position]);
        return (parts == null) ? 0 : Store.toNumber(parts[1]);
    }

    //! Put the segments into their order.
    //!
    //! The Object Store is an unordered map, so entries are placed by a field
    //! instead of being sorted — Monkey C has no Array.sort.
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

    //! What is really in the media cache.
    //!
    //! The object store only remembers IDs. Whether a file still stands behind
    //! one is something only the cache can say — and without that cross-check,
    //! "the player does nothing" cannot be told apart from "the file is not
    //! there at all".
    private function probeCache() as Void {
        var stats = Media.getCacheStatistics();
        Log.line("Cache: " + stats.size.toString() + " of " + stats.capacity.toString() + " bytes");
        var count = 0;
        var iterator = Media.getContentRefIter({ :contentType => Media.CONTENT_TYPE_AUDIO });
        var ref = iterator.next();
        var first = null as Object?;
        while (ref != null) {
            if (count == 0) {
                first = ref.getId();
            }
            count += 1;
            ref = iterator.next();
        }
        Log.code("Cache: audio entries", count);
        Log.line("Cache: first cache ID " + describe(first));
        if (_refs.size() > 0) {
            Log.line("Cache: first store ID " + describe(_refs[0]));
        }
    }

    //! The docs say getCachedContentObj() wants a String ID for audio. On the
    //! fēnix they are numbers, and they resolve cleanly — the type is logged
    //! anyway, because it travels through the store and could change on the way.
    private function describe(id as Object?) as String {
        if (id == null) {
            return "none";
        }
        if (id instanceof String) {
            return "String '" + id + "'";
        }
        if (id instanceof Number) {
            return "Number " + id.toString();
        }
        if (id instanceof Long) {
            return "Long " + id.toString();
        }
        return "other type";
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

    //! The content object comes from the cache — it is not built by hand.
    //!
    //! A hand-made `new Media.Content(ref, metadata)` carries the same
    //! ContentRef and still cannot be played: the player accepts it, asks for
    //! the profile, draws its screen and never starts decoding — without a
    //! single SONG_EVENT. Only the object from getCachedContentObj() carries
    //! what it needs to play the file.
    private function contentAt(position as Number) as Media.Content? {
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
            Log.line("Iterator: cache threw " + ((message == null) ? "?" : message));
            return null;
        }
        if (content == null) {
            Log.code("Iterator: nothing in cache for", position);
            return null;
        }
        // The titles stay ours: the file holds the chapter name, but only the
        // store knows book, author and ordering.
        content.setMetadata(metadataFor(position));
        return content;
    }

    function get() as Media.Content? {
        Log.code("Iterator: get at", _index);
        var content = contentAt(_index);
        if (content == null) {
            return null;
        }
        // ActiveContent only when there really is a mid-segment point to
        // resume from, and only once: otherwise a later jump back to the same
        // segment would land on the old spot again instead of at its start.
        // At position 0 the plain Content from the cache is the right thing.
        if (_startPosition > 0 && !_startApplied) {
            _startApplied = true;
            Log.code("Iterator: ActiveContent from", _startPosition);
            return new Media.ActiveContent(
                new Media.ContentRef(_refs[_index], Media.CONTENT_TYPE_AUDIO),
                content.getMetadata(),
                _startPosition
            );
        }
        return content;
    }

    function next() as Media.Content? {
        Log.code("Iterator: next from", _index);
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
        Log.code("Iterator: peekNext after", _index);
        return contentAt(_index + 1);
    }

    function peekPrevious() as Media.Content? {
        return contentAt(_index - 1);
    }

    function shuffling() as Boolean {
        // An audiobook in random order is no longer an audiobook.
        return false;
    }

    function canSkip() as Boolean {
        return true;
    }

    function getPlaybackProfile() as Media.PlaybackProfile? {
        Log.line("Iterator: getPlaybackProfile");
        var profile = new Media.PlaybackProfile();
        profile.playbackControls = [
            Media.PLAYBACK_CONTROL_PLAYBACK,
            Media.PLAYBACK_CONTROL_PREVIOUS,
            Media.PLAYBACK_CONTROL_NEXT,
            Media.PLAYBACK_CONTROL_SKIP_FORWARD,
            Media.PLAYBACK_CONTROL_SKIP_BACKWARD
        ] as Array<Media.PlaybackControl>;
        // Audiobook values instead of the music default of two times 30 seconds.
        profile.skipForwardTimeDelta = 30;
        profile.skipBackwardTimeDelta = 15;
        profile.attemptSkipAfterThumbsDown = false;
        // Without these notifications the app would never learn where the listener is.
        profile.requirePlaybackNotification = true;
        profile.playbackNotificationThreshold = 30;
        profile.skipPreviousThreshold = 4;
        return profile;
    }
}
