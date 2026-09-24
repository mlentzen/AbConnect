import Toybox.Lang;
import Toybox.WatchUi;

//! Every book that has something playable on the watch.
//!
//! Deliberately not the playlist: this menu is reached with no network and has
//! to answer what can be listened to right now. What *should* be on the watch
//! is the sync configuration's question, and it has its own screen for it.
class BookMenu extends WatchUi.Menu2 {

    function initialize() {
        Menu2.initialize({ :title => Rez.Strings.menuBooks });

        var books = Store.localBooks();
        Log.debugCode("Books: playable", books.size());
        for (var i = 0; i < books.size(); ++i) {
            var info = Store.bookInfo(books[i]);
            addItem(new WatchUi.MenuItem(info[0], info[1], books[i], null));
        }
    }
}

class BookMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        Idle.poke();
        var id = item.getId();
        if (!(id instanceof String)) {
            return;
        }
        // A book opens its chapters instead of starting straight away. The row
        // marked "Resume" carries on exactly where the listening stopped, so
        // the extra press buys the way into the rest of the book without
        // costing the way back into the middle of it — and for the book that
        // was last playing there is no extra press at all, because Continue
        // sits at the top of the menu above this one.
        Log.info("Books: chapters of " + id);
        WatchUi.pushView(
            new ChapterMenu(id),
            new ChapterMenuDelegate(id),
            WatchUi.SLIDE_IMMEDIATE
        );
    }

    function onBack() as Void {
        Idle.poke();
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}
