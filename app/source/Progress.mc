import Toybox.Lang;

//! What the proxy says back when the watch reports where it is.
//!
//! Three paths push listening progress — the sync over Wi-Fi, the automatic
//! push when playback pauses, and the menu row that sends it by hand — and all
//! three get the same reply and owe it the same treatment. The handling lived
//! in two places before this one and was a single paste away from living in
//! three.
module Progress {

    //! Where the server was ahead of the watch, the watch jumps to it.
    //!
    //! The timestamp stays zero on purpose: a position taken over from the
    //! server is not news to the server. With a real timestamp the watch would
    //! push straight back what it had just been told.
    function adopt(data as Dictionary or String or Null) as Void {
        if (!(data instanceof Dictionary)) {
            return;
        }
        var books = data["books"];
        if (!(books instanceof Array)) {
            return;
        }
        for (var i = 0; i < books.size(); ++i) {
            var entry = books[i];
            if (!(entry instanceof Dictionary)) {
                continue;
            }
            var resume = entry["resume"];
            var bookId = entry["id"];
            if (resume instanceof Dictionary && bookId instanceof String) {
                var segment = resume["segment"];
                if (segment instanceof Number) {
                    Log.code("Progress: server is ahead in segment", segment);
                    Store.rememberPosition(
                        bookId, segment, AbSyncDelegate.numberOf(resume["offset"]), 0
                    );
                }
            }
        }
    }
}
