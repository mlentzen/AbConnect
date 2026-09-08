import Toybox.Lang;
import Toybox.System;

//! Ablaufspuren für den Simulator.
//!
//! Sync und Playback laufen ohne eigene Oberfläche: bleibt einer der beiden
//! stehen, sagt nur die Konsole, an welcher Stelle. Jede Zeile beginnt mit dem
//! Modus, weil das System die App je Modus neu startet und die Ausgaben sonst
//! nicht auseinanderzuhalten sind.
module Log {

    //! Auf false setzen, sobald die App auf der Uhr läuft.
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
