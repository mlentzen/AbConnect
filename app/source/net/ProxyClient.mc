import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;

class ProxyClient {

    private var _base as String;
    private var _token as String;

    function initialize() {
        _base = withoutTrailingSlash(readSetting(Settings.PROXY_URL, BuildDefaults.PROXY_URL));
        _token = readSetting(Settings.PROXY_TOKEN, BuildDefaults.PROXY_TOKEN);
        if (isConfigured()) {
            Log.info("Net: proxy " + _base);
        } else {
            Log.error("Net: proxy not configured");
        }
        Log.debugCode("Net: token length", _token.length());
    }

    static function readSetting(key as String, fallback as String) as String {
        var value = Application.Properties.getValue(key);
        if (value instanceof String && value.length() > 0) {
            return value;
        }
        return fallback;
    }

    private static function withoutTrailingSlash(value as String) as String {
        var result = value;
        while (result.length() > 0) {
            var last = result.substring(result.length() - 1, result.length());
            var shorter = result.substring(0, result.length() - 1);
            if (last == null || !last.equals("/") || shorter == null) {
                break;
            }
            result = shorter;
        }
        return result;
    }

    function isConfigured() as Boolean {
        return _base.length() > 0 && _token.length() > 0;
    }

    function playlist(callback as Method) as Void {
        get("/v1/playlist", callback);
    }

    function segments(bookId as String, after as Number, callback as Method) as Void {
        var path = "/v1/books/" + bookId + "/segments";
        if (after >= 0) {
            path += "?after=" + after.toString();
        }
        get(path, callback);
    }

    function downloadSegment(path as String, callback as Method, onBytes as Method) as Void {
        Log.info("Net: GET " + path);
        Communications.makeWebRequest(
            _base + path,
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

    function pushProgress(entries as Array, callback as Method) as Void {
        Log.info("Net: POST /v1/progress");
        Log.debugCode("Net: entries", entries.size());
        var headers = authHeaders();
        headers["Content-Type"] = Communications.REQUEST_CONTENT_TYPE_JSON;
        Communications.makeWebRequest(
            _base + "/v1/progress",
            { "entries" => entries },
            {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => headers,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            callback
        );
    }

    private function get(path as String, callback as Method) as Void {
        Log.info("Net: GET " + path);
        Communications.makeWebRequest(
            _base + path,
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :headers => authHeaders(),
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            callback
        );
    }

    private function authHeaders() as Dictionary {
        return { "Authorization" => "Bearer " + _token };
    }
}
