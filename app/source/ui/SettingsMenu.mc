import Toybox.Lang;
import Toybox.WatchUi;

const SETTING_URL_ITEM = :settingUrl;
const SETTING_PAIR_ITEM = :settingPair;
const SETTING_TOKEN_ITEM = :settingToken;
const SETTING_TEST_ITEM = :settingTest;
const SETTING_AUTO_SYNC_ITEM = :settingAutoSync;

//! Connection and sync settings, on the watch.
//!
//! A side-loaded app gets no settings page in Garmin Connect, so this is where
//! the proxy URL and token get in when the build did not bring them. The URL is
//! short enough for the watch keyboard; the token is not, so it normally
//! arrives by pairing: typed on the phone, collected by the watch.
//!
//! What is entered here lands in the Object Store and wins over the phone
//! settings and the build defaults — see ProxyClient.readSetting().
class SettingsMenu extends WatchUi.Menu2 {

    function initialize() {
        Menu2.initialize({ :title => Rez.Strings.menuSettings });
        addItem(new WatchUi.MenuItem(text(Rez.Strings.settingUrl), null, $.SETTING_URL_ITEM, null));
        addItem(new WatchUi.MenuItem(text(Rez.Strings.settingPair), null, $.SETTING_PAIR_ITEM, null));
        addItem(new WatchUi.MenuItem(text(Rez.Strings.settingToken), null, $.SETTING_TOKEN_ITEM, null));
        addItem(new WatchUi.MenuItem(text(Rez.Strings.settingTest), null, $.SETTING_TEST_ITEM, null));
        addItem(new WatchUi.ToggleMenuItem(
            text(Rez.Strings.settingAutoSync), null, $.SETTING_AUTO_SYNC_ITEM, Store.autoSync(), null
        ));
    }

    //! Back from a text picker or a pairing: the subtitles say what is set now.
    function onShow() as Void {
        Menu2.onShow();
        Idle.poke();
        var client = new ProxyClient();
        setSub($.SETTING_URL_ITEM, client.hasUrl() ? client.host() : text(Rez.Strings.notSet));
        setSub($.SETTING_TOKEN_ITEM, client.hasToken() ? text(Rez.Strings.isSet) : text(Rez.Strings.notSet));
    }

    private function setSub(id as Symbol, value as String) as Void {
        var index = findItemById(id);
        if (index < 0) {
            return;
        }
        var item = getItem(index);
        if (item != null) {
            item.setSubLabel(value);
            updateItem(item, index);
        }
    }

    static function text(id as Lang.ResourceId) as String {
        return WatchUi.loadResource(id) as String;
    }
}

class SettingsMenuDelegate extends WatchUi.Menu2InputDelegate {

    //! Held: the connection test outlives the press.
    private var _client as ProxyClient?;
    private var _loading as MessageView?;

    function initialize() {
        Menu2InputDelegate.initialize();
        _client = null;
        _loading = null;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        Idle.poke();
        var id = item.getId();

        if (id == $.SETTING_URL_ITEM) {
            var client = new ProxyClient();
            editText(client.hasUrl() ? client.url("") : "https://", Keys.CFG_URL);
            return;
        }
        if (id == $.SETTING_TOKEN_ITEM) {
            editText("", Keys.CFG_TOKEN);
            return;
        }
        if (id == $.SETTING_PAIR_ITEM) {
            if (!new ProxyClient().hasUrl()) {
                show(Rez.Strings.pairNeedsUrl);
                return;
            }
            WatchUi.pushView(new PairView(), new BackDelegate(), WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        if (id == $.SETTING_TEST_ITEM) {
            testConnection();
            return;
        }
        if (id == $.SETTING_AUTO_SYNC_ITEM && item instanceof WatchUi.ToggleMenuItem) {
            Store.setAutoSync(item.isEnabled());
            Log.info("Settings: auto sync " + item.isEnabled().toString());
        }
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }

    //! The watch keyboard. Not every device has one; those that do not are
    //! left with pairing (for the token) and the build defaults (for the URL).
    private function editText(initial as String, key as String) as Void {
        if (!(WatchUi has :TextPicker)) {
            show(Rez.Strings.noTextInput);
            return;
        }
        // The keys typed in the picker never reach a delegate of ours.
        Idle.hold();
        WatchUi.pushView(new WatchUi.TextPicker(initial), new SettingTextDelegate(key), WatchUi.SLIDE_IMMEDIATE);
    }

    private function testConnection() as Void {
        var client = new ProxyClient();
        if (!client.isConfigured()) {
            show(Rez.Strings.notConfigured);
            return;
        }
        _client = client;
        var loading = new MessageView(SettingsMenu.text(Rez.Strings.loading));
        _loading = loading;
        Idle.hold();
        WatchUi.pushView(loading, new BackDelegate(), WatchUi.SLIDE_IMMEDIATE);
        client.status(method(:onStatus));
    }

    function onStatus(code as Number, data as Dictionary or String or Null) as Void {
        Log.response("Settings: status", code);
        Idle.release();
        _client = null;
        var text = describeStatus(code);
        var result = new MessageView(text);
        result.closeAfter(3000);
        var loading = _loading;
        _loading = null;
        if (loading != null && loading.isShown()) {
            WatchUi.switchToView(result, new BackDelegate(), WatchUi.SLIDE_IMMEDIATE);
        } else {
            WatchUi.pushView(result, new BackDelegate(), WatchUi.SLIDE_IMMEDIATE);
        }
    }

    //! Also used by the pairing, which ends with the same check.
    static function describeStatus(code as Number) as String {
        if (code == 200) {
            return SettingsMenu.text(Rez.Strings.connectionOk);
        }
        if (code == 401 || code == 403) {
            return SettingsMenu.text(Rez.Strings.tokenInvalid);
        }
        if (code == 503) {
            // Reachable and the token is fine; ABS or ffmpeg is not.
            return SettingsMenu.text(Rez.Strings.serverUnhealthy);
        }
        return "HTTP " + code.toString();
    }

    private function show(id as Lang.ResourceId) as Void {
        var view = new MessageView(SettingsMenu.text(id));
        view.closeAfter(3000);
        WatchUi.pushView(view, new BackDelegate(), WatchUi.SLIDE_IMMEDIATE);
    }
}

//! Stores what the watch keyboard produced.
class SettingTextDelegate extends WatchUi.TextPickerDelegate {

    private var _key as String;

    function initialize(key as String) {
        TextPickerDelegate.initialize();
        _key = key;
    }

    function onTextEntered(text as String, changed as Boolean) as Boolean {
        Idle.release();
        var value = trimmed(text);
        // A bare host is what a thumb types; the proxy only speaks HTTPS.
        if (_key.equals(Keys.CFG_URL) && value.length() > 0 && value.find("://") == null) {
            value = "https://" + value;
        }
        if (_key.equals(Keys.CFG_URL) && value.equals("https://")) {
            value = "";
        }
        Store.setConfigValue(_key, value);
        Log.info("Settings: " + _key + " set, length " + value.length().toString());
        return true;
    }

    function onCancel() as Boolean {
        Idle.release();
        return true;
    }

    private static function trimmed(text as String) as String {
        var chars = text.toCharArray();
        var start = 0;
        var end = chars.size();
        while (start < end && chars[start] == ' ') {
            start += 1;
        }
        while (end > start && chars[end - 1] == ' ') {
            end -= 1;
        }
        var result = text.substring(start, end);
        return (result == null) ? "" : result;
    }
}
