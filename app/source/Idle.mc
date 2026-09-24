import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

//! Ends the app when nobody has touched it for a while.
//!
//! The app menu is an ordinary app on screen: left alone it stays up, keeps the
//! watch face away and holds a Timer or a radio request for nothing. Only the
//! two configuration modes run this — the sync has its own watchdog, and the
//! playback mode belongs to the system player.
//!
//! Input is what counts: every delegate pokes, and so does every view that
//! comes on screen. Work that runs without input — a progress push, a pairing
//! that waits for the phone, a native text picker whose keys never reach us —
//! holds the clock for as long as it runs.
module Idle {

    const TIMEOUT_MS = 120000;
    const TICK_MS = 30000;

    var _timer as Timer.Timer? = null;
    var _lastInput as Number = 0;
    var _holds as Number = 0;

    function start() as Void {
        poke();
        if (_timer != null) {
            return;
        }
        try {
            var timer = new Timer.Timer();
            timer.start(new Lang.Method(Idle, :onTick), TICK_MS, true);
            _timer = timer;
        } catch (ex) {
            // Out of timers: the app then simply stays open, as it always did.
            Log.warn("Idle: no timer available");
        }
    }

    function poke() as Void {
        _lastInput = System.getTimer();
    }

    //! Something is running that must not be cut off. Every hold needs its
    //! release.
    function hold() as Void {
        _holds += 1;
        poke();
    }

    function release() as Void {
        if (_holds > 0) {
            _holds -= 1;
        }
        poke();
    }

    function onTick() as Void {
        if (_holds > 0) {
            return;
        }
        // System.getTimer() wraps; a negative span is a wrap, not idleness.
        var idle = System.getTimer() - _lastInput;
        if (idle < 0) {
            poke();
            return;
        }
        if (idle >= TIMEOUT_MS) {
            Log.info("Idle: no input for a while, ending app");
            System.exit();
        }
    }
}
