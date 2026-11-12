import Toybox.Lang;

module BookProgress {

    function line(bookId as String) as String? {
        var spot = Store.position(bookId);
        if (spot == null) {
            return null;
        }
        var facts = Store.localSegmentFacts(bookId);
        var total = 0;
        var before = 0;
        for (var i = 0; i < facts.size(); ++i) {
            var duration = facts[i]["duration"] as Number;
            total += duration;
            if ((facts[i]["index"] as Number) < spot[0]) {
                before += duration;
            }
        }
        var done = before + spot[1];
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
