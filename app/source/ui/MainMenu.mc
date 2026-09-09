import Toybox.Communications;
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

    function initialize() {
        Menu2.initialize({ :title => Rez.Strings.AppName });

        // Only when there is something to carry on with. A row that explains
        // why it cannot do anything is worse here than no row: this is the
        // first thing on screen, and it should be the thing that plays.
        var resumable = Store.resumableBook();
        if (resumable != null) {
            addItem(
                new WatchUi.MenuItem(
                    WatchUi.loadResource(Rez.Strings.menuContinue) as String,
                    Store.bookInfo(resumable)[0],
                    $.CONTINUE_ITEM,
                    null
                )
            );
        }

        var books = Store.localBooks();
        addItem(
            new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.menuBooks) as String,
                booksSubtitle(books.size()),
                $.BOOKS_ITEM,
                null
            )
        );

        // The small sibling of the sync: the positions go out over the phone
        // connection, without sync mode and so without Wi-Fi. When there is
        // nothing buffered the row says so rather than making it a press to
        // find out.
        var pending = ProgressPush.pending();
        addItem(
            new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.sendProgress) as String,
                (pending == 0)
                    ? WatchUi.loadResource(Rez.Strings.syncNothingToDo) as String
                    : pending.toString() + " " + (WatchUi.loadResource(Rez.Strings.progressPending) as String),
                $.PROGRESS_ITEM,
                null
            )
        );

        // The system leads into this view, not into the sync configuration —
        // without this entry there is no discoverable way on the watch to start
        // a sync by hand, and since isSyncNeeded() says no, by hand is the only
        // way one ever starts.
        addItem(
            new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.menuSync) as String,
                null,
                $.SYNC_ITEM,
                null
            )
        );

        // The way out of a stuck state: orphaned segments in the media cache
        // and listening progress that points at nothing any more cannot be
        // repaired by hand. The subtitle shows what is at stake.
        var stats = Media.getCacheStatistics();
        addItem(
            new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.resetAll) as String,
                (stats.size / 1048576).toString() + " MB",
                $.RESET_ITEM,
                null
            )
        );

        addItem(
            new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.menuInfo) as String,
                null,
                $.INFO_ITEM,
                null
            )
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
            Log.info("Menu: sending progress over the phone");
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
        Log.info("Menu: startSync");
        Store.requestSync();
        Communications.startSync();
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
