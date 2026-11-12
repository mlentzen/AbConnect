import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.WatchUi;

const CONTINUE_ITEM = :continuePlayback;
const CHAPTERS_ITEM = :chapters;
const BOOKS_ITEM = :books;
const PROGRESS_ITEM = :sendProgress;
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

    function onShow() as Void {
        Menu2.onShow();
        if (state(Store.playlistCounts()).equals(_state)) {
            return;
        }
        Log.info("Menu: the store changed, rebuilding");
        while (deleteItem(0) == true) {
        }
        build();
        setFocus(0);
    }

    private static function state(counts as Array<Number>) as String {
        var resumable = Store.resumableBook();
        var chapter = "";
        if (resumable != null) {
            var position = Store.position(resumable);
            if (position != null) {
                chapter = position[0].toString();
            }
        }
        return ((resumable == null) ? "" : resumable)
            + "|" + counts[0].toString()
            + "|" + counts[1].toString()
            + "|" + chapter
            + "|" + ProgressPush.pending().toString()
            + "|" + (Media.getCacheStatistics().size / 1048576).toString()
            + "|" + syncLine();
    }

    private function build() as Void {
        var counts = Store.playlistCounts();
        _state = state(counts);

        var resumable = Store.resumableBook();
        if (resumable != null) {
            addItem(row(
                Rez.Strings.menuContinue, MenuText.sublabel(Store.bookInfo(resumable)[0]),
                $.CONTINUE_ITEM, Rez.Drawables.IconContinue
            ));
            var chapter = ChapterMenu.currentTitle(resumable);
            addItem(row(
                Rez.Strings.menuChapters, (chapter == null) ? null : MenuText.sublabel(chapter),
                $.CHAPTERS_ITEM, Rez.Drawables.IconBooks
            ));
        }

        var books = Store.localBooks();
        Log.debugCode("Menu: playable", books.size());
        addItem(row(Rez.Strings.menuBooks, localSubtitle(books.size()), $.BOOKS_ITEM, Rez.Drawables.IconBooks));
        addItem(row(Rez.Strings.sendProgress, ProgressPush.rowSubtitle(), $.PROGRESS_ITEM, Rez.Drawables.IconSync));
        addItem(row(Rez.Strings.menuSync, MenuText.sublabel(syncLine()), $.SYNC_ITEM, Rez.Drawables.IconSync));
        addItem(row(Rez.Strings.syncFromServer, serverSubtitle(counts), $.SERVER_ITEM, Rez.Drawables.IconSync));
        addItem(row(Rez.Strings.menuSettings, null, $.SETTINGS_ITEM, Rez.Drawables.IconSettings));
        addItem(row(Rez.Strings.menuInfo, null, $.INFO_ITEM, Rez.Drawables.IconInfo));
    }

    private static function row(
        label as Lang.ResourceId, subLabel as String?, id as Symbol, icon as Lang.ResourceId
    ) as WatchUi.IconMenuItem {
        return new WatchUi.IconMenuItem(Util.text(label), subLabel, id, new MenuIcon(icon), null);
    }

    private static function syncLine() as String {
        var result = Store.lastSyncResult();
        if (result == null) {
            return "";
        }
        var ago = Ago.since(result[0] as Number);
        if (result[1] == null) {
            return ago;
        }
        return Lang.format(Util.text(Rez.Strings.syncFailedAgo), [ago]);
    }

    private static function localSubtitle(count as Number) as String {
        if (count == 0) {
            return Util.text(Rez.Strings.nothingOnWatch);
        }
        return count.toString() + " " + Util.text(Rez.Strings.booksCount);
    }

    private static function serverSubtitle(counts as Array<Number>) as String? {
        if (counts[0] == 0) {
            return null;
        }
        if (counts[1] > 0) {
            return counts[1].toString() + " " + Util.text(Rez.Strings.progressPending);
        }
        return counts[0].toString() + " " + Util.text(Rez.Strings.booksCount);
    }
}

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
            continueBook();
        } else if (id == $.BOOKS_ITEM) {
            openBooks();
        } else if (id == $.CHAPTERS_ITEM) {
            openChapters();
        } else if (id == $.SERVER_ITEM) {
            openServerPlaylist();
        } else if (id == $.PROGRESS_ITEM) {
            Log.info("Menu: syncing progress over the phone");
            _push.start();
        } else if (id == $.SETTINGS_ITEM) {
            Log.info("Menu: settings");
            var menu = new SettingsMenu();
            WatchUi.pushView(menu, new SettingsMenuDelegate(menu), WatchUi.SLIDE_IMMEDIATE);
        } else if (id == $.INFO_ITEM) {
            Log.info("Menu: info");
            WatchUi.pushView(new InfoView(), new BackDelegate(), WatchUi.SLIDE_IMMEDIATE);
        } else if (id == $.SYNC_ITEM) {
            startSync();
        }
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }

    private function continueBook() as Void {
        var bookId = Store.resumableBook();
        if (bookId == null) {
            Log.error("Menu: nothing to continue after all");
            return;
        }
        Log.info("Menu: continuing " + bookId);
        _push.syncThenPlay(bookId);
    }

    private function openBooks() as Void {
        if (Store.localBooks().size() == 0) {
            Log.info("Menu: books, but there are none");
            WatchUi.pushView(
                new MessageView(Util.text(Rez.Strings.nothingOnWatch)), new BackDelegate(), WatchUi.SLIDE_IMMEDIATE
            );
            return;
        }
        Log.info("Menu: books");
        WatchUi.pushView(new BookMenu(), new BookMenuDelegate(), WatchUi.SLIDE_IMMEDIATE);
    }

    private function openChapters() as Void {
        var bookId = Store.resumableBook();
        if (bookId != null) {
            Log.info("Menu: chapters of " + bookId);
            WatchUi.pushView(new ChapterMenu(bookId), new ChapterMenuDelegate(bookId), WatchUi.SLIDE_IMMEDIATE);
        }
    }

    private function openServerPlaylist() as Void {
        Log.info("Menu: playlist on the server");
        if (SyncConfigView.openStored(null)) {
            refreshCatalog();
            return;
        }
        WatchUi.pushView(new PlaylistFetchView(), new BackDelegate(), WatchUi.SLIDE_IMMEDIATE);
    }

    private function startSync() as Void {
        Log.info("Menu: startSync2");
        Store.requestSync();
        Communications.startSync2({ :message => Util.text(Rez.Strings.AppName) });
    }

    private function refreshCatalog() as Void {
        var catalog = _catalog;
        if (catalog == null) {
            catalog = new ProxyClient();
            _catalog = catalog;
        }
        if (catalog.isConfigured()) {
            catalog.playlist(method(:onCatalog));
        }
    }

    function onCatalog(code as Number, data as Dictionary or String or Null) as Void {
        if (code != 200 || !(data instanceof Dictionary)) {
            return;
        }
        var books = data["books"];
        if (books instanceof Array && books.size() > 0) {
            Store.rememberPlaylist(books as Array);
        }
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
