import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! Pairing: the token is typed on the phone and collected here.
//!
//! The watch asks the proxy for a short code and shows it together with the
//! address of the pairing page. On the phone, that page takes the code and the
//! token; meanwhile the watch polls, and the poll that finds the token stores
//! it. A last /v1/status call then says whether the token actually works.
//!
//! The URL has to be known already — from the build, the phone settings or the
//! watch keyboard. See proxy/abconnect_proxy/pairing.py for the server half.
class PairView extends WatchUi.View {

    const POLL_MS = 3000;

    private var _client as ProxyClient;
    private var _timer as Timer.Timer?;
    private var _code as String?;
    //! What the screen says below the code, or instead of it once it is over.
    private var _status as String;
    private var _started as Boolean;
    private var _finished as Boolean;
    private var _awaiting as Boolean;
    private var _deadlineMs as Number;
    private var _holding as Boolean;

    function initialize() {
        View.initialize();
        _client = new ProxyClient();
        _timer = null;
        _code = null;
        _status = WatchUi.loadResource(Rez.Strings.loading) as String;
        _started = false;
        _finished = false;
        _awaiting = false;
        _deadlineMs = 0;
        _holding = false;
    }

    function onShow() as Void {
        Idle.poke();
        if (_started) {
            return;
        }
        _started = true;
        // Nobody touches the watch while typing on the phone.
        Idle.hold();
        _holding = true;
        _client.pairStart(method(:onStarted));
    }

    //! BACK or the end: no more polls, and the idle clock runs again.
    function onHide() as Void {
        stop();
    }

    function onStarted(code as Number, data as Dictionary or String or Null) as Void {
        Log.response("Pair: start", code);
        if (code != 200 || !(data instanceof Dictionary) || !(data["code"] instanceof String)) {
            end("HTTP " + code.toString());
            return;
        }
        _code = data["code"] as String;
        var expires = data["expires_in"];
        var seconds = (expires instanceof Number) ? expires : 600;
        _deadlineMs = System.getTimer() + seconds * 1000;
        _status = WatchUi.loadResource(Rez.Strings.pairWaiting) as String;
        try {
            var timer = new Timer.Timer();
            timer.start(method(:onTick), POLL_MS, true);
            _timer = timer;
        } catch (ex) {
            end(WatchUi.loadResource(Rez.Strings.statusError) as String);
            return;
        }
        WatchUi.requestUpdate();
    }

    function onTick() as Void {
        var code = _code;
        if (_finished || code == null || _awaiting) {
            return;
        }
        if (System.getTimer() - _deadlineMs > 0) {
            end(WatchUi.loadResource(Rez.Strings.pairExpired) as String);
            return;
        }
        _awaiting = true;
        _client.pairPoll(code, method(:onPolled));
    }

    function onPolled(code as Number, data as Dictionary or String or Null) as Void {
        _awaiting = false;
        if (_finished) {
            return;
        }
        if (code == 202) {
            return;
        }
        if (code == 404) {
            end(WatchUi.loadResource(Rez.Strings.pairExpired) as String);
            return;
        }
        if (code != 200) {
            // Radio hiccups and the like: the next tick tries again, until the
            // code runs out.
            Log.response("Pair: poll", code);
            return;
        }
        var token = (data instanceof Dictionary) ? data["token"] : null;
        if (!(token instanceof String) || token.length() == 0) {
            end(WatchUi.loadResource(Rez.Strings.statusError) as String);
            return;
        }
        Store.setConfigValue(Keys.CFG_TOKEN, token);
        Log.info("Pair: token received, checking it");
        stopTimer();
        _status = WatchUi.loadResource(Rez.Strings.loading) as String;
        _code = null;
        WatchUi.requestUpdate();
        // A fresh client: the one above was built before the token existed.
        _client = new ProxyClient();
        _client.status(method(:onChecked));
    }

    function onChecked(code as Number, data as Dictionary or String or Null) as Void {
        Log.response("Pair: status", code);
        var text = SettingsMenuDelegate.describeStatus(code);
        if (code == 200) {
            text = WatchUi.loadResource(Rez.Strings.pairDone) as String;
        }
        end(text);
    }

    private function end(text as String) as Void {
        _finished = true;
        _status = text;
        _code = null;
        stop();
        WatchUi.requestUpdate();
    }

    private function stopTimer() as Void {
        var timer = _timer;
        if (timer != null) {
            timer.stop();
            _timer = null;
        }
    }

    private function stop() as Void {
        stopTimer();
        if (_holding) {
            _holding = false;
            Idle.release();
        }
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        var centre = dc.getWidth() / 2;
        var height = dc.getHeight();
        var justify = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;

        var code = _code;
        if (code == null) {
            dc.drawText(centre, height / 2, Graphics.FONT_SMALL, _status, justify);
            return;
        }
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centre, height * 22 / 100, Graphics.FONT_XTINY,
            WatchUi.loadResource(Rez.Strings.pairOpen) as String, justify);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centre, height * 33 / 100, Graphics.FONT_XTINY, _client.host() + "/pair", justify);
        dc.drawText(centre, height / 2 + height / 20, Graphics.FONT_LARGE, code, justify);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centre, height * 76 / 100, Graphics.FONT_XTINY, _status, justify);
    }
}
