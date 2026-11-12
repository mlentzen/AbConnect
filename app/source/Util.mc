import Toybox.Lang;
import Toybox.WatchUi;

module Util {

    function text(resource as Lang.ResourceId) as String {
        return WatchUi.loadResource(resource) as String;
    }

    function numberOf(value as Object?) as Number {
        if (value instanceof Number) {
            return value;
        }
        if (value instanceof Float || value instanceof Double) {
            return value.toNumber();
        }
        return 0;
    }

    function stringOr(value as Object?, fallback as String) as String {
        if (value instanceof String && value.length() > 0) {
            return value;
        }
        return fallback;
    }

    function toNumber(value as String) as Number {
        var number = value.toNumber();
        return (number == null) ? 0 : number;
    }

    function split(value as String, separator as String) as Array<String> {
        var parts = [] as Array<String>;
        var rest = value;
        var cut = rest.find(separator);
        while (cut != null) {
            parts.add(rest.substring(0, cut) as String);
            rest = rest.substring(cut + separator.length(), rest.length()) as String;
            cut = rest.find(separator);
        }
        parts.add(rest);
        return parts;
    }
}
