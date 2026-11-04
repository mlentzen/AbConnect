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
        // Dismissing a notification with Back cancels the request. The page
        // is already gone, and opening another one crashes.
        if (code == Communications.REQUEST_CANCELLED) {
            return;
        }
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
        if (title.length() == 0) {
            title = WatchUi.loadResource(Rez.Strings.menuSyncTitle) as String;
        }
        if (!openStatus(title, books as Array)) {
            showMessage(Rez.Strings.playlistEmpty);
            return;
        }
        _statusShown = true;
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

//! Titles and statuses of the server playlist. Up and down move the selection.
//! Start opens a book that is already on the watch.
class PlaylistStatusView extends WatchUi.View {

    private var _title as String;
    private var _ids as Array<String>;
    private var _titles as Array<String>;
    private var _statuses as Array<String>;
    private var _offset as Number;
    private var _selected as Number;
    //! How many books fit under the heading. Known after the first draw.
    private var _window as Number;

    function initialize(
        title as String, titles as Array<String>, statuses as Array<String>, ids as Array<String>
    ) {
        View.initialize();
        _title = title;
        _ids = ids;
        _titles = titles;
        _statuses = statuses;
        _offset = 0;
        _selected = 0;
        _window = titles.size();
        if (_window < 1) {
            _window = 1;
        }
    }

    function scroll(delta as Number) as Void {
        if (_titles.size() == 0) {
            return;
        }
        var next = _selected + delta;
        if (next < 0) {
            next = 0;
        }
        if (next >= _titles.size()) {
            next = _titles.size() - 1;
        }
        if (next == _selected) {
            return;
        }
        _selected = next;
        reveal();
        WatchUi.requestUpdate();
    }

    function selectedId() as String? {
        if (_selected < 0 || _selected >= _ids.size()) {
            return null;
        }
        var id = _ids[_selected];
        if (id.length() == 0) {
            return null;
        }
        return id;
    }

    private function reveal() as Void {
        if (_selected < _offset) {
            _offset = _selected;
        }
        var last = _offset + _window - 1;
        if (_selected > last) {
            _offset = _selected - _window + 1;
        }
        if (_offset < 0) {
            _offset = 0;
        }
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();
        var titleFont = Graphics.FONT_TINY;
        var bodyFont = Graphics.FONT_XTINY;
        var titleH = dc.getFontHeight(titleFont);
        var bodyH = dc.getFontHeight(bodyFont);
        var bookH = bodyH * 2 + 6;
        var headerH = titleH + bodyH + 8;
        var centre = width / 2;

        var topLimit = (height * 0.12).toNumber();
        var bottomLimit = height - topLimit;
        var block = headerH + _titles.size() * bookH;
        var top = topLimit;
        if (block < bottomLimit - topLimit) {
            top = (height - block) / 2;
        }

        var titleWidth = width - sideInset(dc, top + titleH / 2) * 2;
        dc.drawText(
            centre, top, titleFont,
            fit(dc, titleFont, _title, titleWidth),
            Graphics.TEXT_JUSTIFY_CENTER
        );

        var hintY = top + titleH + 4;
        var hint = WatchUi.loadResource(Rez.Strings.syncFromServer) as String;
        var hintWidth = width - sideInset(dc, hintY + bodyH / 2) * 2;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            centre, hintY, bodyFont,
            fit(dc, bodyFont, hint, hintWidth),
            Graphics.TEXT_JUSTIFY_CENTER
        );

        var listTop = hintY + bodyH + 8;
        var listBottom = (block < bottomLimit - topLimit) ? (top + block) : bottomLimit;
        var window = (listBottom - listTop) / bookH;
        if (window < 1) {
            window = 1;
        }
        if (window > _titles.size()) {
            window = _titles.size();
        }
        _window = window;
        if (_offset > _titles.size() - window) {
            _offset = _titles.size() - window;
        }
        if (_offset < 0) {
            _offset = 0;
        }
        reveal();

        var y = listTop;
        for (var i = 0; i < window; ++i) {
            var index = _offset + i;
            var inset = sideInset(dc, y + bodyH);
            var rowWidth = width - inset * 2;
            if (index == _selected) {
                dc.setColor(Graphics.COLOR_DK_BLUE, Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(inset, y, rowWidth, bookH);
            }
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                centre, y, bodyFont,
                fit(dc, bodyFont, _titles[index], rowWidth),
                Graphics.TEXT_JUSTIFY_CENTER
            );
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                centre, y + bodyH, bodyFont,
                fit(dc, bodyFont, _statuses[index], rowWidth),
                Graphics.TEXT_JUSTIFY_CENTER
            );
            y += bookH;
        }

        if (_offset > 0) {
            dc.drawText(centre, listTop - bodyH / 2, bodyFont, "^", Graphics.TEXT_JUSTIFY_CENTER);
        }
        if (_offset + window < _titles.size()) {
            dc.drawText(centre, y, bodyFont, "v", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    //! Horizontal room inside the round face at this y.
    private function sideInset(dc as Graphics.Dc, y as Number) as Number {
        var radius = dc.getWidth() / 2 - 10;
        var dy = y - dc.getHeight() / 2;
        if (dy < 0) {
            dy = -dy;
        }
        if (dy >= radius) {
            return radius;
        }
        var reach = Math.sqrt((radius * radius - dy * dy).toFloat()).toNumber();
        var inset = dc.getWidth() / 2 - reach;
        if (inset < 8) {
            inset = 8;
        }
        return inset;
    }

    private function fit(
        dc as Graphics.Dc, font as Graphics.FontType, text as String, width as Number
    ) as String {
        if (width <= 0) {
            return "";
        }
        if (dc.getTextWidthInPixels(text, font) <= width) {
            return text;
        }
        var end = text.length();
        while (end > 0) {
            var cut = text.substring(0, end) + "...";
            if (dc.getTextWidthInPixels(cut, font) <= width) {
                return cut;
            }
            end -= 1;
        }
        return "";
    }
}

class PlaylistStatusDelegate extends WatchUi.BehaviorDelegate {

    private var _view as PlaylistStatusView;

    function initialize(view as PlaylistStatusView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onNext() as Boolean {
        _view.scroll(1);
        return true;
    }

    function onPrevious() as Boolean {
        _view.scroll(-1);
        return true;
    }

    function onNextPage() as Boolean {
        _view.scroll(1);
        return true;
    }

    function onPreviousPage() as Boolean {
        _view.scroll(-1);
        return true;
    }

    function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        var direction = swipeEvent.getDirection();
        if (direction == WatchUi.SWIPE_UP) {
            _view.scroll(1);
            return true;
        }
        if (direction == WatchUi.SWIPE_DOWN) {
            _view.scroll(-1);
            return true;
        }
        return false;
    }

    function onBack() as Boolean {
        Log.debugCode("Config: back, playlist state", Store.desired().size());
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }

    function onSelect() as Boolean {
        var id = _view.selectedId();
        if (id == null || Store.localTracks(id).size() == 0) {
            return true;
        }
        Log.info("Playlist: open " + id);
        WatchUi.pushView(new ChapterMenu(id), new ChapterMenuDelegate(id), WatchUi.SLIDE_IMMEDIATE);
        return true;
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
        if (code == Communications.REQUEST_CANCELLED) {
            return;
        }
        if (code == 409) {
            show(Rez.Strings.syncNoPlaylist);
            return;
        }
        if (code == 401 || code == 403) {
            show(Rez.Strings.notConfigured);
            return;
        }
        if (code != 200 || !(data instanceof Dictionary)) {
            if (SyncConfigView.openStored()) {
                _opened = true;
                return;
            }
            WatchUi.switchToView(new MessageView("HTTP " + code.toString()), null, WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        var books = data["books"];
        if (!(books instanceof Array) || books.size() == 0) {
            show(Rez.Strings.playlistEmpty);
            return;
        }
        var title = SyncConfigView.stringOr(data["playlist"], "");
        if (title.length() == 0) {
            title = WatchUi.loadResource(Rez.Strings.menuSyncTitle) as String;
        }
        if (!SyncConfigView.openStatus(title, books as Array)) {
            show(Rez.Strings.playlistEmpty);
            return;
        }
        _opened = true;
    }

    private function show(resource as Lang.ResourceId) as Void {
        WatchUi.switchToView(
            new MessageView(WatchUi.loadResource(resource) as String),
            null,
            WatchUi.SLIDE_IMMEDIATE
        );
    }
}
