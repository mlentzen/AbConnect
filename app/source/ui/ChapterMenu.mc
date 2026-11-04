import Toybox.Lang;
import Toybox.Media;
import Toybox.Time;
import Toybox.WatchUi;

const RESUME_ITEM = :resumeBook;
const FROM_START_ITEM = :fromStart;

class ChapterMenu extends WatchUi.Menu2 {

    function initialize(bookId as String) {
        var info = Store.bookInfo(bookId);
        Menu2.initialize({ :title => MenuText.label(info[0], bookId) });

        var refs = Store.orderedRefs(bookId);
        var position = Store.position(bookId);
        Log.debugCode("Chapters: building for segments", refs.size());

        if (position != null) {
            addItem(
                new WatchUi.MenuItem(
                    WatchUi.loadResource(Rez.Strings.resume) as String,
                    landingPoint(bookId, refs, position),
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

        var start = 0;
        for (var i = 0; i < refs.size(); ++i) {
            var parts = Store.trackInfo(bookId, refs[i]);
            if (parts == null) {
                continue;
            }
            addItem(new WatchUi.MenuItem(
                MenuText.label(parts[2], Store.toNumber(parts[0]).toString()),
                clock(start),
                Store.toNumber(parts[0]),
                null
            ));
            start += Store.toNumber(parts[1]);
        }
    }

    private static function landingPoint(
        bookId as String, refs as Array, position as Array<Number>
    ) as String {
        var start = 0;
        for (var i = 0; i < refs.size(); ++i) {
            var parts = Store.trackInfo(bookId, refs[i]);
            if (parts == null) {
                continue;
            }
            if (Store.toNumber(parts[0]) == position[0]) {
                return parts[2] + " - " + clock(start + position[1]);
            }
            start += Store.toNumber(parts[1]);
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
        var refs = Store.orderedRefs(_bookId);
        for (var i = 0; i < refs.size(); ++i) {
            var parts = Store.trackInfo(_bookId, refs[i]);
            if (parts != null) {
                return Store.toNumber(parts[0]);
            }
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
