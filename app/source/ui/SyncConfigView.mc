import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Zeigt, was laut Playlist auf die Uhr gehört und wie weit es ist.
//!
//! Ausgewählt wird nicht mehr hier, sondern in Audiobookshelf: die Playlist ist
//! die Sollvorgabe. Diese Ansicht beantwortet nur die Frage, warum ein Buch
//! noch nicht auf der Uhr ist.
class SyncConfigView extends WatchUi.View {

    private var _client as ProxyClient;
    private var _menuShown as Boolean;

    function initialize() {
        View.initialize();
        _client = new ProxyClient();
        _menuShown = false;
    }

    function onShow() as Void {
        if (_menuShown) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        if (!_client.isConfigured()) {
            showMessage(Rez.Strings.notConfigured);
            return;
        }
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
        if (code == 409) {
            showMessage(Rez.Strings.syncNoPlaylist);
            return;
        }
        if (code == 401 || code == 403) {
            showMessage(Rez.Strings.notConfigured);
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
        _menuShown = true;
        WatchUi.pushView(menu, new SyncConfigDelegate(), WatchUi.SLIDE_IMMEDIATE);
    }

    //! Zustand im Klartext — der Nutzer soll nicht raten, warum ein Buch fehlt.
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

//! Die Liste ist reine Anzeige — es gibt nichts auszuwählen.
class SyncConfigDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}
