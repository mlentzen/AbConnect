import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Media;
import Toybox.Time;
import Toybox.WatchUi;

//! Which build this is, and what state it is in.
//!
//! The two halves belong together. A version number alone cannot answer "why is
//! it behaving like that" — the counts below it can, and they are the same
//! numbers the log would print if the log were switched on, which by default it
//! is not. This screen is what a silent build has instead.
class InfoView extends WatchUi.View {

    //! Label column left, value column right, both inset from the round edge.
    private const MARGIN = 0.18;

    function initialize() {
        View.initialize();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();
        var centre = width / 2;
        var left = (width * MARGIN).toNumber();
        var right = width - left;

        // Six lines on a fixed grid, centred as a block rather than laid out
        // from the top: on a round screen the top and the bottom are the narrow
        // parts, and a grid started at the top puts the last row off the glass.
        // The version line is the one in the larger font, so it is worth its
        // own height in the reckoning.
        var rowHeight = dc.getFontHeight(Graphics.FONT_XTINY);
        var titleHeight = dc.getFontHeight(Graphics.FONT_SMALL);
        // Version, build, a blank, and four rows: one title plus six rows.
        var blockHeight = titleHeight + rowHeight * 6;
        var y = height / 2 - blockHeight / 2 + titleHeight / 2;

        dc.drawText(
            centre, y,
            Graphics.FONT_SMALL,
            (WatchUi.loadResource(Rez.Strings.AppName) as String) + " " + $.APP_VERSION,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
        y += titleHeight / 2 + rowHeight / 2;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            centre, y,
            Graphics.FONT_XTINY,
            build(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // A blank row between which build this is and what it currently holds.
        y += rowHeight;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var stats = Media.getCacheStatistics();
        row(dc, left, right, y + rowHeight * 1,
            Rez.Strings.infoBooks, Store.localBooks().size().toString());
        row(dc, left, right, y + rowHeight * 2,
            Rez.Strings.infoCache, (stats.size / 1048576).toString() + " MB");
        row(dc, left, right, y + rowHeight * 3,
            Rez.Strings.infoPending, ProgressPush.pending().toString());
        row(dc, left, right, y + rowHeight * 4,
            Rez.Strings.infoChecked, lastCheck());
    }

    private function row(
        dc as Graphics.Dc, left as Number, right as Number, y as Number,
        label as Lang.ResourceId, value as String
    ) as Void {
        dc.drawText(
            left, y, Graphics.FONT_XTINY,
            WatchUi.loadResource(label) as String,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER
        );
        dc.drawText(
            right, y, Graphics.FONT_XTINY, value,
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    //! Commit and date, or just the date outside a git checkout.
    private static function build() as String {
        if (BuildDefaults.COMMIT.length() == 0) {
            return BuildDefaults.BUILT;
        }
        return BuildDefaults.COMMIT + " · " + BuildDefaults.BUILT;
    }

    //! How long ago the playlist was last read successfully.
    //!
    //! Since sync only ever runs by hand, this is the one number that says
    //! whether the watch's idea of what should be on it is still worth
    //! anything.
    private static function lastCheck() as String {
        var stamp = Store.lastCheck();
        if (stamp == 0) {
            return WatchUi.loadResource(Rez.Strings.infoNever) as String;
        }
        var ago = WatchUi.loadResource(Rez.Strings.infoAgo) as String;
        var seconds = Time.now().value() - stamp;
        if (seconds < 3600) {
            return (seconds / 60).toString() + " min " + ago;
        }
        if (seconds < 86400) {
            return (seconds / 3600).toString() + " h " + ago;
        }
        return (seconds / 86400).toString() + " d " + ago;
    }
}
