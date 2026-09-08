import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Buchauswahl.
//!
//! Das Ankreuzen stößt beim Proxy sofort die Vorbereitung an, statt damit bis
//! zum Sync zu warten: bis die Uhr am Ladegerät hängt, ist das Buch dann in
//! aller Regel geschnitten.
class SyncConfigView extends WatchUi.View {

    private const PER_PAGE = 40;

    private var _client as ProxyClient;
    private var _menuShown as Boolean;

    function initialize() {
        View.initialize();
        _client = new ProxyClient();
        _menuShown = false;
    }

    function onShow() as Void {
        if (_menuShown) {
            // Rückkehr aus dem Menü: die Ansicht hat ihren Zweck erfüllt.
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        if (!_client.isConfigured()) {
            WatchUi.switchToView(
                new MessageView(WatchUi.loadResource(Rez.Strings.notConfigured) as String),
                null,
                WatchUi.SLIDE_IMMEDIATE
            );
            return;
        }
        Log.line("Konfig: hole Bücher");
        _client.books(1, PER_PAGE, method(:onBooks));
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

    function onBooks(code as Number, data as Dictionary or String or Null) as Void {
        Log.code("Konfig: books", code);
        if (code != 200 || !(data instanceof Dictionary)) {
            WatchUi.switchToView(new MessageView(errorText(code)), null, WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        var books = data["books"];
        if (!(books instanceof Array) || books.size() == 0) {
            WatchUi.switchToView(
                new MessageView(WatchUi.loadResource(Rez.Strings.noBooks) as String),
                null,
                WatchUi.SLIDE_IMMEDIATE
            );
            return;
        }
        showMenu(books as Array<Dictionary>);
    }

    private function showMenu(books as Array<Dictionary>) as Void {
        var menu = new WatchUi.CheckboxMenu({ :title => Rez.Strings.menuSyncTitle });
        for (var i = 0; i < books.size(); ++i) {
            var book = books[i];
            var id = book["id"];
            if (!(id instanceof String)) {
                continue;
            }
            menu.addItem(
                new WatchUi.CheckboxMenuItem(
                    stringOr(book["title"], id),
                    subLabel(book),
                    id,
                    Store.isSelected(id),
                    null
                )
            );
        }
        _menuShown = true;
        WatchUi.pushView(menu, new SyncConfigDelegate(_client, books), WatchUi.SLIDE_IMMEDIATE);
    }

    //! Autor plus Zustand — der Nutzer soll sehen, was noch vorbereitet wird.
    private function subLabel(book as Dictionary) as String {
        var author = stringOr(book["author"], "");
        var status = book["status"];
        var note = "";
        if (status instanceof String) {
            if (status.equals("ready")) {
                note = WatchUi.loadResource(Rez.Strings.statusReady) as String;
            } else if (status.equals("preparing")) {
                note = WatchUi.loadResource(Rez.Strings.statusPreparing) as String;
            } else if (status.equals("error")) {
                note = WatchUi.loadResource(Rez.Strings.statusError) as String;
            }
        }
        if (note.length() == 0) {
            return author;
        }
        if (author.length() == 0) {
            return note;
        }
        return author + " · " + note;
    }

    private function errorText(code as Number) as String {
        if (code == 401 || code == 403) {
            return WatchUi.loadResource(Rez.Strings.notConfigured) as String;
        }
        return "HTTP " + code.toString();
    }

    static function stringOr(value as Object?, fallback as String) as String {
        if (value instanceof String && value.length() > 0) {
            return value;
        }
        return fallback;
    }
}

//! Nimmt die Häkchen entgegen und stößt das Vorbereiten an.
class SyncConfigDelegate extends WatchUi.Menu2InputDelegate {

    private var _client as ProxyClient;

    function initialize(client as ProxyClient, books as Array<Dictionary>) {
        Menu2InputDelegate.initialize();
        _client = client;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof String)) {
            return;
        }
        var checkbox = item as WatchUi.CheckboxMenuItem;
        if (checkbox.isChecked()) {
            Log.line("Konfig: gewählt " + id);
            Store.select(id);
            // Sofort vorbereiten lassen; das Ergebnis interessiert hier nicht,
            // der Sync fragt später ohnehin den Status ab.
            _client.prepare(id, method(:onIgnored));
        } else {
            Log.line("Konfig: abgewählt " + id);
            Store.deselect(id);
            _client.release(id, method(:onIgnored));
        }
    }

    //! Das Ergebnis ändert hier nichts mehr — für die Fehlersuche zählt aber,
    //! ob der Proxy das Vorbereiten überhaupt angenommen hat.
    function onIgnored(code as Number, data as Dictionary or String or Null) as Void {
        Log.code("Konfig: prepare/release", code);
    }

    function onBack() as Void {
        Log.line("Konfig: zurück, Auswahl=" + Store.selection().size().toString());
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}
