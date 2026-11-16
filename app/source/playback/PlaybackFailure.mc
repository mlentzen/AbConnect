import Toybox.Lang;

class PlaybackFailure {

    private var _message as String;

    function initialize(message as String) {
        _message = message;
    }

    function toString() as String {
        return _message;
    }
}
