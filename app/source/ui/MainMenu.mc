import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.WatchUi;

// Symbols, so they never collide with book IDs (always strings).
const CONTINUE_ITEM = :continuePlayback;
const BOOKS_ITEM = :books;
const SERVER_ITEM = :onServer;
const SYNC_ITEM = :syncNow;
const INFO_ITEM = :info;
const SETTINGS_ITEM = :settings;

class MainMenu extends WatchUi.Menu2 {

    private var _state as String;

    function initialize() {
        Menu2.initialize({ :title => Rez.Strings.AppName });
        _state = "";
        build();
    }

    // Rebuilt only when the store changed: a rebuild moves the cursor to the top.
    function onShow() as Void {
        Menu2.onShow();
        if (state().equals(_state)) {
            return;
        }
        Log.info("Menu: the store changed, rebuilding");
        var removed = deleteItem(0);
        while (removed == true) {
            removed = deleteItem(0);
        }
        build();
        setFocus(0);
    }

    private static function state() as String {
        return stateWith(Store.playlistCounts());
    }

    private static function stateWith(counts as Array<Number>) as String {
        var resumable = Store.resumableBook();
        return ((resumable == null) ? "" : resumable)
            + "|" + counts[0].toString()
            + "|" + counts[1].toString()
            + "|" + ProgressPush.pending().toString()
            + "|" + (Media.getCacheStatistics().size / 1048576).toString();
    }

    private function build() as Void {
        var counts = Store.playlistCounts();
        _state = stateWith(counts);

        var resumable = Store.resumableBook();
        if (resumable != null) {
            addItem(row(
                Rez.Strings.menuContinue,
                MenuText.sublabel(Store.bookInfo(resumable)[0]),
                $.CONTINUE_ITEM, Rez.Drawables.IconContinue
            ));
        }

        var books = Store.localBooks();
        Log.debugCode("Menu: playable", books.size());
        addItem(row(
            Rez.Strings.menuBooks, localSubtitle(books.size()),
            $.BOOKS_ITEM, Rez.Drawables.IconBooks
        ));

        addItem(row(
            Rez.Strings.sendProgress, ProgressPush.rowSubtitle(),
            $.PROGRESS_ITEM, Rez.Drawables.IconSync
        ));

        addItem(row(
            Rez.Strings.menuSync, null,
            $.SYNC_ITEM, Rez.Drawables.IconSync
        ));

        addItem(row(
            Rez.Strings.syncFromServer, serverSubtitle(counts),
            $.SERVER_ITEM, Rez.Drawables.IconSync
        ));

        addItem(row(
            Rez.Strings.menuSettings, null,
            $.SETTINGS_ITEM, Rez.Drawables.IconSettings
        ));

        addItem(row(
            Rez.Strings.menuInfo, null,
            $.INFO_ITEM, Rez.Drawables.IconInfo
        ));
    }

    private static function row(
        label as Lang.ResourceId, subLabel as String?, id as Symbol, icon as Lang.ResourceId
    ) as WatchUi.IconMenuItem {
        return new WatchUi.IconMenuItem(
            WatchUi.loadResource(label) as String,
            subLabel,
            id,
            new MenuIcon(icon),
            null
        );
    }

    private static function localSubtitle(count as Number) as String {
        if (count == 0) {
            return WatchUi.loadResource(Rez.Strings.nothingOnWatch) as String;
        }
        return count.toString() + " " + (WatchUi.loadResource(Rez.Strings.booksCount) as String);
    }

    private static function serverSubtitle(counts as Array<Number>) as String? {
        if (counts[0] == 0) {
            return null;
        }
        if (counts[1] > 0) {
            return counts[1].toString() + " " + (WatchUi.loadResource(Rez.Strings.progressPending) as String);
        }
        return counts[0].toString() + " " + (WatchUi.loadResource(Rez.Strings.booksCount) as String);
    }
}

//! IconMenuItem needs a Drawable: a plain BitmapResource crashed the fēnix
//! with "Symbol Not Found".
class MenuIcon extends WatchUi.Drawable {

    private var _bitmap as WatchUi.BitmapResource;

    function initialize(rezId as Lang.ResourceId) {
        Drawable.initialize({});
        _bitmap = WatchUi.loadResource(rezId) as WatchUi.BitmapResource;
    }

    function draw(dc as Graphics.Dc) as Void {
        dc.drawBitmap(
            (dc.getWidth() - _bitmap.getWidth()) / 2,
            (dc.getHeight() - _bitmap.getHeight()) / 2,
            _bitmap
        );
    }
}

class MainMenuDelegate extends WatchUi.Menu2InputDelegate {

    // Held as a field so it is not collected while its response is in flight.
    private var _push as ProgressPush;
    private var _catalog as ProxyClient?;

    function initialize() {
        Menu2InputDelegate.initialize();
        _push = new ProgressPush();
        _catalog = null;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();

        if (id == $.CONTINUE_ITEM) {
            var bookId = Store.resumableBook();
            if (bookId == null) {
                Log.error("Menu: nothing to continue after all");
                return;
            }
            Log.info("Menu: continuing " + bookId);
            _push.syncThenPlay(bookId);
            return;
        }

        if (id == $.BOOKS_ITEM) {
            // An empty Menu2 has undefined behavior on the device.
            if (Store.localBooks().size() == 0) {
                Log.info("Menu: books, but there are none");
                WatchUi.pushView(
                    new MessageView(WatchUi.loadResource(Rez.Strings.nothingOnWatch) as String),
                    new BackDelegate(),
                    WatchUi.SLIDE_IMMEDIATE
                );
                return;
            }
            Log.info("Menu: books");
            WatchUi.pushView(new BookMenu(), new BookMenuDelegate(), WatchUi.SLIDE_IMMEDIATE);
            return;
        }

        if (id == $.SERVER_ITEM) {
            // The page whose subtitle is "Chosen on the server". Sync
            // configuration shows it; the watch never opens that mode.
            Log.info("Menu: playlist on the server");
            if (Store.playlistRows().size() > 0) {
                SyncConfigView.openStored();
                refreshCatalog();
                return;
            }
            WatchUi.pushView(new PlaylistFetchView(), new BackDelegate(), WatchUi.SLIDE_IMMEDIATE);
            return;
        }

        if (id == $.PROGRESS_ITEM) {
            Log.info("Menu: syncing progress over the phone");
            _push.start();
            return;
        }

        if (id == $.SETTINGS_ITEM) {
            Log.info("Menu: settings");
            var menu = new SettingsMenu();
            WatchUi.pushView(menu, new SettingsMenuDelegate(menu), WatchUi.SLIDE_IMMEDIATE);
            return;
        }

        if (id == $.INFO_ITEM) {
            Log.info("Menu: info");
            WatchUi.pushView(new InfoView(), new BackDelegate(), WatchUi.SLIDE_IMMEDIATE);
            return;
        }

        // The ticket must come first: the app restarts in sync mode and
        // isSyncNeeded() only sees the stamp. startSync2 is used because it
        // shows a message on the sync screen.
        Log.info("Menu: startSync2");
        Store.requestSync();
        Communications.startSync2({
            :message => WatchUi.loadResource(Rez.Strings.AppName) as String
        });
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }

    //! Updates the stored playlist while the page already on screen stays put.
    private function refreshCatalog() as Void {
        if (_catalog == null) {
            _catalog = new ProxyClient();
        }
        var catalog = _catalog;
        if (catalog == null || !catalog.isConfigured()) {
            return;
        }
        catalog.playlist(method(:onCatalog));
    }

    function onCatalog(code as Number, data as Dictionary or String or Null) as Void {
        if (code != 200 || !(data instanceof Dictionary)) {
            return;
        }
        var books = data["books"];
        if (!(books instanceof Array) || books.size() == 0) {
            return;
        }
        Store.rememberPlaylist(books as Array);
    }
}

class ResetConfirmationDelegate extends WatchUi.ConfirmationDelegate {

    function initialize() {
        ConfirmationDelegate.initialize();
    }

    function onResponse(response as WatchUi.Confirm) as Boolean {
        if (response != WatchUi.CONFIRM_YES) {
            Log.info("Menu: reset cancelled");
            return false;
        }
        Log.info("Menu: resetting");
        Store.reset();
        Log.info("Menu: reset done, ending app");
        System.exit();
        return true;
    }
}
