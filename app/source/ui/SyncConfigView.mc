import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

//! Sync configuration shows the server playlist. The watch does not choose
//! books: the next sync reads the playlist again and downloads that set.
//!
//! Menu2 is a list of options, so a row here would look like a choice that
//! then does nothing. This is a status page. Back returns to the system's
//! "Synchronize?" prompt; the ticket for that prompt is stamped in onShow.
class SyncConfigView extends WatchUi.View {

    private var _client as ProxyClient;
    private var _statusShown as Boolean;

    function initialize() {
        View.initialize();
        _client = new ProxyClient();
        _statusShown = false;
    }

    function onShow() as Void {
        // BACK leads to the system's "Synchronize?" prompt, which needs a fresh
        // ticket for isSyncNeeded(). Stamped on every show so it is fresh then.
        Store.requestSync();
        if (_statusShown) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        if (!_client.isConfigured()) {
            showMessage(Rez.Strings.notConfigured);
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
        if (showReply(code, data, false)) {
            _statusShown = true;
        }
    }

    //! Shows what a playlist reply deserves: the playlist menu, or a message.
    //! True when the menu was opened. storedOnError falls back to the playlist
    //! of the last fetch when the proxy cannot be reached.
    static function showReply(
        code as Number, data as Dictionary or String or Null, storedOnError as Boolean
    ) as Boolean {
        // Dismissing a notification with Back cancels the request. The page
        // is already gone, and opening another one crashes.
        if (code == Communications.REQUEST_CANCELLED) {
            return false;
        }
        if (code == 409) {
            showMessage(Rez.Strings.syncNoPlaylist);
            return false;
        }
        if (code == 401 || code == 403) {
            showMessage(Rez.Strings.notConfigured);
            return false;
        }
        if (code != 200 || !(data instanceof Dictionary)) {
            if (storedOnError && openStored()) {
                return true;
            }
            WatchUi.switchToView(new MessageView(Errors.fromCode(code)), null, WatchUi.SLIDE_IMMEDIATE);
            return false;
        }
        var books = data["books"];
        if (!(books instanceof Array) || books.size() == 0) {
            showMessage(Rez.Strings.playlistEmpty);
            return false;
        }
        var title = stringOr(data["playlist"], "");
        if (title.length() == 0) {
            title = WatchUi.loadResource(Rez.Strings.menuSyncTitle) as String;
        }
        if (!openStatus(title, books as Array)) {
            showMessage(Rez.Strings.playlistEmpty);
            return false;
        }
        return true;
    }

    //! Builds the playlist menu and pushes it. False when there are no rows.
    static function openStatus(title as String, books as Array) as Boolean {
        Store.rememberPlaylist(books);
        if (Store.playlistRows().size() == 0) {
            return false;
        }
        var heading = title;
        if (heading.length() == 0) {
            heading = WatchUi.loadResource(Rez.Strings.syncFromServer) as String;
        }
        WatchUi.pushView(new PlaylistMenu(heading), new PlaylistMenuDelegate(), WatchUi.SLIDE_IMMEDIATE);
        return true;
    }

    //! Last fetched playlist, for when the phone is not reachable.
    static function openStored() as Boolean {
        if (Store.playlistRows().size() == 0) {
            return false;
        }
        var title = WatchUi.loadResource(Rez.Strings.syncFromServer) as String;
        WatchUi.pushView(new PlaylistMenu(title), new PlaylistMenuDelegate(), WatchUi.SLIDE_IMMEDIATE);
        return true;
    }

    static function statusLine(book as Dictionary) as String {
        var status = book["status"];
        if (!(status instanceof String)) {
            return "";
        }
        if (status.equals("ready")) {
            var hinted = 0;
            if (book["segments"] instanceof Number) {
                hinted = book["segments"] as Number;
            }
            var id = book["id"];
            if (id instanceof String && Store.onWatch(id as String, hinted)) {
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

    static function showMessage(resource as Lang.ResourceId) as Void {
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

//! One row per book on the server playlist. The label is the title, the
//! subtitle is the sync status. A book already on the watch opens its chapters.
class PlaylistMenu extends WatchUi.Menu2 {

    function initialize(title as String) {
        Menu2.initialize({ :title => title });
        var rows = Store.playlistRows();
        for (var i = 0; i < rows.size(); ++i) {
            var entry = Store.playlistEntry(rows[i]);
            if (entry[0].length() == 0) {
                continue;
            }
            var book = {
                "id" => entry[0],
                "status" => entry[1],
                "title" => entry[3]
            } as Dictionary;
            if (entry[2].length() > 0) {
                var percent = entry[2].toNumber();
                if (percent != null) {
                    book["percent"] = percent;
                }
            }
            var label = entry[3];
            if (label.length() == 0) {
                label = entry[0];
            }
            addItem(new WatchUi.MenuItem(
                MenuText.label(label, entry[0]),
                MenuText.sublabel(SyncConfigView.statusLine(book)),
                entry[0],
                null
            ));
        }
    }
}

class PlaylistMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof String)) {
            return;
        }
        var bookId = id as String;
        if (Store.localTracks(bookId).size() == 0) {
            return;
        }
        Log.info("Playlist: open " + bookId);
        WatchUi.pushView(new ChapterMenu(bookId), new ChapterMenuDelegate(bookId), WatchUi.SLIDE_IMMEDIATE);
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}

//! Fetches the playlist for the server menu. Does not stamp a sync ticket.
class PlaylistFetchView extends WatchUi.View {

    private var _client as ProxyClient;
    private var _started as Boolean;
    private var _opened as Boolean;

    function initialize() {
        View.initialize();
        _client = new ProxyClient();
        _started = false;
        _opened = false;
    }

    function onShow() as Void {
        if (_opened) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        if (_started) {
            return;
        }
        _started = true;
        if (!_client.isConfigured()) {
            WatchUi.switchToView(
                new MessageView(WatchUi.loadResource(Rez.Strings.notConfigured) as String),
                null,
                WatchUi.SLIDE_IMMEDIATE
            );
            return;
        }
        Log.info("Playlist: fetching");
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
        Log.response("Playlist: fetched", code);
        if (SyncConfigView.showReply(code, data, true)) {
            _opened = true;
        }
    }
}
