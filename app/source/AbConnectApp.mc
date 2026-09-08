import Toybox.Application;
import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Media;
import Toybox.WatchUi;

//! Audio Content Provider für Audiobookshelf.
//!
//! Das System startet die App in vier getrennten Modi — Sync-Konfiguration,
//! Sync, Playback-Konfiguration und Playback. Jeder Modus ist ein eigener
//! App-Start ohne gemeinsamen Laufzeitzustand; alles, was einen Modus
//! überdauern muss, liegt im Object Store.
class AbConnectApp extends Application.AudioContentProviderApp {

    function initialize() {
        AudioContentProviderApp.initialize();
        Store.checkSchema();
    }

    //! Modus 1: Nutzer wählt aus, was auf die Uhr soll.
    function getSyncConfigurationView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new SyncConfigView()];
    }

    //! Modus 2: das System hat WLAN aktiviert und lässt uns laden.
    function getSyncDelegate() as Communications.SyncDelegate? {
        return new AbSyncDelegate();
    }

    //! Modus 3: Nutzer wählt aus, was abgespielt wird.
    function getPlaybackConfigurationView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new PlaybackConfigView()];
    }

    //! Modus 4: der System-Player fragt uns nach den Tracks.
    function getContentDelegate(args as Application.PersistableType) as Media.ContentDelegate {
        return new AbContentDelegate();
    }

    function getProviderIconInfo() as Media.ProviderIconInfo? {
        return new Media.ProviderIconInfo(Rez.Drawables.LauncherIcon, Graphics.COLOR_BLUE);
    }
}
