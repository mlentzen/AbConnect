import Toybox.Lang;

module Errors {

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
        return Util.text(resource) + " (" + code.toString() + ")";
    }
}
