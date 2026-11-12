import Toybox.Lang;

module Rewind {

    const SHORT_BREAK_SECONDS = 600;
    const LONG_BREAK_SECONDS = 3600;
    const SHORT_BREAK_REWIND_SECONDS = 30;
    const LONG_BREAK_REWIND_SECONDS = 120;

    function secondsFor(idleSeconds as Number) as Number {
        if (idleSeconds < SHORT_BREAK_SECONDS) {
            return 0;
        }
        if (idleSeconds <= LONG_BREAK_SECONDS) {
            return SHORT_BREAK_REWIND_SECONDS;
        }
        return LONG_BREAK_REWIND_SECONDS;
    }
}
