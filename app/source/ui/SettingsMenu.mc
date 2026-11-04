import Toybox.Application;
import Toybox.Lang;
import Toybox.Media;
import Toybox.WatchUi;

const URL_ITEM = :proxyUrlSetting;
const TOKEN_ITEM = :proxyTokenSetting;
const RESET_ITEM = :resetAll;

//! URL and token. A side-loaded app has no settings page in Garmin Connect,
//! so they are edited here and stored as application properties.
class SettingsMenu extends WatchUi.Menu2 {

    function initialize() {
        Menu2.initialize({ :title => Rez.Strings.menuSettings });
        addItem(item($.URL_ITEM, Rez.Strings.settingProxyUrlTitle, urlValue()));
        addItem(item($.TOKEN_ITEM, Rez.Strings.settingProxyTokenTitle, tokenValue()));
        var stats = Media.getCacheStatistics();
        addItem(new WatchUi.MenuItem(
            WatchUi.loadResource(Rez.Strings.resetAll) as String,
            (stats.size / 1048576).toString() + " MB",
            $.RESET_ITEM,
            null
        ));
    }

    function refresh(index as Number) as Void {
        if (index == 0) {
            updateItem(item($.URL_ITEM, Rez.Strings.settingProxyUrlTitle, urlValue()), index);
        } else {
            updateItem(item($.TOKEN_ITEM, Rez.Strings.settingProxyTokenTitle, tokenValue()), index);
        }
    }

    private function item(id as Symbol, label as Lang.ResourceId, value as String) as WatchUi.MenuItem {
        var subtitle = value;
        if (subtitle.length() == 0) {
            subtitle = WatchUi.loadResource(Rez.Strings.settingNotSet) as String;
        }
        return new WatchUi.MenuItem(
            WatchUi.loadResource(label) as String,
            subtitle,
            id,
            null
        );
    }

    private function urlValue() as String {
        return ProxyClient.readSetting(Settings.PROXY_URL, BuildDefaults.PROXY_URL);
    }

    //! The token is never shown in the list. The picker still opens the real value.
    private function tokenValue() as String {
        var token = ProxyClient.readSetting(Settings.PROXY_TOKEN, BuildDefaults.PROXY_TOKEN);
        if (token.length() == 0) {
            return "";
        }
        return "••••";
    }
}

class SettingsMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _menu as SettingsMenu;

    function initialize(menu as SettingsMenu) {
        Menu2InputDelegate.initialize();
        _menu = menu;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == $.RESET_ITEM) {
            Log.info("Settings: asking about reset");
            WatchUi.pushView(
                new WatchUi.Confirmation(WatchUi.loadResource(Rez.Strings.resetConfirm) as String),
                new ResetConfirmationDelegate(),
                WatchUi.SLIDE_IMMEDIATE
            );
            return;
        }
        var key = Settings.PROXY_URL;
        var current = ProxyClient.readSetting(key, BuildDefaults.PROXY_URL);
        var index = 0;
        if (id == $.TOKEN_ITEM) {
            key = Settings.PROXY_TOKEN;
            current = ProxyClient.readSetting(key, BuildDefaults.PROXY_TOKEN);
            index = 1;
        } else if (id != $.URL_ITEM) {
            return;
        }
        Log.info("Settings: edit " + key);
        WatchUi.pushView(
            new WatchUi.TextPicker(current),
            new SettingEditDelegate(_menu, index, key),
            WatchUi.SLIDE_IMMEDIATE
        );
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}

class SettingEditDelegate extends WatchUi.TextPickerDelegate {

    private var _menu as SettingsMenu;
    private var _index as Number;
    private var _key as String;

    function initialize(menu as SettingsMenu, index as Number, key as String) {
        TextPickerDelegate.initialize();
        _menu = menu;
        _index = index;
        _key = key;
    }

    function onTextEntered(text as String, changed as Boolean) as Boolean {
        if (!changed) {
            return true;
        }
        var value = text;
        if (value.length() > 120) {
            var cut = value.substring(0, 120);
            if (cut != null) {
                value = cut;
            }
        }
        Application.Properties.setValue(_key, value);
        Log.info("Settings: saved " + _key);
        _menu.refresh(_index);
        return true;
    }

    function onCancel() as Boolean {
        return true;
    }
}
