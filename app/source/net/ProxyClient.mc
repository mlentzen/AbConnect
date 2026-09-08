import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;

//! Aufrufe gegen abconnect-proxy.
//!
//! Die Uhr kennt nur Proxy-URL und Token — der Audiobookshelf-Schlüssel bleibt
//! serverseitig. Antworten sind bewusst schmal gehalten, weil Connect IQ große
//! JSON-Antworten mit -402 beziehungsweise -403 abbricht.
class ProxyClient {

    private var _base as String;
    private var _token as String;

    function initialize() {
        _base = readSetting(Settings.PROXY_URL, BuildDefaults.PROXY_URL);
        _token = readSetting(Settings.PROXY_TOKEN, BuildDefaults.PROXY_TOKEN);
        _base = withoutTrailingSlash(_base);
    }

    //! substring() liefert null, wenn die Grenzen nicht passen — ohne diese
    //! Prüfung stürzt die App an einer URL mit Schrägstrich am Ende ab.
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

    //! Ohne URL und Token hat kein Aufruf Aussicht auf Erfolg.
    function isConfigured() as Boolean {
        return _base.length() > 0 && _token.length() > 0;
    }

    function url(path as String) as String {
        return _base + path;
    }

    private function headers() as Dictionary {
        return { "Authorization" => "Bearer " + _token };
    }

    private function jsonOptions() as Dictionary {
        return {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => headers(),
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
    }

    // --- Bibliothek ----------------------------------------------------------

    function books(page as Number, perPage as Number, callback as Method) as Void {
        Communications.makeWebRequest(
            url("/v1/books"),
            { "page" => page, "per_page" => perPage },
            jsonOptions(),
            callback
        );
    }

    function prepare(bookId as String, callback as Method) as Void {
        Communications.makeWebRequest(
            url("/v1/books/" + bookId + "/prepare"),
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => headers(),
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            callback
        );
    }

    function segments(bookId as String, callback as Method) as Void {
        Communications.makeWebRequest(url("/v1/books/" + bookId + "/segments"), null, jsonOptions(), callback);
    }

    function release(bookId as String, callback as Method) as Void {
        Communications.makeWebRequest(
            url("/v1/books/" + bookId + "/release"),
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => headers(),
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            callback
        );
    }

    // --- Medien --------------------------------------------------------------

    //! Lädt ein Segment in den verschlüsselten Media-Cache der Uhr.
    //! Die Antwort der Callback ist eine Media.ContentRef.
    function downloadSegment(path as String, encoding as String, callback as Method) as Void {
        Communications.makeWebRequest(
            url(path),
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :headers => headers(),
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_AUDIO,
                :mediaEncoding => mediaEncoding(encoding)
            },
            callback
        );
    }

    //! Das Cover läuft über eine vorsignierte URL: makeImageRequest kann keine
    //! Header setzen, und der Token hätte in einem Query-String nichts verloren.
    function downloadCover(signedPath as String, callback as Method) as Void {
        Communications.makeImageRequest(
            url(signedPath),
            null,
            {
                :maxWidth => 200,
                :maxHeight => 200,
                :dithering => Communications.IMAGE_DITHERING_NONE
            },
            callback
        );
    }

    // --- Fortschritt ---------------------------------------------------------

    function pushProgress(entries as Array, callback as Method) as Void {
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

    // --- Hilfen --------------------------------------------------------------

    static function mediaEncoding(encoding as String) as Number {
        if (encoding.equals("mp3")) {
            return Media.ENCODING_MP3;
        }
        return Media.ENCODING_M4A;
    }

    //! Die Telefon-Einstellung sticht die beim Bauen eingebackene Vorgabe.
    //!
    //! Ein leerer Wert zählt dabei wie keiner: Eine sideloadete App bekommt in
    //! Garmin Connect keine Einstellungsmaske, sonst bliebe die Vorgabe
    //! wirkungslos.
    private static function readSetting(key as String, fallback as String) as String {
        var value = Application.Properties.getValue(key);
        if (value instanceof String && value.length() > 0) {
            return value;
        }
        return fallback;
    }
}
