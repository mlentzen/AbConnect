import Toybox.Lang;
import Toybox.Media;
import Toybox.Time;
import Toybox.WatchUi;

const RESUME_ITEM = :resumeBook;
const FROM_START_ITEM = :fromStart;

class ChapterMenu extends WatchUi.Menu2 {

    private var _focusAt as Number;

    function initialize(bookId as String) {
        Menu2.initialize({ :title => MenuText.label(Store.bookInfo(bookId)[0], bookId) });
        _focusAt = 0;

        var segments = Store.orderedSegments(bookId);
        var position = Store.position(bookId);
        Log.debugCode("Chapters: building for segments", segments.size());

        if (position != null) {
            addItem(new WatchUi.MenuItem(
                Util.text(Rez.Strings.resume), landingPoint(segments, position), $.RESUME_ITEM, null
            ));
        }
        addItem(new WatchUi.MenuItem(Util.text(Rez.Strings.fromStart), null, $.FROM_START_ITEM, null));

        var leadingRows = (position == null) ? 1 : 2;
        var playing = (position == null) ? -1 : position[0];
        var start = 0;
        for (var i = 0; i < segments.size(); ++i) {
            var number = segments[i]["index"] as Number;
            var when = clock(start);
            if (number == playing) {
                when += " · " + Util.text(Rez.Strings.chapterNow);
                _focusAt = leadingRows + i;
            }
            addItem(new WatchUi.MenuItem(
                MenuText.label(segments[i]["title"] as String, number.toString()), when, number, null
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

    private static function landingPoint(segments as Array<Dictionary>, position as Array<Number>) as String {
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
        } else if (id == $.FROM_START_ITEM) {
            startAt(firstSegment());
        } else if (id instanceof Number) {
            startAt(id);
        }
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }

    private function firstSegment() as Number {
        var segments = Store.orderedSegments(_bookId);
        return (segments.size() > 0) ? segments[0]["index"] as Number : 0;
    }

    private function startAt(segment as Number) as Void {
        Log.code("Chapters: starting segment", segment);
        Store.rememberPosition(_bookId, segment, 0, Time.now().value());
        Current.set(_bookId);
        Log.info("Chapters: startPlayback " + _bookId);
        Media.startPlayback(_bookId);
    }
}
