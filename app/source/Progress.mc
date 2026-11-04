import Toybox.Lang;

//! What the proxy says back when the watch reports where it is.
//!
//! Three paths push listening progress (the Wi-Fi sync, the push on pause and
//! the menu row), and all three handle the reply the same way.
module Progress {

    //! What the reply means for each book that was sent.
    //!
    //! Where the server was ahead, the watch jumps to it. Where the server took
    //! the watch's position, the watch keeps it and stops reporting it. Where
    //! the server refused, a book it has not prepared, an Audiobookshelf that
    //! failed, nothing changes, and the position goes out again next time.
    //!
    //! An adopted position keeps timestamp zero on purpose: a position taken
    //! over from the server is not news to the server. With a real timestamp
    //! the watch would push straight back what it had just been told.
    function settle(sent as Array, data as Dictionary or String or Null) as Void {
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
            var bookId = entry["id"];
            if (!(bookId instanceof String)) {
                continue;
            }
            var resume = entry["resume"];
            if (resume instanceof Dictionary) {
                var segment = resume["segment"];
                if (segment instanceof Number) {
                    Log.code("Progress: server is ahead in segment", segment);
                    Store.rememberPosition(
                        bookId, segment, AbSyncDelegate.numberOf(resume["offset"]), 0
                    );
                }
                continue;
            }
            var accepted = entry["accepted"];
            if (accepted instanceof Boolean && accepted) {
                Store.markSynced(bookId, sentStamp(sent, bookId));
            } else {
                Log.warn("Progress: server refused " + bookId + ", kept for the next push");
            }
        }
    }

    //! The timestamp this book went out with, or 0 if it was not sent.
    function sentStamp(sent as Array, bookId as String) as Number {
        for (var i = 0; i < sent.size(); ++i) {
            var entry = sent[i];
            if (entry instanceof Dictionary && bookId.equals(entry["book_id"])) {
                return AbSyncDelegate.numberOf(entry["ts"]);
            }
        }
        return 0;
    }
}
