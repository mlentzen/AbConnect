import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! A message that does not leave the user puzzled.
//!
//! Without this view every error case ends in a blank screen — that is the
//! difference between "does not work" and "why it does not work".
class MessageView extends WatchUi.View {

    private var _text as String;

    function initialize(text as String) {
        View.initialize();
        _text = text;
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
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }
}
