import Toybox.Lang;
import Toybox.System;

//! Execution traces for the simulator and for the log file on the watch.
//!
//! Sync and playback run without a UI of their own, so the log is the only
//! way to see where they get stuck.
//!
//! Four levels, chosen at build time (LOG_LEVEL in build.sh). The default is
//! errors only.
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
    //! Per item and per tick, every segment, every cache entry, every
    //! estimated position. A flood, and the only thing that helps when the
    //! player refuses to say why it plays nothing.
    const DEBUG = 3;

    //! How much this build says, from build.sh (LOG_LEVEL, default 0).
    //!
    //! A constant so the comparisons fold away at compile time. Monkey C
    //! builds the message before the call, so call sites in loops guard on
    //! this constant themselves.
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
    //! A failure is always logged; a 200 only at INFO.
    function response(message as String, code as Number) as Void {
        if (code == 200) {
            Log.code(message, code);
        } else {
            Log.errorCode(message, code);
        }
    }

    //! A media ref ID with its type.
    //!
    //! The type is logged because IDs travel through the object store and may
    //! change type on the way.
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
