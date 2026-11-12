import Toybox.Application;
import Toybox.Lang;
import Toybox.Media;
import Toybox.WatchUi;

const URL_ITEM = :proxyUrlSetting;
const TOKEN_ITEM = :proxyTokenSetting;
const RESET_ITEM = :resetAll;
const PLUGGED_IN_ITEM = :syncOnPluggedInSetting;

class SettingsMenu extends WatchUi.Menu2 {

    function initialize() {
        Menu2.initialize({ :title => Rez.Strings.menuSettings });
        addItem(textItem($.URL_ITEM));
        addItem(textItem($.TOKEN_ITEM));
        addItem(new WatchUi.ToggleMenuItem(
            Util.text(Rez.Strings.settingSyncOnPluggedInTitle),
            {
                :enabled => Util.text(Rez.Strings.settingOn),
                :disabled => Util.text(Rez.Strings.settingOff)
            },
            $.PLUGGED_IN_ITEM,
            Settings.syncOnPluggedIn(),
            null
        ));
        addItem(new WatchUi.MenuItem(
            Util.text(Rez.Strings.resetAll),
            (Media.getCacheStatistics().size / 1048576).toString() + " MB",
            $.RESET_ITEM,
            null
        ));
    }

    function refresh(id as Symbol) as Void {
        updateItem(textItem(id), findItemById(id));
    }

    static function settingKey(id as Symbol) as String {
        return (id == $.TOKEN_ITEM) ? Settings.PROXY_TOKEN : Settings.PROXY_URL;
    }

    static function settingValue(id as Symbol) as String {
        if (id == $.TOKEN_ITEM) {
            return ProxyClient.readSetting(Settings.PROXY_TOKEN, BuildDefaults.PROXY_TOKEN);
        }
        return ProxyClient.readSetting(Settings.PROXY_URL, BuildDefaults.PROXY_URL);
    }

    private function textItem(id as Symbol) as WatchUi.MenuItem {
        var isToken = id == $.TOKEN_ITEM;
        var value = settingValue(id);
        var subtitle = value;
        if (value.length() == 0) {
            subtitle = Util.text(Rez.Strings.settingNotSet);
        } else if (isToken) {
            subtitle = "••••";
        }
        var label = isToken ? Rez.Strings.settingProxyTokenTitle : Rez.Strings.settingProxyUrlTitle;
        return new WatchUi.MenuItem(Util.text(label), subtitle, id, null);
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
        if (id == $.PLUGGED_IN_ITEM && item instanceof WatchUi.ToggleMenuItem) {
            Application.Properties.setValue(Settings.SYNC_ON_PLUGGED_IN, item.isEnabled());
            Log.info("Settings: sync on plugged in " + item.isEnabled().toString());
        } else if (id == $.RESET_ITEM) {
            Log.info("Settings: asking about reset");
            WatchUi.pushView(
                new WatchUi.Confirmation(Util.text(Rez.Strings.resetConfirm)),
                new ResetConfirmationDelegate(),
                WatchUi.SLIDE_IMMEDIATE
            );
        } else if (id == $.URL_ITEM || id == $.TOKEN_ITEM) {
            id = id as Symbol;
            Log.info("Settings: edit " + SettingsMenu.settingKey(id));
            WatchUi.pushView(
                new WatchUi.TextPicker(SettingsMenu.settingValue(id)),
                new SettingEditDelegate(_menu, id),
                WatchUi.SLIDE_IMMEDIATE
            );
        }
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}

class SettingEditDelegate extends WatchUi.TextPickerDelegate {

    private const MAX_LENGTH = 120;

    private var _menu as SettingsMenu;
    private var _id as Symbol;

    function initialize(menu as SettingsMenu, id as Symbol) {
        TextPickerDelegate.initialize();
        _menu = menu;
        _id = id;
    }

    function onTextEntered(text as String, changed as Boolean) as Boolean {
        if (!changed) {
            return true;
        }
        var value = text;
        if (value.length() > MAX_LENGTH) {
            var cut = value.substring(0, MAX_LENGTH);
            if (cut != null) {
                value = cut;
            }
        }
        var key = SettingsMenu.settingKey(_id);
        Application.Properties.setValue(key, value);
        Log.info("Settings: saved " + key);
        _menu.refresh(_id);
        return true;
    }

    function onCancel() as Boolean {
        return true;
    }
}
