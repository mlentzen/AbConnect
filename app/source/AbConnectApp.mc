import Toybox.Application;
import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Media;
import Toybox.WatchUi;

//! Audio content provider for Audiobookshelf.
//!
//! The system starts the app in four separate modes, sync configuration,
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
        Log.info("Mode: sync configuration");
        return [new SyncConfigView()];
    }

    //! Mode 2: the system has enabled Wi-Fi and lets us download.
    function getSyncDelegate() as Communications.SyncDelegate? {
        Log.info("Mode: sync");
        return new AbSyncDelegate();
    }

    //! Mode 3: the user selects what is played.
    function getPlaybackConfigurationView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        Log.info("Mode: playback configuration");
        logStore();
        var view = new PlaybackConfigView();
        Log.debug("Config: view built");
        return [view];
    }

    //! Mode 4: the system player asks us for the tracks.
    function getContentDelegate(args as Application.PersistableType) as Media.ContentDelegate {
        Log.info("Mode: playback");
        logStore();
        var delegate = new AbContentDelegate();
        Log.debug("Playback: delegate built");
        return delegate;
    }

    //! What the watch shows on the entry that opens this app's menu.
    //!
    //! A plain menu symbol in the style of the system's own entries, not the
    //! launcher icon.
    function getProviderIconInfo() as Media.ProviderIconInfo? {
        Log.info("Icon: requested");
        return new Media.ProviderIconInfo(Rez.Drawables.ProviderIcon, Graphics.COLOR_BLUE);
    }

    //! Logs what is on the watch, which every mode depends on.
    private function logStore() as Void {
        Log.debugCode("Store: known", Store.knownBooks().size());
        Log.debugCode("Store: playable", Store.localBooks().size());
        if (Log.LEVEL >= Log.DEBUG) {
            var current = Current.bookId();
            Log.debug("Store: current " + ((current == null) ? "none" : current));
        }
    }
}
