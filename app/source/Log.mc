import Toybox.Lang;
import Toybox.System;

//! Execution traces for the simulator.
//!
//! Sync and playback run without a UI of their own: if either one gets stuck,
//! only the console says where. Every line starts with the mode, because the
//! system restarts the app per mode and the output would otherwise be
//! impossible to tell apart.
module Log {

    //! Set to false once the app runs on the watch.
    const ENABLED = true;

    //! Per-item traces: every segment, every cache entry, every metadata field.
    //!
    //! Far too loud for normal operation — one line per file in the cache — and
    //! exactly what is needed while the player still refuses to say why it
    //! plays nothing. Kept apart from ENABLED so the flood can go without the
    //! structure going with it.
    const VERBOSE = true;

    function line(message as String) as Void {
        if (ENABLED) {
            System.println(message);
        }
    }

    function code(message as String, value as Number) as Void {
        if (ENABLED) {
            System.println(message + " -> " + value.toString());
        }
    }

    //! One item out of a list. Indented, so that the structural lines above
    //! still stand out in a console full of them.
    function detail(message as String) as Void {
        if (ENABLED && VERBOSE) {
            System.println("    " + message);
        }
    }
}
