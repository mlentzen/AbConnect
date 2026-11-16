import Toybox.Lang;

module BookProgress {

    function line(bookId as String) as String? {
        var spot = Store.position(bookId);
        if (spot == null) {
            return null;
        }
        var times = Store.segmentTimes(bookId, spot[0]);
        var total = times[1];
        var done = times[0] + spot[1];
        if (total <= 0 || done <= 0) {
            return null;
        }
        if (done >= total) {
            return Util.text(Rez.Strings.bookFinished);
        }
        return Lang.format(Util.text(Rez.Strings.bookProgress), [(done * 100) / total, timeLeft(total - done)]);
    }

    function timeLeft(seconds as Number) as String {
        var minutes = (seconds + 59) / 60;
        if (minutes < 60) {
            return Lang.format(Util.text(Rez.Strings.bookLeftMinutes), [minutes]);
        }
        return Lang.format(Util.text(Rez.Strings.bookLeftHours), [minutes / 60, minutes % 60]);
    }
}
