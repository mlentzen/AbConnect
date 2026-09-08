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
