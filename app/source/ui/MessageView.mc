import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Eine Meldung, die den Nutzer nicht ratlos zurücklässt.
//!
//! Ohne diese Ansicht endet jeder Fehlerfall in einem leeren Bildschirm — das
//! ist der Unterschied zwischen "geht nicht" und "warum es nicht geht".
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
