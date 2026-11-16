import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class SyncConfigView extends WatchUi.View {

    private var _client as ProxyClient;
    private var _statusShown as Boolean;

    function initialize() {
        View.initialize();
        _client = new ProxyClient();
        _statusShown = false;
    }

    function onShow() as Void {
        Store.requestSync();
        if (_statusShown) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        if (!_client.isConfigured()) {
            MessageView.show(Util.text(_client.setupProblem(Rez.Strings.notConfigured)));
            return;
        }
        Log.info("Config: fetching playlist");
        _client.playlist(method(:onPlaylist));
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        MessageView.drawCentered(dc, Util.text(Rez.Strings.loading));
    }

    function onPlaylist(code as Number, data as Dictionary or String or Null) as Void {
        Log.response("Config: playlist", code);
        if (showReply(code, data, false)) {
            _statusShown = true;
        }
    }

    static function showReply(
        code as Number, data as Dictionary or String or Null, storedOnError as Boolean
    ) as Boolean {
        if (code == Communications.REQUEST_CANCELLED) {
            return false;
        }
        if (code == 409) {
            MessageView.show(Util.text(Rez.Strings.syncNoPlaylist));
            return false;
        }
        if (code == 401 || code == 403) {
            MessageView.show(Util.text(Rez.Strings.notConfigured));
            return false;
        }
        if (code != 200 || !(data instanceof Dictionary)) {
            if (storedOnError && openStored(null)) {
                return true;
            }
            MessageView.show(Errors.fromCode(code));
            return false;
        }
        var books = data["books"];
        if (books instanceof Array && books.size() > 0) {
            Store.rememberPlaylist(books as Array);
            var title = Util.stringOr(data["playlist"], Util.text(Rez.Strings.menuSyncTitle));
            if (openStored(title)) {
                return true;
            }
        }
        MessageView.show(Util.text(Rez.Strings.playlistEmpty));
        return false;
    }

    static function openStored(title as String?) as Boolean {
        if (Store.playlistRows().size() == 0) {
            return false;
        }
        var heading = Util.stringOr(title, Util.text(Rez.Strings.syncFromServer));
        WatchUi.pushView(new PlaylistMenu(heading), new PlaylistMenuDelegate(), WatchUi.SLIDE_IMMEDIATE);
        return true;
    }

    static function statusLine(book as Dictionary) as String {
        var status = book["status"];
        if (!(status instanceof String)) {
            return "";
        }
        if (status.equals("ready")) {
            var hinted = Util.numberOf(book["segments"]);
            var id = book["id"];
            if (id instanceof String && Store.onWatch(id, hinted)) {
                return Util.text(Rez.Strings.statusReady);
            }
            return Util.text(Rez.Strings.statusWaitingForSync);
        }
        if (status.equals("preparing")) {
            var percent = book["percent"];
            var text = Util.text(Rez.Strings.statusPreparing);
            return (percent instanceof Number) ? text + " " + percent.toString() + " %" : text;
        }
        if (status.equals("error")) {
            return Util.stringOr(book["error"], Util.text(Rez.Strings.statusError));
        }
        return Util.text(Rez.Strings.statusPending);
    }
}

class PlaylistMenu extends WatchUi.Menu2 {

    function initialize(title as String) {
        Menu2.initialize({ :title => title });
        var rows = Store.playlistRows();
        for (var i = 0; i < rows.size(); ++i) {
            var entry = Store.playlistEntry(rows[i]);
            var id = entry[0];
            if (id.length() == 0) {
                continue;
            }
            var book = { "id" => id, "status" => entry[1] } as Dictionary;
            var percent = entry[2].toNumber();
            if (percent != null) {
                book["percent"] = percent;
            }
            addItem(new WatchUi.MenuItem(
                MenuText.label(entry[3], id),
                MenuText.sublabel(SyncConfigView.statusLine(book)),
                id,
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
        var bookId = item.getId();
        if (!(bookId instanceof String) || !Store.hasTracks(bookId)) {
            return;
        }
        Log.info("Playlist: open " + bookId);
        WatchUi.pushView(new ChapterMenu(bookId), new ChapterMenuDelegate(bookId), WatchUi.SLIDE_IMMEDIATE);
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}

class PlaylistFetchView extends WatchUi.View {

    private var _client as ProxyClient;
    private var _started as Boolean;
    private var _opened as Boolean;
    private var _visible as Boolean;

    function initialize() {
        View.initialize();
        _client = new ProxyClient();
        _started = false;
        _opened = false;
        _visible = false;
    }

    function onHide() as Void {
        _visible = false;
    }

    function onShow() as Void {
        _visible = true;
        if (_opened) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        if (_started) {
            return;
        }
        _started = true;
        if (!_client.isConfigured()) {
            MessageView.show(Util.text(_client.setupProblem(Rez.Strings.notConfigured)));
            return;
        }
        Log.info("Playlist: fetching");
        _client.playlist(method(:onPlaylist));
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        MessageView.drawCentered(dc, Util.text(Rez.Strings.loading));
    }

    function onPlaylist(code as Number, data as Dictionary or String or Null) as Void {
        Log.response("Playlist: fetched", code);
        if (!_visible) {
            Log.info("Playlist: answer after the view was left");
            return;
        }
        if (SyncConfigView.showReply(code, data, true)) {
            _opened = true;
        }
    }
}
