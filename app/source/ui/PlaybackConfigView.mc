import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! A Menu2 cannot be returned from getPlaybackConfigurationView(), so this
//! view pushes one and pops itself when the menu is dismissed.
//!
//! The player's own button opens this view, and it opens the main menu. The
//! chapters of the current book are the Chapters row in that menu: the media
//! player offers no way to put a second screen behind a button of its own.
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
