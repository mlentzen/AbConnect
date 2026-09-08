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
}
