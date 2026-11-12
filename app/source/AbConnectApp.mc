import Toybox.Application;
import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Media;
import Toybox.WatchUi;

class AbConnectApp extends Application.AudioContentProviderApp {

    function initialize() {
        AudioContentProviderApp.initialize();
        Store.checkSchema();
    }

    function getSyncConfigurationView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        Log.info("Mode: sync configuration");
        return [new SyncConfigView()];
    }

    function getSyncDelegate() as Communications.SyncDelegate? {
        Log.info("Mode: sync");
        return new AbSyncDelegate();
    }

    function getPlaybackConfigurationView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        Log.info("Mode: playback configuration");
        logStore();
        return [new PlaybackConfigView()];
    }

    function getContentDelegate(args as Application.PersistableType) as Media.ContentDelegate {
        Log.info("Mode: playback");
        logStore();
        return new AbContentDelegate();
    }

    function getProviderIconInfo() as Media.ProviderIconInfo? {
        Log.info("Icon: requested");
        return new Media.ProviderIconInfo(Rez.Drawables.ProviderIcon, Graphics.COLOR_BLUE);
    }

    private function logStore() as Void {
        Log.debugCode("Store: known", Store.knownBooks().size());
        Log.debugCode("Store: playable", Store.localBooks().size());
    }
}
