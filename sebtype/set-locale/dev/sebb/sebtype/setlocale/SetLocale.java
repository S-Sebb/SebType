package dev.sebb.sebtype.setlocale;

import android.content.res.Configuration;
import android.os.LocaleList;

/**
 * test-emulator.sh's helper (#103): sets the system locale the way Settings does, with no restart.
 * Run as the shell user, which holds CHANGE_CONFIGURATION:
 * app_process -cp set-locale.dex / dev.sebb.sebtype.setlocale.SetLocale en-US
 */
public class SetLocale {
    public static void main(String[] args) throws Exception {
        Object am = Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null);
        Configuration c = (Configuration) am.getClass().getMethod("getConfiguration").invoke(am);
        c.setLocales(LocaleList.forLanguageTags(args[0]));
        Configuration.class.getField("userSetLocale").setBoolean(c, true);
        am.getClass()
                .getMethod("updatePersistentConfigurationWithAttribution", Configuration.class, String.class, String.class)
                .invoke(am, c, "com.android.shell", null);
    }
}
