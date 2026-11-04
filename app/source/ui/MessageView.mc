import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

class MessageView extends WatchUi.View {

    private var _text as String;
    private var _closeAfterMs as Number;
    private var _timer as Timer.Timer?;
    private var _shown as Boolean;

    function initialize(text as String) {
        View.initialize();
        _text = text;
        _closeAfterMs = 0;
        _timer = null;
        _shown = false;
    }

    function closeAfter(ms as Number) as Void {
        _closeAfterMs = ms;
    }

    function isShown() as Boolean {
        return _shown;
    }

    function onShow() as Void {
        _shown = true;
        if (_closeAfterMs > 0 && _timer == null) {
            var timer = new Timer.Timer();
            timer.start(method(:onClose), _closeAfterMs, false);
            _timer = timer;
        }
    }

    function onHide() as Void {
        _shown = false;
        var timer = _timer;
        if (timer != null) {
            timer.stop();
            _timer = null;
        }
    }

    function onClose() as Void {
        _timer = null;
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        dc.drawText(
            dc.getWidth() / 2,
            dc.getHeight() / 2,
            Graphics.FONT_SMALL,
            _text,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }
}

//! Menu2 on the fēnix draws the IQ screen if a label or subtitle is "".
//! null is a missing subtitle; "" is not.
module MenuText {

    function label(text as String, fallback as String) as String {
        if (text.length() > 0) {
            return text;
        }
        if (fallback.length() > 0) {
            return fallback;
        }
        return "-";
    }

    function sublabel(text as String) as String? {
        if (text.length() == 0) {
            return null;
        }
        return text;
    }
}

class BackDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }
}
