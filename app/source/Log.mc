import Toybox.Lang;
import Toybox.System;

module Log {

    const ERROR = 0;
    const WARN = 1;
    const INFO = 2;
    const DEBUG = 3;

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

    function debug(message as String) as Void {
        if (LEVEL >= DEBUG) {
            System.println("    " + message);
        }
    }

    function code(message as String, value as Number) as Void {
        if (LEVEL >= INFO) {
            System.println(message + " -> " + value.toString());
        }
    }

    function errorCode(message as String, value as Number) as Void {
        if (LEVEL >= ERROR) {
            System.println(message + " -> " + value.toString());
        }
    }

    function warnCode(message as String, value as Number) as Void {
        if (LEVEL >= WARN) {
            System.println(message + " -> " + value.toString());
        }
    }

    function debugCode(message as String, value as Number) as Void {
        if (LEVEL >= DEBUG) {
            System.println("    " + message + " -> " + value.toString());
        }
    }

    function response(message as String, code as Number) as Void {
        if (code == 200) {
            Log.code(message, code);
        } else {
            Log.errorCode(message, code);
        }
    }

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
