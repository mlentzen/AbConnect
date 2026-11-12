import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;

//! "5 min ago" in the watch's language, for rows and screens that show when
//! something last happened.
module Ago {

    function since(stamp as Number) as String {
        var seconds = Time.now().value() - stamp;
        if (seconds < 60) {
            return WatchUi.loadResource(Rez.Strings.agoNow) as String;
        }
        if (seconds < 3600) {
            return Lang.format(WatchUi.loadResource(Rez.Strings.infoAgoMinutes) as String, [seconds / 60]);
        }
        if (seconds < 86400) {
            return Lang.format(WatchUi.loadResource(Rez.Strings.infoAgoHours) as String, [seconds / 3600]);
        }
        return Lang.format(WatchUi.loadResource(Rez.Strings.infoAgoDays) as String, [seconds / 86400]);
    }
}
