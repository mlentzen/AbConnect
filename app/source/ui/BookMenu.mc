import Toybox.Lang;
import Toybox.WatchUi;

class BookMenu extends WatchUi.Menu2 {

    function initialize() {
        Menu2.initialize({ :title => Rez.Strings.menuBooks });

        var books = Store.localBooks();
        Log.debugCode("Books: playable", books.size());
        for (var i = 0; i < books.size(); ++i) {
            // Listed as soon as one segment is on the watch, so the title line
            // can still be missing and the author can be blank.
            var info = Store.bookInfo(books[i]);
            addItem(new WatchUi.MenuItem(
                MenuText.label(info[0], books[i]),
                MenuText.sublabel(info[1]),
                books[i],
                null
            ));
        }
    }
}

class BookMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof String)) {
            return;
        }
        Log.info("Books: chapters of " + id);
        WatchUi.pushView(
            new ChapterMenu(id),
            new ChapterMenuDelegate(id),
            WatchUi.SLIDE_IMMEDIATE
        );
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}
