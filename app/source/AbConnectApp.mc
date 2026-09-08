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
        logStore();
        var view = new PlaybackConfigView();
        Log.line("Config: view built");
        return [view];
    }

    //! Mode 4: the system player asks us for the tracks.
    function getContentDelegate(args as Application.PersistableType) as Media.ContentDelegate {
        Log.line("Mode: playback");
        logStore();
        var delegate = new AbContentDelegate();
        Log.line("Playback: delegate built");
        return delegate;
    }

    function getProviderIconInfo() as Media.ProviderIconInfo? {
        Log.line("Icon: requested");
        return new Media.ProviderIconInfo(Rez.Drawables.LauncherIcon, Graphics.COLOR_BLUE);
    }

    //! What every mode hangs on: what is on the watch at all.
    //!
    //! As long as no sync has run, the store is empty — and the empty paths are
    //! exactly the least travelled ones.
    private function logStore() as Void {
        Log.code("Store: known", Store.knownBooks().size());
        Log.code("Store: playable", Store.localBooks().size());
        var current = Current.bookId();
        Log.line("Store: current " + ((current == null) ? "none" : current));
    }
}
