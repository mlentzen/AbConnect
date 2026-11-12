import Toybox.Lang;
import Toybox.WatchUi;

//! How far into a book the listener is, for the book list.
//!
//! Worked out from the segments that are on the watch and the remembered
//! position. A book with no remembered position has no progress to show.
module BookProgress {

    //! "42 % · 5 h 10 min left", or null when nothing was listened to yet.
    function line(bookId as String) as String? {
        var spot = Store.position(bookId);
        if (spot == null) {
            return null;
        }
        var facts = Store.localSegmentFacts(bookId);
        var total = 0;
        var before = 0;
        for (var i = 0; i < facts.size(); ++i) {
            var fact = facts[i] as Dictionary;
            var duration = fact["duration"] as Number;
            total += duration;
            if ((fact["index"] as Number) < spot[0]) {
                before += duration;
            }
        }
        if (total <= 0) {
            return null;
        }
        var done = before + spot[1];
        if (done <= 0) {
            return null;
        }
        if (done >= total) {
            return WatchUi.loadResource(Rez.Strings.bookFinished) as String;
        }
        return Lang.format(
            WatchUi.loadResource(Rez.Strings.bookProgress) as String,
            [(done * 100) / total, timeLeft(total - done)]
        );
    }

    //! Whole minutes, rounded up so the last seconds do not read "0 min".
    function timeLeft(seconds as Number) as String {
        var minutes = (seconds + 59) / 60;
        if (minutes < 60) {
            return Lang.format(WatchUi.loadResource(Rez.Strings.bookLeftMinutes) as String, [minutes]);
        }
        return Lang.format(
            WatchUi.loadResource(Rez.Strings.bookLeftHours) as String,
            [minutes / 60, minutes % 60]
        );
    }
}
