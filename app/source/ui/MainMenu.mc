import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.WatchUi;

//! Identifiers of the rows. Symbols throughout, so that none of them can ever
//! collide with a book ID — those are always strings.
const CONTINUE_ITEM = :continuePlayback;
const BOOKS_ITEM = :books;
const SYNC_ITEM = :syncNow;
const RESET_ITEM = :resetAll;
const INFO_ITEM = :info;

//! What the app opens on.
//!
//! The order is the order of how often a row is wanted. Carrying on with the
//! book that was playing is nearly always the reason the app was opened at all,
//! so it is one press and it is first. Everything that reaches for the network
//! or throws things away sits below the books, out of the way of a thumb
//! scrolling for something to listen to.
class MainMenu extends WatchUi.Menu2 {

    //! What the rows were built from, so a return to the menu can tell whether
    //! they still say the truth.
    private var _state as String;

    function initialize() {
        Menu2.initialize({ :title => Rez.Strings.AppName });
        _state = "";
        build();
    }

    //! Every return to the menu checks the store again.
    //!
    //! The rows were once built only here, and what they report is changed
    //! elsewhere — a Wi-Fi sync, a progress sync, the player. Coming back from
    //! the sync to the old book count is how the menu came to be out of date.
    //! Unchanged is the common case, back from the book list or the info
    //! screen, and there a rebuild would only throw the cursor to the top.
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

    //! Everything the rows say, in one comparable string.
    private static function state() as String {
        var resumable = Store.resumableBook();
        return ((resumable == null) ? "" : resumable)
            + "|" + Store.localBooks().size().toString()
            + "|" + ProgressPush.pending().toString()
            + "|" + (Media.getCacheStatistics().size / 1048576).toString();
    }

    private function build() as Void {
        _state = state();

        // Only when there is something to carry on with. A row that explains
        // why it cannot do anything is worse here than no row: this is the
        // first thing on screen, and it should be the thing that plays.
        var resumable = Store.resumableBook();
        if (resumable != null) {
            addItem(row(
                Rez.Strings.menuContinue, Store.bookInfo(resumable)[0],
                $.CONTINUE_ITEM, Rez.Drawables.IconContinue
            ));
        }

        var books = Store.localBooks();
        Log.debugCode("Menu: playable", books.size());
        addItem(row(
            Rez.Strings.menuBooks, booksSubtitle(books.size()),
            $.BOOKS_ITEM, Rez.Drawables.IconBooks
        ));

        // The small sibling of the sync: positions both ways over the phone
        // connection, without sync mode and so without Wi-Fi. The row says how
        // many are waiting to go out, and nothing when none are — there may
        // still be something to learn from the server.
        addItem(row(
            Rez.Strings.sendProgress, ProgressPush.rowSubtitle(),
            $.PROGRESS_ITEM, Rez.Drawables.IconSync
        ));

        // The system leads into this view, not into the sync configuration —
        // without this entry there is no discoverable way on the watch to start
        // a sync by hand, and since isSyncNeeded() says no, by hand is the only
        // way one ever starts.
        addItem(row(
            Rez.Strings.menuSync, null,
            $.SYNC_ITEM, Rez.Drawables.IconSync
        ));

        // The way out of a stuck state: orphaned segments in the media cache
        // and listening progress that points at nothing any more cannot be
        // repaired by hand. The subtitle shows what is at stake.
        var stats = Media.getCacheStatistics();
        addItem(row(
            Rez.Strings.resetAll, (stats.size / 1048576).toString() + " MB",
            $.RESET_ITEM, Rez.Drawables.IconReset
        ));

        // With an icon like every other row, so the labels line up.
        addItem(row(
            Rez.Strings.menuInfo, null,
            $.INFO_ITEM, Rez.Drawables.IconInfo
        ));
    }

    //! A row with its icon on the left, the way the system's own menus have
    //! them.
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

    //! An empty watch is the state that needs explaining; a full one only needs
    //! counting.
    private static function booksSubtitle(count as Number) as String {
        if (count == 0) {
            return WatchUi.loadResource(Rez.Strings.nothingOnWatch) as String;
        }
        return count.toString() + " " + (WatchUi.loadResource(Rez.Strings.booksCount) as String);
    }
}

//! A row icon the menu can draw.
//!
//! IconMenuItem is documented to take a bitmap, but handed a plain
//! BitmapResource the app crashed on the fēnix with "Symbol Not Found" and an
//! empty stack, and no row showed an icon. Garmin's Menu2Sample hands over a
//! Drawable, and so does this: the menu gives it a dc the size of the icon
//! slot, and the bitmap is centred in it — 40 x 56 on the fēnix, 65 x 96 on
//! the vívoactive 5.
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

    //! Held rather than made on demand: the push outlives the press, and a
    //! local one could be collected while its response is still in flight.
    private var _push as ProgressPush;

    function initialize() {
        Menu2InputDelegate.initialize();
        _push = new ProgressPush();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();

        if (id == $.CONTINUE_ITEM) {
            var bookId = Store.resumableBook();
            if (bookId == null) {
                // The row was drawn from the same answer, so this cannot
                // normally happen — but the store is written by other app
                // instances and the menu is older than the press.
                Log.error("Menu: nothing to continue after all");
                return;
            }
            // The same path as the Resume row in the chapter menu: agree with
            // the server first, and play whatever happens.
            Log.info("Menu: continuing " + bookId);
            _push.syncThenPlay(bookId);
            return;
        }

        if (id == $.BOOKS_ITEM) {
            // An empty Menu2 has nothing to put the cursor on, and what it does
            // then is the device's business rather than ours. The row already
            // says the watch is empty; pressing it should repeat that, not
            // gamble.
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

        if (id == $.PROGRESS_ITEM) {
            Log.info("Menu: syncing progress over the phone");
            _push.start();
            return;
        }

        if (id == $.RESET_ITEM) {
            Log.info("Menu: asking about reset");
            WatchUi.pushView(
                new WatchUi.Confirmation(WatchUi.loadResource(Rez.Strings.resetConfirm) as String),
                new ResetConfirmationDelegate(),
                WatchUi.SLIDE_IMMEDIATE
            );
            return;
        }

        if (id == $.INFO_ITEM) {
            Log.info("Menu: info");
            WatchUi.pushView(new InfoView(), new BackDelegate(), WatchUi.SLIDE_IMMEDIATE);
            return;
        }

        // The ticket comes first: startSync() ends the app and restarts it in
        // sync mode, and the stamp is the only thing isSyncNeeded() can still
        // see after that restart. Without it the answer there is no, and no
        // means the sync screen sits at 0 % with onStartSync() never called.
        // startSync2 rather than startSync: only this one hands the sync screen
        // a message, and without one the centre of that screen stays blank.
        Log.info("Menu: startSync2");
        Store.requestSync();
        Communications.startSync2({
            :message => WatchUi.loadResource(Rez.Strings.AppName) as String
        });
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}

//! The way back to zero.
//!
//! After the deletion the menu would still hold the old book list, and reaching
//! for it would lead into a state that no longer exists. Ending the app is the
//! only exit that leaves nothing stale behind — the next launch builds it all
//! up again, and the sync can then be started by hand.
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
