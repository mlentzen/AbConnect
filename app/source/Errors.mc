import Toybox.Lang;
import Toybox.WatchUi;

//! Plain wording for what went wrong, in the watch's language.
//!
//! The number stays in brackets so a screenshot or a report still says which
//! answer the server or the phone gave.
module Errors {

    //! What an HTTP status, or a negative Connect IQ error code, means for the
    //! person holding the watch.
    function fromCode(code as Number) as String {
        var resource = Rez.Strings.errOther;
        if (code <= 0) {
            resource = Rez.Strings.errNoConnection;
        } else if (code == 401 || code == 403) {
            resource = Rez.Strings.errRejected;
        } else if (code == 404) {
            resource = Rez.Strings.errNotFound;
        } else if (code == 409) {
            resource = Rez.Strings.errNotReady;
        } else if (code >= 500) {
            resource = Rez.Strings.errServer;
        }
        return (WatchUi.loadResource(resource) as String) + " (" + code.toString() + ")";
    }

    function text(resource as Lang.ResourceId) as String {
        return WatchUi.loadResource(resource) as String;
    }
}
