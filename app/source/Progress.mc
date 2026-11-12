import Toybox.Lang;

module Progress {

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
            var accepted = entry["accepted"];
            if (resume instanceof Dictionary) {
                adoptServerPosition(sent, bookId, resume);
            } else if (accepted instanceof Boolean && accepted) {
                Store.markSynced(bookId, sentStamp(sent, bookId));
            } else {
                Log.warn("Progress: server refused " + bookId + ", kept for the next push");
            }
        }
    }

    function adoptServerPosition(sent as Array, bookId as String, resume as Dictionary) as Void {
        var segment = resume["segment"];
        if (!(segment instanceof Number)) {
            return;
        }
        var local = Store.position(bookId);
        if (local != null && local[2] != sentStamp(sent, bookId)) {
            Log.warn("Progress: kept newer local position for " + bookId);
            return;
        }
        Log.code("Progress: server is ahead in segment", segment);
        Store.rememberPosition(bookId, segment, Util.numberOf(resume["offset"]), 0);
    }

    function sentStamp(sent as Array, bookId as String) as Number {
        for (var i = 0; i < sent.size(); ++i) {
            var entry = sent[i];
            if (entry instanceof Dictionary && bookId.equals(entry["book_id"])) {
                return Util.numberOf(entry["ts"]);
            }
        }
        return 0;
    }
}
