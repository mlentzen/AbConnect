import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

//! A message that does not leave the user puzzled.
//!
//! Without this view every error case ends in a blank screen — that is the
//! difference between "does not work" and "why it does not work".
class MessageView extends WatchUi.View {

    private var _text as String;
    //! How long the message stays before it takes itself away, or 0 to wait
    //! for BACK.
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

    //! Make way for whatever is underneath after this long.
    function closeAfter(ms as Number) as Void {
        _closeAfterMs = ms;
    }

    //! Whether this view is the one on screen. What decides whether a later
    //! view may take its place or has to go on top.
    function isShown() as Boolean {
        return _shown;
    }

    function onShow() as Void {
        _shown = true;
        Idle.poke();
        if (_closeAfterMs > 0 && _timer == null) {
            var timer = new Timer.Timer();
            timer.start(method(:onClose), _closeAfterMs, false);
            _timer = timer;
        }
    }

    //! The timer stops with the view, so it can never pop a view that is not
    //! this one — BACK may have got there first.
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

//! A pushed View gets no input of its own, so BACK would not return to
//! whatever is underneath it. Every view in this app that is pushed rather
//! than switched to is pushed with one of these.
class BackDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onBack() as Boolean {
        Idle.poke();
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }
}
