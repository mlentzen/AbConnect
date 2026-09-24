import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;

//! Calls against abconnect-proxy.
//!
//! The watch only knows the proxy URL and token — the Audiobookshelf key stays
//! server-side. Responses are deliberately kept small, because Connect IQ
//! aborts large JSON responses with -402 or -403.
class ProxyClient {

    private var _base as String;
    private var _token as String;

    function initialize() {
        _base = readSetting(Keys.CFG_URL, Settings.PROXY_URL, BuildDefaults.PROXY_URL);
        _token = readSetting(Keys.CFG_TOKEN, Settings.PROXY_TOKEN, BuildDefaults.PROXY_TOKEN);
        _base = withoutTrailingSlash(_base);
        if (_base.length() == 0 || _token.length() == 0) {
            // Nothing this client is asked to do can work. Said once, at the
            // level a silent build still prints.
            Log.error("Net: proxy not configured");
        } else {
            Log.info("Net: proxy " + _base);
        }
        // Only the length: it tells "no token" from "token present" without
        // giving the token away.
        Log.debugCode("Net: token length", _token.length());
    }

    //! substring() returns null when the bounds do not fit — without this
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

    //! Pairing needs the address, not the token.
    function hasUrl() as Boolean {
        return _base.length() > 0;
    }

    function hasToken() as Boolean {
        return _token.length() > 0;
    }

    //! The address without its scheme, short enough for a watch face.
    function host() as String {
        var index = _base.find("://");
        if (index == null) {
            return _base;
        }
        var rest = _base.substring(index + 3, _base.length());
        return (rest == null) ? _base : rest;
    }

    function url(path as String) as String {
        return _base + path;
    }

    //! Do not name it `headers`: the name collides with makeWebRequest's
    //! `:headers` option key. The compiler then reads the symbol as an
    //! indirect reference to this private method and warns that it cannot find
    //! it at runtime — in the worst case the request goes out without an
    //! Authorization header.
    private function authHeaders() as Dictionary {
        return { "Authorization" => "Bearer " + _token };
    }

    //! Every outgoing request once in the trace.
    //!
    //! Without it the log holds only the response — and for a response that
    //! never comes, nothing at all. The token is never included: the log file
    //! sits in the open on the watch and travels on while debugging.
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
    //! first page. A chapter-heavy book does not fit in one response — see
    //! the module comment — so the server paginates and this passes the
    //! cursor it hands back straight through.
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
    //! stalled one — a segment is several megabytes, and over Bluetooth that
    //! takes minutes to hours.
    function downloadSegment(
        path as String, encoding as String, callback as Method, onBytes as Method
    ) as Void {
        trace("GET", path + " (" + encoding + ")");
        Communications.makeWebRequest(
            url(path),
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :headers => authHeaders(),
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_AUDIO,
                :mediaEncoding => mediaEncoding(encoding),
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

    // --- Setup --------------------------------------------------------------

    //! Whether URL and token work: 200 is healthy, 503 reachable but unhappy
    //! (ABS or ffmpeg), 401 a wrong token.
    function status(callback as Method) as Void {
        trace("GET", "/v1/status");
        Communications.makeWebRequest(url("/v1/status"), null, jsonOptions(), callback);
    }

    //! Asks for a pairing code. No token: this is how the watch gets one.
    function pairStart(callback as Method) as Void {
        trace("POST", "/pair/start");
        Communications.makeWebRequest(
            url("/pair/start"),
            {},
            {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => { "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            callback
        );
    }

    //! 202 while the phone has not answered, 200 with the token once it has.
    function pairPoll(code as String, callback as Method) as Void {
        Communications.makeWebRequest(
            url("/pair/" + code),
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            callback
        );
    }

    // --- Helpers --------------------------------------------------------------

    static function mediaEncoding(encoding as String) as Number {
        if (encoding.equals("mp3")) {
            return Media.ENCODING_MP3;
        }
        return Media.ENCODING_M4A;
    }

    //! What was entered on the watch, then the phone setting, then the default
    //! baked in at build time.
    //!
    //! An empty value counts as none here: a side-loaded app gets no settings
    //! screen in Garmin Connect, otherwise the default would have no effect.
    private static function readSetting(storeKey as String, key as String, fallback as String) as String {
        var local = Store.configValue(storeKey);
        if (local != null) {
            return local;
        }
        var value = Application.Properties.getValue(key);
        if (value instanceof String && value.length() > 0) {
            return value;
        }
        return fallback;
    }
}
