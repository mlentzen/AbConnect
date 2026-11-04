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

        var titles = [] as Array<String>;
        var statuses = [] as Array<String>;
        for (var i = 0; i < books.size(); ++i) {
            var book = books[i];
            if (!(book instanceof Dictionary)) {
                continue;
            }
            var id = book["id"];
            titles.add(stringOr(book["title"], stringOr(id, "?")));
            statuses.add(statusLine(book));
        }
        if (titles.size() == 0) {
            showMessage(Rez.Strings.playlistEmpty);
            return;
        }

        var title = stringOr(data["playlist"], "");
        if (title.length() == 0) {
            title = WatchUi.loadResource(Rez.Strings.menuSyncTitle) as String;
        }
        Log.debugCode("Config: playlist status rows", titles.size());
        var status = new PlaylistStatusView(title, titles, statuses);
        _statusShown = true;
        WatchUi.pushView(status, new PlaylistStatusDelegate(status), WatchUi.SLIDE_IMMEDIATE);
    }

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

//! Titles and statuses of the server playlist, scrolled as a page rather than
//! a menu. Up and down move the window; nothing on the page can be chosen.
class PlaylistStatusView extends WatchUi.View {

    private var _title as String;
    private var _titles as Array<String>;
    private var _statuses as Array<String>;
    private var _offset as Number;
    //! How many books fit under the heading. Known after the first draw.
    private var _window as Number;

    function initialize(title as String, titles as Array<String>, statuses as Array<String>) {
        View.initialize();
        _title = title;
        _titles = titles;
        _statuses = statuses;
        _offset = 0;
        _window = titles.size();
        if (_window < 1) {
            _window = 1;
        }
    }

    function scroll(delta as Number) as Void {
        var next = _offset + delta;
        if (next < 0) {
            next = 0;
        }
        var limit = _titles.size() - _window;
        if (limit < 0) {
            limit = 0;
        }
        if (next > limit) {
            next = limit;
        }
        if (next == _offset) {
            return;
        }
        _offset = next;
        WatchUi.requestUpdate();
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

        var y = listTop;
        for (var i = 0; i < window; ++i) {
            var index = _offset + i;
            var inset = sideInset(dc, y + bodyH);
            var rowWidth = width - inset * 2;
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
}
