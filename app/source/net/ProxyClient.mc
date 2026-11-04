import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;

//! Calls against abconnect-proxy.
//!
//! The watch only knows the proxy URL and token. The Audiobookshelf key stays
//! server-side. Responses are deliberately kept small, because Connect IQ
//! aborts large JSON responses with -402 or -403.
class ProxyClient {

    private var _base as String;
    private var _token as String;

    function initialize() {
        _base = readSetting(Settings.PROXY_URL, BuildDefaults.PROXY_URL);
        _token = readSetting(Settings.PROXY_TOKEN, BuildDefaults.PROXY_TOKEN);
        _base = withoutTrailingSlash(_base);
        if (_base.length() == 0 || _token.length() == 0) {
            Log.error("Net: proxy not configured");
        } else {
            Log.info("Net: proxy " + _base);
        }
        // Only the length: it tells "no token" from "token present" without
        // giving the token away.
        Log.debugCode("Net: token length", _token.length());
    }

    //! substring() returns null when the bounds do not fit. Without this
    //! check the app crashes on a URL with a trailing slash.
    private static function withoutTrailingSlash(value as String) as String {
        var result = value;
        while (result.length() > 0) {
            var last = result.substring(result.length() - 1, result.length());
            if (last == null || !last.equals("/")) {
                break;
            }
            var shorter = result.substring(0, result.length() - 1);
            if (shorter == null) {
                break;
            }
            result = shorter;
        }
        return result;
    }

    //! Without a URL and token, no call has any chance of success.
    function isConfigured() as Boolean {
        return _base.length() > 0 && _token.length() > 0;
    }

    function url(path as String) as String {
        return _base + path;
    }

    //! Not named `headers`: that collides with makeWebRequest's `:headers`
    //! option key.
    private function authHeaders() as Dictionary {
        return { "Authorization" => "Bearer " + _token };
    }

    //! Logs every outgoing request. The token is never included, because the
    //! log file is readable on the watch.
    private static function trace(verb as String, path as String) as Void {
        Log.info("Net: " + verb + " " + path);
    }

    private function jsonOptions() as Dictionary {
        return {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => authHeaders(),
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
    }

    // --- Library ----------------------------------------------------------

    //! The target: what is in the playlist on the server.
    function playlist(callback as Method) as Void {
        trace("GET", "/v1/playlist");
        Communications.makeWebRequest(url("/v1/playlist"), null, jsonOptions(), callback);
    }

    //! `after` is the index of the last segment already received, -1 for the
    //! first page. The server paginates because a chapter-heavy book does not
    //! fit in one response.
    function segments(bookId as String, after as Number, callback as Method) as Void {
        var path = "/v1/books/" + bookId + "/segments";
        if (after >= 0) {
            path += "?after=" + after.toString();
        }
        trace("GET", path);
        Communications.makeWebRequest(url(path), null, jsonOptions(), callback);
    }

    // --- Media --------------------------------------------------------------

    //! Downloads a segment into the watch's encrypted media cache.
    //! The callback's response is a Media.ContentRef.
    //!
    //! `onBytes` reports the byte count during the transfer. On the watch that
    //! is the only trace by which a slow connection can be told apart from a
    //! stalled one. A segment is several megabytes, and over Bluetooth that
    //! takes minutes to hours.
    function downloadSegment(path as String, callback as Method, onBytes as Method) as Void {
        trace("GET", path);
        Communications.makeWebRequest(
            url(path),
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :headers => authHeaders(),
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_AUDIO,
                :mediaEncoding => Media.ENCODING_MP3,
                :fileDownloadProgressCallback => onBytes
            },
            callback
        );
    }

    // --- Progress ---------------------------------------------------------

    function pushProgress(entries as Array, callback as Method) as Void {
        trace("POST", "/v1/progress");
        Log.debugCode("Net: entries", entries.size());
        Communications.makeWebRequest(
            url("/v1/progress"),
            { "entries" => entries },
            {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => {
                    "Authorization" => "Bearer " + _token,
                    "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON
                },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            callback
        );
    }

    // --- Helpers --------------------------------------------------------------

    //! A saved property overrides the value baked in at build time.
    //! An empty property counts as none, so clearing it restores that default.
    static function readSetting(key as String, fallback as String) as String {
        var value = Application.Properties.getValue(key);
        if (value instanceof String && value.length() > 0) {
            return value;
        }
        return fallback;
    }
}
