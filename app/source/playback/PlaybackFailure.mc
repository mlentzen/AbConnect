import Toybox.Lang;

//! Returned by the iterator when a segment should have played and cannot.
//!
//! null means there is no such track. The player treats any other object that
//! is not media content as an error and displays toString().
class PlaybackFailure {

    private var _message as String;

    function initialize(message as String) {
        _message = message;
    }

    function toString() as String {
        return _message;
    }
}
