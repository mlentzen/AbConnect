import Toybox.Lang;
import Toybox.Media;

//! Order and metadata of a book's segments.
//!
//! Two things make the difference between a music player and an audiobook:
//! the metadata comes from the Object Store instead of the file's tags, and
//! the current segment is returned as ActiveContent with a remembered
//! position — only then does the player resume in the middle of a chapter.
//!
//! Every step is traced. The player says nothing about why it does not play,
//! so the only account of what it was handed is the one this class writes
//! itself. Log.debug() carries the per-segment flood; the levels above it
//! carry the few lines that stay worth reading once it is over.
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
        } else {
            Log.debugCode("Iterator: segments", _refs.size());
        }
        // Guarded as a whole, not merely quietened: probing walks the entire
        // media cache and resolves every segment in it against the store. That
        // is a price worth paying to find out why nothing plays, and none at
        // all when the answer would not be printed.
        if (Log.LEVEL >= Log.DEBUG) {
            probeCache();
        }

        _index = 0;
        _startPosition = 0;
        _startApplied = false;
        var position = Store.position(bookId);
        if (position == null) {
            Log.debug("Iterator: nothing remembered, starting at the beginning");
        } else {
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
                // Remembered, but not on the watch: the segment was deleted or
                // never downloaded. Beginning of the book is all that is left.
                Log.errorCode("Iterator: no local segment numbered", position[0]);
            }
        }
        Log.debugCode("Iterator: starting at", _index);
        Log.debugCode("Iterator: start position", _startPosition);
    }

    //! A segment listened to the end is not a starting point.
    //!
    //! When a segment completes, its full duration is remembered as the
    //! position — right for reporting to the server, but as a starting point
    //! exactly the end. Without this step playback would begin past the last
    //! sound of the segment and be over immediately.
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
            Log.debugCode("Iterator: segment still has sound left", _index);
            return;
        }
        if (_index + 1 < _refs.size()) {
            _index += 1;
            _startPosition = 0;
            Log.debugCode("Iterator: segment was finished, moving on to", _index);
            return;
        }
        // The last segment was listened through: the book is finished.
        // Starting over is the only choice that does not end in silence.
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
            // The playlist was built from the same store, so this means the
            // entry changed shape underneath us — worth a line of its own.
            Log.error("Iterator: no store entry for " + Log.describe(_refs[position]));
            return 0;
        }
        return Store.toNumber(parts[1]);
    }

    //! The playlist, and the titles that go with it.
    //!
    //! The ordering itself lives in Store.orderedRefs(): the chapter menu walks
    //! the same book and the two must never disagree about what segment 3 is.
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

    //! What is really in the media cache.
    //!
    //! The object store only remembers IDs. Whether a file still stands behind
    //! one is something only the cache can say — and without that cross-check,
    //! "the player does nothing" cannot be told apart from "the file is not
    //! there at all".
    private function probeCache() as Void {
        var stats = Media.getCacheStatistics();
        Log.debug("Cache: " + stats.size.toString() + " of " + stats.capacity.toString() + " bytes");
        var count = 0;
        var ours = 0;
        var iterator = Media.getContentRefIter({ :contentType => Media.CONTENT_TYPE_AUDIO });
        var ref = iterator.next();
        while (ref != null) {
            count += 1;
            var id = null as Object?;
            try {
                id = ref.getId();
            } catch (ex) {
                Log.warn("Cache: an entry would not give up its ID");
            }
            var mine = indexOfRef(id);
            if (mine >= 0) {
                ours += 1;
            }
            // Whose file this is decides everything: a cache full of audio the
            // store knows no ID for looks, from the player's side, exactly like
            // an empty one.
            Log.debug(
                "cache " + Log.describe(id)
                    + ((mine >= 0) ? (" = playlist " + mine.toString()) : " (not this book)")
            );
            ref = iterator.next();
        }
        Log.debugCode("Cache: audio entries", count);
        Log.debugCode("Cache: entries of this book", ours);
        Log.debugCode("Iterator: resolvable", resolvableCount());
    }

    //! Where a cache ID sits in the playlist, or -1.
    private function indexOfRef(id as Object?) as Number {
        if (id == null) {
            return -1;
        }
        for (var i = 0; i < _refs.size(); ++i) {
            if (_refs[i] == id) {
                return i;
            }
        }
        return -1;
    }

    //! How many of our segments the cache actually hands back.
    //!
    //! This one number decides where the fault lies. Zero means the player was
    //! never given anything to play and the ref IDs did not survive the round
    //! trip through the object store; a full count means the player was handed
    //! content and refused to decode it — a question about the audio, not
    //! about this app.
    private function resolvableCount() as Number {
        var found = 0;
        for (var i = 0; i < _refs.size(); ++i) {
            var content = null as Media.Content?;
            try {
                content = Media.getCachedContentObj(
                    new Media.ContentRef(_refs[i], Media.CONTENT_TYPE_AUDIO)
                );
            } catch (ex) {
                var message = ex.getErrorMessage();
                Log.error(
                    "Iterator: cache threw for " + Log.describe(_refs[i])
                        + ": " + ((message == null) ? "?" : message)
                );
                content = null;
            }
            if (content != null) {
                found += 1;
                Log.debug("segment " + i.toString() + " " + Log.describe(_refs[i]) + " resolves");
            } else {
                // The type is worth having: it is what a broken round trip
                // through the store would show up as.
                Log.error("Iterator: unresolved " + Log.describe(_refs[i]));
            }
        }
        return found;
    }

    private function indexOfSegment(segment as Number) as Number {
        for (var i = 0; i < _refs.size(); ++i) {
            var parts = Store.trackInfo(_bookId, _refs[i]);
            if (parts != null && Store.toNumber(parts[0]) == segment) {
                Log.debugCode("Iterator: segment " + segment.toString() + " is playlist position", i);
                return i;
            }
        }
        Log.errorCode("Iterator: the playlist has no segment numbered", segment);
        return -1;
    }

    //! Our titles onto the cache's own metadata object — never onto a fresh one.
    //!
    //! ContentMetadata carries three fields that cannot be read or written from
    //! here: duration, audioFormat and encoding are protected, and the cache
    //! fills them in from the file. A `new ContentMetadata()` has them empty, so
    //! handing one to setMetadata() throws the file's duration away — and the
    //! player then ends the track about a second after it starts, START and
    //! COMPLETE back to back, marching through the whole book in eight seconds.
    //! Setting the four public fields on the object the cache handed us keeps
    //! the other three.
    private function applyMetadata(content as Media.Content, position as Number) as Void {
        var metadata = content.getMetadata();
        if (metadata == null) {
            // Nothing to preserve; a fresh object is all there is to give.
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

    //! Only for content that arrives without metadata of its own. The duration
    //! is missing from this one, with the consequences described above.
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
        Log.debugCode("Iterator: content asked for", position);
        if (position < 0 || position >= _refs.size()) {
            Log.error(
                "Iterator: " + position.toString() + " is outside a playlist of "
                    + _refs.size().toString()
            );
            return null;
        }
        var content = null as Media.Content?;
        try {
            content = Media.getCachedContentObj(
                new Media.ContentRef(_refs[position], Media.CONTENT_TYPE_AUDIO)
            );
        } catch (ex) {
            var message = ex.getErrorMessage();
            Log.error("Iterator: cache threw " + ((message == null) ? "?" : message));
            return null;
        }
        if (content == null) {
            Log.errorCode("Iterator: nothing in cache for", position);
            return null;
        }
        // Full account of the object handed to the player. If the ref it
        // carries is not the one we asked for, everything after this is built
        // on sand — and that is invisible without saying so out loud.
        var carried = null as Object?;
        var startAt = "?";
        var kind = "Content";
        try {
            carried = content.getContentRef().getId();
            // Declared as Number, but a plain Content need not carry one, and a
            // crash in the diagnostic build would cost us the whole run.
            var where = content.getPlaybackStartPosition();
            startAt = (where == null) ? "null" : where.toString();
            if (content instanceof Media.ActiveContent) {
                kind = "ActiveContent";
            }
        } catch (ex) {
            Log.warn("Iterator: inspecting the content threw");
        }
        if (Log.LEVEL >= Log.DEBUG) {
            Log.debug(
                "Iterator: resolved " + position.toString()
                    + " asked " + Log.describe(_refs[position])
                    + " carries " + Log.describe(carried)
                    + " start " + startAt
                    + " kind " + kind
            );
            describeMetadata("before", content);
        }
        // The titles stay ours: the file holds the chapter name, but only the
        // store knows book, author and ordering.
        applyMetadata(content, position);
        // Reading the metadata back is the proof that our write survived —
        // proof nobody reads in a build that prints nothing, and it costs a
        // getMetadata() per track to produce.
        if (Log.LEVEL >= Log.DEBUG) {
            describeMetadata("after", content);
        }
        return content;
    }

    //! What the player will show — and proof that metadata survives our write.
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
        // The player shows these too, and an empty artist line on the watch is
        // answered here.
        Log.debug(
            "metadata " + when
                + " artist=" + ((meta.artist == null) ? "null" : meta.artist)
                + " genre=" + ((meta.genre == null) ? "null" : meta.genre)
        );
    }

    function get() as Media.Content? {
        Log.debugCode("Iterator: get at", _index);
        var content = contentAt(_index);
        if (content == null) {
            Log.error("Iterator: get returns null");
            return null;
        }
        // ActiveContent only when there really is a mid-segment point to
        // resume from, and only once: otherwise a later jump back to the same
        // segment would land on the old spot again instead of at its start.
        // At position 0 the plain Content from the cache is the right thing.
        if (_startPosition > 0 && !_startApplied) {
            _startApplied = true;
            Log.debugCode("Iterator: ActiveContent from", _startPosition);
            // The ref comes from the cached Content itself, not freshly built.
            // contentAt()'s own doc note applies here too: a hand-made
            // `new Media.Content(ref, metadata)` carries the same ContentRef and
            // still does not play — only the object getCachedContentObj() hands
            // back carries what it needs to. A ContentRef built by hand for
            // ActiveContent is the same kind of stand-in and untested on this
            // device; content.getContentRef() is the one already proven to work.
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
        Log.debugCode("Iterator: next from", _index);
        if (_index + 1 >= _refs.size()) {
            Log.info("Iterator: next returns null (end of book)");
            return null;
        }
        _index += 1;
        _startPosition = 0;
        var content = contentAt(_index);
        if (content == null) {
            Log.errorCode("Iterator: next has no content for", _index);
        } else {
            Log.debugCode("Iterator: next returns content for", _index);
        }
        return content;
    }

    function previous() as Media.Content? {
        Log.debugCode("Iterator: previous from", _index);
        if (_index - 1 < 0) {
            Log.debug("Iterator: previous returns null (start of book)");
            return null;
        }
        _index -= 1;
        _startPosition = 0;
        var content = contentAt(_index);
        if (content == null) {
            Log.errorCode("Iterator: previous has no content for", _index);
        } else {
            Log.debugCode("Iterator: previous returns content for", _index);
        }
        return content;
    }

    //! The player looks ahead before it plays anything. Whether it does so at
    //! all, and how often, is half the answer to why nothing starts — so the
    //! peeks are traced as loudly as the real moves.
    function peekNext() as Media.Content? {
        Log.debugCode("Iterator: peekNext after", _index);
        var content = contentAt(_index + 1);
        Log.debug((content == null) ? "Iterator: peekNext returns null" : "Iterator: peekNext returns content");
        return content;
    }

    function peekPrevious() as Media.Content? {
        Log.debugCode("Iterator: peekPrevious before", _index);
        var content = contentAt(_index - 1);
        Log.debug((content == null) ? "Iterator: peekPrevious returns null" : "Iterator: peekPrevious returns content");
        return content;
    }

    function shuffling() as Boolean {
        // An audiobook in random order is no longer an audiobook.
        Log.debug("Iterator: shuffling -> false");
        return false;
    }

    //! Part of the ContentIterator contract and never implemented here.
    //!
    //! Tried null (the system default, and what the one working third-party
    //! provider returns) as a diagnostic step. That made things strictly
    //! worse — selecting a book stopped doing anything at all, consistent
    //! with the restart into playback mode crashing right where this is
    //! called, immediately after the iterator is built. Back to an explicit
    //! value; whatever is silencing playback, null is not the way there.
    function repeatMode() as Media.RepeatMode? {
        Log.debug("Iterator: repeatMode -> off");
        return Media.REPEAT_MODE_OFF;
    }

    function canSkip() as Boolean {
        Log.debug("Iterator: canSkip -> true");
        return true;
    }

    //! A profile, and never null.
    //!
    //! Null is what the type signature permits and what the player cannot
    //! survive: returning it killed the startup outright with "Error starting
    //! music app", a Null Reference Error in system code immediately after this
    //! call and before any further callback. The native player dereferences
    //! whatever comes back from here.
    //!
    //! The custom values below were suspected of blocking playback and are
    //! back: the silence was the metadata write in applyMetadata() destroying
    //! the track duration, and with that fixed the same profile plays through.
    function getPlaybackProfile() as Media.PlaybackProfile? {
        Log.debug("Iterator: getPlaybackProfile -> custom");
        var profile = new Media.PlaybackProfile();
        // Order matters, and membership matters more. The SDK says this array
        // "determines which native media player control options are rendered
        // and available", and separately that "the first entry in the array may
        // be used as a hotkey". So PLAYBACK_CONTROL_PLAYBACK has to stay — drop
        // it and the player renders no play/pause at all — but putting it first
        // is what bound a second play button to the hotkey next to the one on
        // START. Skip forward is the hotkey worth having in an audiobook.
        profile.playbackControls = [
            Media.PLAYBACK_CONTROL_SKIP_FORWARD,
            Media.PLAYBACK_CONTROL_PLAYBACK,
            Media.PLAYBACK_CONTROL_SKIP_BACKWARD,
            Media.PLAYBACK_CONTROL_PREVIOUS,
            Media.PLAYBACK_CONTROL_NEXT
        ] as Array<Media.PlaybackControl>;
        // Symmetric on purpose. The SDK warns that a custom delta needs custom
        // artwork, because the stock skip icons say 30 — at 30 both ways the
        // stock icons are simply correct, and an audiobook is skipped by equal
        // steps in both directions anyway.
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
