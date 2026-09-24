import Toybox.Lang;
import Toybox.Media;
import Toybox.Time;
import Toybox.WatchUi;

//! Identifiers of the two rows that are not chapters. Symbols, so they can
//! never collide with a segment number — those are always numbers.
const RESUME_ITEM = :resumeBook;
const FROM_START_ITEM = :fromStart;

//! What to do with a book: carry on, begin again, or go to a chapter.
//!
//! The chapter titles are the proxy's: it cuts on the book's own chapter marks
//! and falls back to a 15-minute grid where a book has none. Either way the
//! store already holds the title and the duration of every segment, so this
//! menu needs nothing from the network to be drawn.
class ChapterMenu extends WatchUi.Menu2 {

    function initialize(bookId as String) {
        var info = Store.bookInfo(bookId);
        Menu2.initialize({ :title => info[0] });

        var refs = Store.orderedRefs(bookId);
        var position = Store.position(bookId);
        Log.debugCode("Chapters: building for segments", refs.size());

        // Resuming comes first, and only when there is something to resume. Its
        // subtitle says where it will land, which is worth more than a mark
        // buried somewhere in the list below.
        if (position != null) {
            addItem(
                new WatchUi.MenuItem(
                    WatchUi.loadResource(Rez.Strings.resume) as String,
                    landingPoint(bookId, refs, position),
                    $.RESUME_ITEM,
                    null
                )
            );
        }
        addItem(
            new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.fromStart) as String,
                null,
                $.FROM_START_ITEM,
                null
            )
        );

        // Every chapter row starts its chapter at the beginning. The chapter
        // last listened to used to be the exception and resumed mid-way — one
        // row behaving unlike its neighbours, for no reason now that resuming
        // has a row of its own.
        //
        // A chapter starts where all the ones before it end. The store knows
        // durations, not offsets: a book is cut into pieces and nobody writes
        // down where each piece sits in the whole.
        var start = 0;
        for (var i = 0; i < refs.size(); ++i) {
            var parts = Store.trackInfo(bookId, refs[i]);
            if (parts == null) {
                continue;
            }
            addItem(
                new WatchUi.MenuItem(parts[2], clock(start), Store.toNumber(parts[0]), null)
            );
            start += Store.toNumber(parts[1]);
        }
    }

    //! "Section 3 - 0:29:10": the chapter the resume lands in, and where in the
    //! whole book that is.
    private static function landingPoint(
        bookId as String, refs as Array, position as Array<Number>
    ) as String {
        var start = 0;
        for (var i = 0; i < refs.size(); ++i) {
            var parts = Store.trackInfo(bookId, refs[i]);
            if (parts == null) {
                continue;
            }
            if (Store.toNumber(parts[0]) == position[0]) {
                return parts[2] + " - " + clock(start + position[1]);
            }
            start += Store.toNumber(parts[1]);
        }
        // The remembered segment is not on the watch any more. The offset alone
        // is still true, and saying nothing would be worse.
        return clock(position[1]);
    }

    //! h:mm:ss — a chapter can begin ten hours into a book.
    private static function clock(seconds as Number) as String {
        return (seconds / 3600).toString()
            + ":" + ((seconds / 60) % 60).format("%02d")
            + ":" + (seconds % 60).format("%02d");
    }
}

//! Picking a row is picking a starting point.
//!
//! The player is never told where to begin: AbContentIterator starts wherever
//! Store.position() points, so writing the position and starting playback is
//! the whole mechanism. Resuming is the one row that first asks the server
//! whether it knows better.
class ChapterMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _bookId as String;
    private var _push as ProgressPush;

    function initialize(bookId as String) {
        Menu2InputDelegate.initialize();
        _bookId = bookId;
        // Held rather than made on demand: the push outlives the press, and a
        // local one could be collected while its response is still in flight.
        _push = new ProgressPush();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        Idle.poke();
        var id = item.getId();
        if (id == $.RESUME_ITEM) {
            Log.info("Chapters: agreeing with the server before playing");
            _push.syncThenPlay(_bookId);
            return;
        }
        if (id == $.FROM_START_ITEM) {
            startAt(firstSegment());
            return;
        }
        if (id instanceof Number) {
            startAt(id);
        }
    }

    //! The first segment that is really on the watch.
    //!
    //! A gap in the numbering would otherwise send "from the start" to a
    //! segment that was never downloaded.
    private function firstSegment() as Number {
        var refs = Store.orderedRefs(_bookId);
        for (var i = 0; i < refs.size(); ++i) {
            var parts = Store.trackInfo(_bookId, refs[i]);
            if (parts != null) {
                return Store.toNumber(parts[0]);
            }
        }
        return 0;
    }

    private function startAt(segment as Number) as Void {
        // A jump is progress too. It goes out with the next push, so the phone
        // and the server follow the watch instead of pulling it back.
        Log.code("Chapters: starting segment", segment);
        Store.rememberPosition(_bookId, segment, 0, Time.now().value());
        Current.set(_bookId);
        // startPlayback() ends the app and restarts it in playback mode;
        // anything after it would no longer run.
        Log.info("Chapters: startPlayback " + _bookId);
        Media.startPlayback(_bookId);
    }

    function onBack() as Void {
        Idle.poke();
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}
