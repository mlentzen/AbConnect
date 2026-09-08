import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.WatchUi;

//! Identifier of the sync entry. A symbol, so it can never collide with a book
//! ID — those are always strings.
const SYNC_ITEM = :syncNow;
const RESET_ITEM = :resetAll;

//! Selection of which book the player plays.
class PlaybackConfigView extends WatchUi.View {

    private var _menuShown as Boolean;

    function initialize() {
        View.initialize();
        _menuShown = false;
    }

    function onShow() as Void {
        Log.line("Config: onShow");
        if (_menuShown) {
            Log.line("Config: popView");
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        var books = Store.localBooks();
        Log.code("Config: playable", books.size());

        Log.line("Config: building menu");
        var menu = new WatchUi.Menu2({ :title => Rez.Strings.menuPlaybackTitle });
        for (var i = 0; i < books.size(); ++i) {
            var info = Store.bookInfo(books[i]);
            menu.addItem(new WatchUi.MenuItem(info[0], info[1], books[i], null));
        }

        // The system leads into this view, not into the sync configuration —
        // without this entry there is no discoverable way on the watch to start
        // a sync by hand. As long as nothing is downloaded it is the only thing
        // the menu has to offer, and it carries the explanation along as its
        // subtitle.
        var hint = null as String?;
        if (books.size() == 0) {
            hint = WatchUi.loadResource(Rez.Strings.nothingOnWatch) as String;
        }
        menu.addItem(
            new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.syncNow) as String,
                hint,
                $.SYNC_ITEM,
                null
            )
        );

        // The way out of a stuck state: orphaned segments in the media cache
        // and listening progress that points at nothing any more cannot be
        // repaired by hand. The subtitle shows what is at stake.
        var stats = Media.getCacheStatistics();
        menu.addItem(
            new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.resetAll) as String,
                (stats.size / 1048576).toString() + " MB",
                $.RESET_ITEM,
                null
            )
        );

        _menuShown = true;
        Log.line("Config: pushView");
        WatchUi.pushView(menu, new PlaybackConfigDelegate(), WatchUi.SLIDE_IMMEDIATE);
        Log.line("Config: pushView returned");
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Log.line("Config: onUpdate");
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
            // A book opens its chapters instead of starting straight away. The
            // chapter marked "Resume" carries on exactly where the listening
            // stopped, so the extra press buys the way into the rest of the
            // book without costing the way back into the middle of it.
            Log.line("Config: chapters of " + id);
            WatchUi.pushView(
                new ChapterMenu(id),
                new ChapterMenuDelegate(id),
                WatchUi.SLIDE_IMMEDIATE
            );
            return;
        }
        if (id == $.RESET_ITEM) {
            Log.line("Config: asking about reset");
            WatchUi.pushView(
                new WatchUi.Confirmation(WatchUi.loadResource(Rez.Strings.resetConfirm) as String),
                new ResetConfirmationDelegate(),
                WatchUi.SLIDE_IMMEDIATE
            );
            return;
        }
        // startSync() ends the app and restarts it in sync mode; whatever stood
        // here after it would never run.
        Log.line("Config: startSync");
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
            Log.line("Config: reset cancelled");
            return false;
        }
        Log.line("Config: resetting");
        Store.reset();
        Log.line("Config: reset done, ending app");
        System.exit();
        return true;
    }
}
