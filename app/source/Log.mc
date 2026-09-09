import Toybox.Lang;
import Toybox.System;

//! Execution traces for the simulator and for the log file on the watch.
//!
//! Sync and playback run without a UI of their own: if either one gets stuck,
//! only the console says where. Every line starts with the mode, because the
//! system restarts the app per mode and the output would otherwise be
//! impossible to tell apart.
//!
//! Four levels, chosen at build time. The default is errors only — see the
//! note at LEVEL for why that is a performance question and not a taste one.
module Log {

    //! Something failed: a request that did not arrive, a store entry that
    //! cannot be read, a watchdog that had to end a sync. If it is here, the
    //! app did not do what it was asked.
    const ERROR = 0;
    //! Something was wrong and was worked around. Worth knowing when the result
    //! looks odd, not worth a line when it does not.
    const WARN = 1;
    //! The course of events: modes, phases, what started and what stopped. A
    //! handful of lines per run.
    const INFO = 2;
    //! Per item and per tick — every segment, every cache entry, every
    //! estimated position. A flood, and the only thing that helps when the
    //! player refuses to say why it plays nothing.
    const DEBUG = 3;

    //! How much this build says, from build.sh (LOG_LEVEL, default 0).
    //!
    //! A constant rather than a setting so that the comparisons fold away at
    //! compile time. That matters more than it looks: Monkey C builds the
    //! argument at the call site, so a debug line whose message is concatenated
    //! costs its concatenation even when nothing is printed. Call sites in
    //! loops and tickers therefore guard on this constant themselves rather
    //! than leaving it to the functions below.
    const LEVEL = BuildDefaults.LOG_LEVEL;

    function error(message as String) as Void {
        if (LEVEL >= ERROR) {
            System.println(message);
        }
    }

    function warn(message as String) as Void {
        if (LEVEL >= WARN) {
            System.println(message);
        }
    }

    function info(message as String) as Void {
        if (LEVEL >= INFO) {
            System.println(message);
        }
    }

    //! Indented, so that in a console full of per-item lines the structural
    //! ones above still stand out.
    function debug(message as String) as Void {
        if (LEVEL >= DEBUG) {
            System.println("    " + message);
        }
    }

    //! A message and a number. The two are joined here rather than at the call
    //! site so that nothing is concatenated when the level does not print it.
    function code(message as String, value as Number) as Void {
        if (LEVEL >= INFO) {
            System.println(message + " -> " + value.toString());
        }
    }

    //! The same, for a number that only matters when something went wrong.
    function errorCode(message as String, value as Number) as Void {
        if (LEVEL >= ERROR) {
            System.println(message + " -> " + value.toString());
        }
    }

    //! The same, for a number that says something was worked around.
    function warnCode(message as String, value as Number) as Void {
        if (LEVEL >= WARN) {
            System.println(message + " -> " + value.toString());
        }
    }

    //! The same, for a number worth a line only in the flood.
    function debugCode(message as String, value as Number) as Void {
        if (LEVEL >= DEBUG) {
            System.println("    " + message + " -> " + value.toString());
        }
    }

    //! The code a request came back with.
    //!
    //! Every one of these decides its own level, because the interesting half
    //! is the half that failed: a build reporting errors only must still say
    //! that the playlist came back 401 or that the radio answered -104. A 200
    //! is merely the course of events and stays quiet.
    function response(message as String, code as Number) as Void {
        if (code == 200) {
            Log.code(message, code);
        } else {
            Log.errorCode(message, code);
        }
    }

    //! A media ref ID with its type.
    //!
    //! The docs say getCachedContentObj() wants a String ID for audio. On the
    //! fēnix they are numbers, and they resolve cleanly — the type is logged
    //! anyway, because it travels through the object store and could change on
    //! the way. A broken round trip shows up here and nowhere else.
    function describe(id as Object?) as String {
        if (id == null) {
            return "none";
        }
        if (id instanceof String) {
            return "String '" + id + "'";
        }
        if (id instanceof Number) {
            return "Number " + id.toString();
        }
        if (id instanceof Long) {
            return "Long " + id.toString();
        }
        return "other type";
    }
}
