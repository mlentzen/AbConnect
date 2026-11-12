import Toybox.Lang;
import Toybox.Media;
import Toybox.Time;
import Toybox.WatchUi;

const RESUME_ITEM = :resumeBook;
const FROM_START_ITEM = :fromStart;

//! The chapters of one book: Resume, From the start, then every chapter with
//! its start time. The chapter that is playing is marked and the list opens on
//! it, so a long book does not start at chapter 1.
class ChapterMenu extends WatchUi.Menu2 {

    //! Row to focus the first time the menu is shown, or 0 for none.
    private var _focusAt as Number;

    function initialize(bookId as String) {
        var info = Store.bookInfo(bookId);
        Menu2.initialize({ :title => MenuText.label(info[0], bookId) });
        _focusAt = 0;

        var segments = Store.orderedSegments(bookId);
        var position = Store.position(bookId);
        Log.debugCode("Chapters: building for segments", segments.size());

        if (position != null) {
            addItem(
                new WatchUi.MenuItem(
                    WatchUi.loadResource(Rez.Strings.resume) as String,
                    landingPoint(segments, position),
                    $.RESUME_ITEM,
                    null
                )
            );
        }
        addItem(
            new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.fromStart) as String,
                null,
                $.FROM_START_ITEM,
                null
            )
        );

        // Rows before the first chapter: Resume (when there is a position) and From the start.
        var leading = (position == null) ? 1 : 2;
        var start = 0;
        var playing = (position == null) ? -1 : position[0];
        for (var i = 0; i < segments.size(); ++i) {
            var number = segments[i]["index"] as Number;
            var when = clock(start);
            if (number == playing) {
                when = when + " · " + (WatchUi.loadResource(Rez.Strings.chapterNow) as String);
                _focusAt = leading + i;
            }
            addItem(new WatchUi.MenuItem(
                MenuText.label(segments[i]["title"] as String, number.toString()),
                when,
                number,
                null
            ));
            start += segments[i]["duration"] as Number;
        }
    }

    function onShow() as Void {
        Menu2.onShow();
        if (_focusAt > 0) {
            setFocus(_focusAt);
            _focusAt = 0;
        }
    }

    //! Title of the chapter the book stands at, or null when nothing is remembered.
    static function currentTitle(bookId as String) as String? {
        var position = Store.position(bookId);
        if (position == null) {
            return null;
        }
        var segments = Store.orderedSegments(bookId);
        for (var i = 0; i < segments.size(); ++i) {
            if ((segments[i]["index"] as Number) == position[0]) {
                return segments[i]["title"] as String;
            }
        }
        return null;
    }

    private static function landingPoint(
        segments as Array<Dictionary>, position as Array<Number>
    ) as String {
        var start = 0;
        for (var i = 0; i < segments.size(); ++i) {
            if ((segments[i]["index"] as Number) == position[0]) {
                return (segments[i]["title"] as String) + " - " + clock(start + position[1]);
            }
            start += segments[i]["duration"] as Number;
        }
        return clock(position[1]);
    }

    private static function clock(seconds as Number) as String {
        return (seconds / 3600).toString()
            + ":" + ((seconds / 60) % 60).format("%02d")
            + ":" + (seconds % 60).format("%02d");
    }
}

class ChapterMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _bookId as String;
    private var _push as ProgressPush;

    function initialize(bookId as String) {
        Menu2InputDelegate.initialize();
        _bookId = bookId;
        _push = new ProgressPush();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == $.RESUME_ITEM) {
            Log.info("Chapters: agreeing with the server before playing");
            _push.syncThenPlay(_bookId);
            return;
        }
        if (id == $.FROM_START_ITEM) {
            startAt(firstSegment());
            return;
        }
        if (id instanceof Number) {
            startAt(id);
        }
    }

    private function firstSegment() as Number {
        var segments = Store.orderedSegments(_bookId);
        if (segments.size() > 0) {
            return segments[0]["index"] as Number;
        }
        return 0;
    }

    private function startAt(segment as Number) as Void {
        Log.code("Chapters: starting segment", segment);
        Store.rememberPosition(_bookId, segment, 0, Time.now().value());
        Current.set(_bookId);
        Log.info("Chapters: startPlayback " + _bookId);
        Media.startPlayback(_bookId);
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}
