import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Selection of which book the player plays.
class PlaybackConfigView extends WatchUi.View {

    private var _menuShown as Boolean;

    function initialize() {
        View.initialize();
        _menuShown = false;
    }

    function onShow() as Void {
        if (_menuShown) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        var books = Store.localBooks();
        if (books.size() == 0) {
            WatchUi.switchToView(
                new MessageView(WatchUi.loadResource(Rez.Strings.nothingOnWatch) as String),
                null,
                WatchUi.SLIDE_IMMEDIATE
            );
            return;
        }
        var menu = new WatchUi.Menu2({ :title => Rez.Strings.menuPlaybackTitle });
        for (var i = 0; i < books.size(); ++i) {
            var info = Store.bookInfo(books[i]);
            menu.addItem(new WatchUi.MenuItem(info[0], info[1], books[i], null));
        }
        _menuShown = true;
        WatchUi.pushView(menu, new PlaybackConfigDelegate(), WatchUi.SLIDE_IMMEDIATE);
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
    }
}

class PlaybackConfigDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id instanceof String) {
            Current.set(id);
        }
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}
