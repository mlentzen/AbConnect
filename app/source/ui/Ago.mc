import Toybox.Lang;
import Toybox.Time;

module Ago {

    function since(stamp as Number) as String {
        var seconds = Time.now().value() - stamp;
        if (seconds < 60) {
            return Util.text(Rez.Strings.agoNow);
        }
        if (seconds < 3600) {
            return Lang.format(Util.text(Rez.Strings.infoAgoMinutes), [seconds / 60]);
        }
        if (seconds < 86400) {
            return Lang.format(Util.text(Rez.Strings.infoAgoHours), [seconds / 3600]);
        }
        return Lang.format(Util.text(Rez.Strings.infoAgoDays), [seconds / 86400]);
    }
}
