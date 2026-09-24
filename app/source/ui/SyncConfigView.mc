import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Shows what belongs on the watch according to the playlist and how far along it is.
//!
//! Selection no longer happens here but in Audiobookshelf: the playlist is the
//! target. This view only answers the question of why a book is not on the
//! watch yet.
class SyncConfigView extends WatchUi.View {

    private var _client as ProxyClient;
    private var _menuShown as Boolean;

    function initialize() {
        View.initialize();
        _client = new ProxyClient();
        _menuShown = false;
    }

    function onShow() as Void {
        // The way BACK out of here is the system's "Synchronize?" prompt, and
        // that prompt is a sync trigger like any other: without a fresh ticket
        // isSyncNeeded() answers no, and no freezes the sync screen at 0 % with
        // onStartSync() never called. Stamped on every show — the second one is
        // the view being dismissed on the way to that prompt — so the stamp is
        // seconds old when the prompt arrives, however long the browsing took.
        // Browsing without confirming merely leaves a ticket that expires in
        // two minutes.
        Store.requestSync();
        if (_menuShown) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        Idle.poke();
        if (!_client.isConfigured()) {
            showSettings();
            return;
        }
        Log.info("Config: fetching playlist");
        _client.playlist(method(:onPlaylist));
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        dc.drawText(
            dc.getWidth() / 2,
            dc.getHeight() / 2,
            Graphics.FONT_SMALL,
            WatchUi.loadResource(Rez.Strings.loading) as String,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    function onPlaylist(code as Number, data as Dictionary or String or Null) as Void {
        Log.response("Config: playlist", code);
        if (code == 409) {
            showMessage(Rez.Strings.syncNoPlaylist);
            return;
        }
        if (code == 401 || code == 403) {
            showSettings();
            return;
        }
        if (code != 200 || !(data instanceof Dictionary)) {
            WatchUi.switchToView(new MessageView("HTTP " + code.toString()), null, WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        var books = data["books"];
        if (!(books instanceof Array) || books.size() == 0) {
            showMessage(Rez.Strings.playlistEmpty);
            return;
        }

        var title = stringOr(data["playlist"], "");
        var menu = new WatchUi.Menu2({ :title => title.length() > 0 ? title : Rez.Strings.menuSyncTitle });
        for (var i = 0; i < books.size(); ++i) {
            var book = books[i];
            if (!(book instanceof Dictionary)) {
                continue;
            }
            var id = book["id"];
            menu.addItem(
                new WatchUi.MenuItem(
                    stringOr(book["title"], stringOr(id, "?")),
                    statusLine(book),
                    id,
                    null
                )
            );
        }
        // The same row as in the playback configuration, so the progress can be
        // synced without opening the player first.
        menu.addItem(
            new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.sendProgress) as String,
                ProgressPush.rowSubtitle(),
                $.PROGRESS_ITEM,
                null
            )
        );

        _menuShown = true;
        WatchUi.pushView(menu, new SyncConfigDelegate(), WatchUi.SLIDE_IMMEDIATE);
    }

    //! State in plain text — the user should not have to guess why a book is missing.
    private function statusLine(book as Dictionary) as String {
        var status = book["status"];
        if (!(status instanceof String)) {
            return "";
        }
        if (status.equals("ready")) {
            var local = (book["id"] instanceof String) && Store.localTracks(book["id"] as String).size() > 0;
            if (local) {
                return WatchUi.loadResource(Rez.Strings.statusReady) as String;
            }
            return WatchUi.loadResource(Rez.Strings.statusWaitingForSync) as String;
        }
        if (status.equals("preparing")) {
            var percent = book["percent"];
            var text = WatchUi.loadResource(Rez.Strings.statusPreparing) as String;
            if (percent instanceof Number) {
                return text + " " + percent.toString() + " %";
            }
            return text;
        }
        if (status.equals("error")) {
            return stringOr(book["error"], WatchUi.loadResource(Rez.Strings.statusError) as String);
        }
        return WatchUi.loadResource(Rez.Strings.statusPending) as String;
    }

    //! Nothing to show without a working connection — so the place to fix it.
    //! BACK out of it comes through onShow() again and leaves, like the list.
    private function showSettings() as Void {
        Log.info("Config: not configured, opening settings");
        _menuShown = true;
        WatchUi.pushView(new SettingsMenu(), new SettingsMenuDelegate(), WatchUi.SLIDE_IMMEDIATE);
    }

    private function showMessage(resource as Lang.ResourceId) as Void {
        WatchUi.switchToView(
            new MessageView(WatchUi.loadResource(resource) as String),
            null,
            WatchUi.SLIDE_IMMEDIATE
        );
    }

    static function stringOr(value as Object?, fallback as String) as String {
        if (value instanceof String && value.length() > 0) {
            return value;
        }
        return fallback;
    }
}

//! The book list is display only; the row below it is not.
class SyncConfigDelegate extends WatchUi.Menu2InputDelegate {

    //! Held rather than made on demand: the push outlives the press, and a
    //! local one could be collected while its response is still in flight.
    private var _push as ProgressPush;

    function initialize() {
        Menu2InputDelegate.initialize();
        _push = new ProgressPush();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        Idle.poke();
        // The books are display only: what is on the watch is decided by the
        // playlist. Only the send-progress row does anything here.
        if (item.getId() == $.PROGRESS_ITEM) {
            Log.info("Config: syncing progress over the phone");
            _push.start();
        }
    }

    function onBack() as Void {
        Log.debugCode("Config: back, playlist state", Store.desired().size());
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}
