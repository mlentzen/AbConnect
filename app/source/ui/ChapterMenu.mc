import Toybox.Lang;
import Toybox.Media;
import Toybox.Time;
import Toybox.WatchUi;

//! The chapters of one book, and the one the listening stopped in.
//!
//! The titles are the proxy's: it cuts on the book's own chapter marks and
//! falls back to a 15-minute grid where a book has none. Either way the store
//! already holds the title and the duration of every segment, so this menu
//! needs nothing from the network.
class ChapterMenu extends WatchUi.Menu2 {

    function initialize(bookId as String) {
        var info = Store.bookInfo(bookId);
        Menu2.initialize({ :title => info[0] });

        var refs = Store.orderedRefs(bookId);
        var position = Store.position(bookId);
        var remembered = (position == null) ? -1 : position[0];
        Log.code("Chapters: building for segments", refs.size());

        // The start of a chapter is where all the ones before it end. The store
        // knows durations, not offsets — an audiobook is cut into pieces and
        // nobody writes down where each piece sits in the whole.
        var start = 0;
        for (var i = 0; i < refs.size(); ++i) {
            var parts = Store.trackInfo(bookId, refs[i]);
            if (parts == null) {
                continue;
            }
            var segment = Store.toNumber(parts[0]);
            var sublabel = clock(start);
            if (segment == remembered) {
                // The row that continues instead of restarting, and the only
                // one that says so.
                sublabel = sublabel + "  " + (WatchUi.loadResource(Rez.Strings.resume) as String);
            }
            addItem(new WatchUi.MenuItem(parts[2], sublabel, segment, null));
            start += Store.toNumber(parts[1]);
        }
    }

    //! h:mm:ss — a chapter can begin ten hours into a book.
    private static function clock(seconds as Number) as String {
        return (seconds / 3600).toString()
            + ":" + ((seconds / 60) % 60).format("%02d")
            + ":" + (seconds % 60).format("%02d");
    }
}

//! Picking a chapter is picking a starting point.
//!
//! The player is never told where to begin: AbContentIterator starts wherever
//! Store.position() points, so writing the position and starting playback is
//! the whole mechanism. The remembered chapter is the exception — it is left
//! alone, and so keeps the offset inside the chapter instead of restarting it.
class ChapterMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _bookId as String;

    function initialize(bookId as String) {
        Menu2InputDelegate.initialize();
        _bookId = bookId;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var segment = item.getId();
        if (!(segment instanceof Number)) {
            return;
        }
        var position = Store.position(_bookId);
        var remembered = (position == null) ? -1 : position[0];
        if (segment != remembered) {
            // A jump is progress too. It goes out with the next push, so the
            // phone and the server follow the watch instead of pulling it back.
            Log.code("Chapters: jumping to segment", segment);
            Store.rememberPosition(_bookId, segment, 0, Time.now().value());
        } else {
            Log.code("Chapters: resuming segment", segment);
        }
        Current.set(_bookId);
        // startPlayback() ends the app and restarts it in playback mode;
        // anything after it would no longer run.
        Log.line("Chapters: startPlayback " + _bookId);
        Media.startPlayback(_bookId);
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}
