import Toybox.Application;
import Toybox.Lang;

//! Zugriff auf den Object Store.
//!
//! Alle Werte sind bewusst flach: verschachtelte Dictionaries sprengen das
//! 8-KB-Limit pro Wert, lange bevor eine größere Bibliothek darin Platz findet.
module Store {

    //! Verwirft den Store, wenn er von einer älteren Schemaversion stammt.
    function checkSchema() as Void {
        var version = Application.Storage.getValue(Keys.SCHEMA);
        if (!(version instanceof Number) || version != Keys.SCHEMA_VERSION) {
            Application.Storage.clearValues();
            Application.Storage.setValue(Keys.SCHEMA, Keys.SCHEMA_VERSION);
        }
    }

    // --- Auswahl -------------------------------------------------------------

    function selection() as Array<String> {
        var stored = Application.Storage.getValue(Keys.SELECTION);
        if (stored instanceof Array) {
            return stored as Array<String>;
        }
        return [] as Array<String>;
    }

    function setSelection(ids as Array<String>) as Void {
        Application.Storage.setValue(Keys.SELECTION, ids);
    }

    function isSelected(bookId as String) as Boolean {
        return selection().indexOf(bookId) >= 0;
    }

    function select(bookId as String) as Void {
        var ids = selection();
        if (ids.indexOf(bookId) < 0) {
            ids.add(bookId);
            setSelection(ids);
        }
    }

    function deselect(bookId as String) as Void {
        var ids = selection();
        var index = ids.indexOf(bookId);
        if (index >= 0) {
            ids.remove(bookId);
            setSelection(ids);
        }
    }

    // --- Lokaler Bestand -----------------------------------------------------

    //! Map refId -> "segIdx|dauer|titel" für ein Buch.
    function localTracks(bookId as String) as Dictionary {
        var stored = Application.Storage.getValue(Keys.local(bookId));
        if (stored instanceof Dictionary) {
            return stored;
        }
        return {};
    }

    function addLocalTrack(
        bookId as String, refId as Object, segment as Number, duration as Number, title as String
    ) as Void {
        remember(bookId);
        var tracks = localTracks(bookId);
        tracks[refId] = segment.toString() + "|" + duration.toString() + "|" + title;
        Application.Storage.setValue(Keys.local(bookId), tracks);
    }

    //! [segIdx, dauer, titel] eines lokalen Tracks, oder null.
    function trackInfo(bookId as String, refId as Object) as Array<String>? {
        var stored = localTracks(bookId)[refId];
        if (!(stored instanceof String)) {
            return null;
        }
        var parts = split(stored, "|");
        if (parts.size() < 3) {
            return null;
        }
        return parts;
    }

    function forgetBook(bookId as String) as Void {
        Application.Storage.deleteValue(Keys.local(bookId));
        Application.Storage.deleteValue(Keys.book(bookId));
        var known = knownBooks();
        if (known.indexOf(bookId) >= 0) {
            known.remove(bookId);
            Application.Storage.setValue(Keys.KNOWN, known);
        }
    }

    //! Alle Bücher, von denen Segmente auf der Uhr liegen — auch abgewählte.
    function knownBooks() as Array<String> {
        var stored = Application.Storage.getValue(Keys.KNOWN);
        if (stored instanceof Array) {
            return stored as Array<String>;
        }
        return [] as Array<String>;
    }

    function remember(bookId as String) as Void {
        var known = knownBooks();
        if (known.indexOf(bookId) < 0) {
            known.add(bookId);
            Application.Storage.setValue(Keys.KNOWN, known);
        }
    }

    //! Buchtitel, Autor und Segmentanzahl in einem flachen Wert.
    function setBookInfo(bookId as String, title as String, author as String, segments as Number) as Void {
        Application.Storage.setValue(Keys.book(bookId), title + "|" + author + "|" + segments.toString());
    }

    function bookInfo(bookId as String) as Array<String> {
        var stored = Application.Storage.getValue(Keys.book(bookId));
        if (stored instanceof String) {
            var parts = split(stored, "|");
            if (parts.size() >= 3) {
                return parts;
            }
        }
        return ["", "", "0"] as Array<String>;
    }

    //! Bücher, von denen mindestens ein Segment abspielbar auf der Uhr liegt.
    function localBooks() as Array<String> {
        var books = [] as Array<String>;
        var ids = knownBooks();
        for (var i = 0; i < ids.size(); ++i) {
            if (localTracks(ids[i]).size() > 0) {
                books.add(ids[i]);
            }
        }
        return books;
    }

    // --- Fortschritt ---------------------------------------------------------

    function progress() as Dictionary {
        var stored = Application.Storage.getValue(Keys.PROGRESS);
        if (stored instanceof Dictionary) {
            return stored;
        }
        return {};
    }

    //! Position merken. Wird beim nächsten Sync an den Proxy geschickt.
    function rememberPosition(bookId as String, segment as Number, seconds as Number, timestamp as Number) as Void {
        var all = progress();
        all[bookId] = segment.toString() + "|" + seconds.toString() + "|" + timestamp.toString();
        Application.Storage.setValue(Keys.PROGRESS, all);
    }

    //! [segIdx, sekunden, zeitstempel] oder null.
    function position(bookId as String) as Array<Number>? {
        var stored = progress()[bookId];
        if (!(stored instanceof String)) {
            return null;
        }
        var parts = split(stored, "|");
        if (parts.size() < 3) {
            return null;
        }
        return [toNumber(parts[0]), toNumber(parts[1]), toNumber(parts[2])] as Array<Number>;
    }

    function clearProgress() as Void {
        Application.Storage.deleteValue(Keys.PROGRESS);
    }

    // --- Hilfen --------------------------------------------------------------

    //! String.toNumber() liefert null, wenn der Wert unlesbar ist. Ein
    //! beschädigter Store-Eintrag darf die App nicht mitreißen.
    function toNumber(value as String) as Number {
        var number = value.toNumber();
        return (number == null) ? 0 : number;
    }

    //! Monkey C kennt kein String.split; die flachen Werte brauchen eines.
    function split(value as String, separator as String) as Array<String> {
        var parts = [] as Array<String>;
        var rest = value;
        var cut = rest.find(separator);
        while (cut != null) {
            parts.add(rest.substring(0, cut) as String);
            rest = rest.substring(cut + separator.length(), rest.length()) as String;
            cut = rest.find(separator);
        }
        parts.add(rest);
        return parts;
    }
}

//! Das Buch, das der Player gerade abspielt.
module Current {
    function bookId() as String? {
        var stored = Application.Storage.getValue(Keys.CURRENT);
        if (stored instanceof String && stored.length() > 0) {
            return stored;
        }
        return null;
    }

    function set(bookId as String) as Void {
        Application.Storage.setValue(Keys.CURRENT, bookId);
    }
}
