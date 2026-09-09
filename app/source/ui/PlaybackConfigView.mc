import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! The way into the app, and nothing more.
//!
//! The system opens this view when the provider is picked, but what belongs on
//! screen is a menu — and a Menu2 cannot be returned from
//! getPlaybackConfigurationView(). So this View exists to push one and then get
//! out of the way: the _menuShown flag catches the second onShow(), the one
//! that arrives when the menu is dismissed, and pops this view with it. Without
//! that, BACK out of the menu would land on an empty screen instead of leaving
//! the app.
class PlaybackConfigView extends WatchUi.View {

    private var _menuShown as Boolean;

    function initialize() {
        View.initialize();
        _menuShown = false;
    }

    function onShow() as Void {
        if (_menuShown) {
            Log.debug("Config: the menu is gone, leaving");
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
