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
        Log.info("Mode: sync configuration");
        Idle.start();
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
        Idle.start();
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
    //! Not the launcher icon: the apps list and the music providers list show
    //! that one already, and this entry sits among the system's own, so it is
    //! a plain menu symbol in their style. The sync screen never asks for it —
    //! the log of a sync has no request — and shows the startSync2 message.
    function getProviderIconInfo() as Media.ProviderIconInfo? {
        // Info, not debug: whether and when the system asks for the icon is
        // the whole question behind a blank sync screen, and a debug build
        // floods the log file past rotation before a sync is over.
        Log.info("Icon: requested");
        return new Media.ProviderIconInfo(Rez.Drawables.ProviderIcon, Graphics.COLOR_BLUE);
    }

    //! What every mode hangs on: what is on the watch at all.
    //!
    //! As long as no sync has run, the store is empty — and the empty paths are
    //! exactly the least travelled ones.
    private function logStore() as Void {
        Log.debugCode("Store: known", Store.knownBooks().size());
        Log.debugCode("Store: playable", Store.localBooks().size());
        if (Log.LEVEL >= Log.DEBUG) {
            var current = Current.bookId();
            Log.debug("Store: current " + ((current == null) ? "none" : current));
        }
    }
}
