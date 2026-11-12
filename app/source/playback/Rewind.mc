import Toybox.Lang;

//! How far to step back when a book is picked up again.
//!
//! After a break the listener has lost the thread. The longer the break, the
//! further back playback starts. A short break needs nothing.
module Rewind {

    //! Breaks shorter than this resume exactly where they stopped.
    const SHORT_BREAK_SECONDS = 600;
    //! Breaks up to this long step back a little; longer ones step back more.
    const LONG_BREAK_SECONDS = 3600;

    const SHORT_BREAK_REWIND_SECONDS = 30;
    const LONG_BREAK_REWIND_SECONDS = 120;

    //! Seconds to go back after a break of idleSeconds.
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
