import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class PlaybackConfigView extends WatchUi.View {

    private var _menuShown as Boolean;

    function initialize() {
        View.initialize();
        _menuShown = false;
    }

    function onShow() as Void {
        if (_menuShown) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        _menuShown = true;
        WatchUi.pushView(new MainMenu(), new MainMenuDelegate(), WatchUi.SLIDE_IMMEDIATE);
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
    }
}
