import Toybox.Application;
import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Media;
import Toybox.WatchUi;

//! Audio content provider for Audiobookshelf.
//!
//! The system starts the app in four separate modes — sync configuration,
//! sync, playback configuration and playback. Each mode is its own app start
//! without shared runtime state; anything that has to outlive a mode lives in
//! the Object Store.
class AbConnectApp extends Application.AudioContentProviderApp {

    function initialize() {
        AudioContentProviderApp.initialize();
        Store.checkSchema();
    }

    //! Mode 1: the user selects what should go onto the watch.
    function getSyncConfigurationView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        Log.line("Mode: sync configuration");
        return [new SyncConfigView()];
    }

    //! Mode 2: the system has enabled Wi-Fi and lets us download.
    function getSyncDelegate() as Communications.SyncDelegate? {
        Log.line("Mode: sync");
        return new AbSyncDelegate();
    }

    //! Mode 3: the user selects what is played.
    function getPlaybackConfigurationView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        Log.line("Mode: playback configuration");
        return [new PlaybackConfigView()];
    }

    //! Mode 4: the system player asks us for the tracks.
    function getContentDelegate(args as Application.PersistableType) as Media.ContentDelegate {
        Log.line("Mode: playback");
        return new AbContentDelegate();
    }

    function getProviderIconInfo() as Media.ProviderIconInfo? {
        return new Media.ProviderIconInfo(Rez.Drawables.LauncherIcon, Graphics.COLOR_BLUE);
    }
}
