package com.androiddc;

import android.net.wifi.WifiConfiguration;
import android.os.IBinder;

import java.lang.reflect.Method;
import java.util.List;

/**
 * Prints the SSID and saved password of each Wi-Fi network the phone has kept,
 * launched by adb through app_process; it is not installed as an app.
 *
 * Reading a saved password needs the system permission READ_WIFI_CREDENTIAL,
 * which an installed app cannot be granted (signature|privileged). The adb
 * shell (uid 2000) has it, so this runs as the shell and asks the Wi-Fi
 * service for the privileged network list, which carries preSharedKey.
 *
 * It works on Android 8 to 12 (measured on a Changhong/MediaTek Android TV 11:
 * 23 networks in 1.4 s). From Android 13 the same call returns null to the
 * shell - the Wi-Fi module moved to a Mainline package and this one method no
 * longer counts the shell as privileged - and there is no root-free path. The
 * old reference code called getList() on that null and the process was killed;
 * this prints STATUS UNSUPPORTED instead, so the window can say so plainly.
 *
 * Output, one line each, tab-separated, each line marked so an app_process or
 * linker warning on stderr is never mistaken for a row:
 *   STATUS<TAB>OK | UNSUPPORTED | ERROR<TAB><message>
 *   NET<TAB><ssid><TAB><password>        ("" password for an open network)
 */
public final class WifiPw {
    public static void main(String[] args) {
        try {
            IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                    .getMethod("getService", String.class).invoke(null, "wifi");
            if (binder == null) { done("ERROR", "no wifi service"); return; }
            Object wm = Class.forName("android.net.wifi.IWifiManager$Stub")
                    .getMethod("asInterface", IBinder.class).invoke(null, binder);

            Method method = null;
            for (Method m : wm.getClass().getMethods()) {
                if (m.getName().equals("getPrivilegedConfiguredNetworks")) { method = m; break; }
            }
            if (method == null) { done("ERROR", "getPrivilegedConfiguredNetworks not found"); return; }

            // the signature changed across versions: (String), (String, Bundle),
            // or (String, String, Bundle). The first String is the calling
            // package - the shell's own - and the rest are filled by type.
            Class<?>[] types = method.getParameterTypes();
            Object[] a = new Object[types.length];
            boolean firstString = true;
            for (int i = 0; i < types.length; i++) {
                if (types[i] == String.class && firstString) { a[i] = "com.android.shell"; firstString = false; }
                else if (types[i].getName().equals("android.os.Bundle")) a[i] = Class.forName("android.os.Bundle").newInstance();
                else a[i] = null;
            }

            Object sliced = method.invoke(wm, a);
            // Android 13+: the shell is no longer privileged for this call and
            // it answers null. Nothing to read, and no root-free way to it.
            if (sliced == null) { done("UNSUPPORTED", ""); return; }

            Object listObj = sliced.getClass().getMethod("getList").invoke(sliced);
            if (!(listObj instanceof List)) { done("UNSUPPORTED", ""); return; }
            List<?> list = (List<?>) listObj;

            StringBuilder out = new StringBuilder();
            int shown = 0;
            for (Object o : list) {
                if (!(o instanceof WifiConfiguration)) continue;
                WifiConfiguration c = (WifiConfiguration) o;
                String ssid = strip(c.SSID);
                if (ssid == null || ssid.isEmpty()) continue;
                String pw = c.preSharedKey;
                if (pw == null && c.wepKeys != null && c.wepKeys.length > 0 && c.wepKeys[0] != null) pw = c.wepKeys[0];
                pw = strip(pw);
                if (pw == null) pw = "";               // open network, or none saved
                out.append("NET\t").append(ssid).append('\t').append(pw).append('\n');
                shown++;
            }
            // the list came back but held no readable password anywhere: on
            // some 13+ builds it is there but every key is masked as "*"
            System.out.print("STATUS\tOK\n");
            System.out.print(out);
            if (shown == 0) System.out.print("STATUS\tEMPTY\n");
        } catch (Throwable t) {
            Throwable cause = t.getCause() != null ? t.getCause() : t;
            done("ERROR", cause.getClass().getSimpleName() + ": " + cause.getMessage());
        }
    }

    private static void done(String status, String message) {
        if (message == null || message.isEmpty()) System.out.print("STATUS\t" + status + "\n");
        else System.out.print("STATUS\t" + status + "\t" + message + "\n");
    }

    // the provider wraps an SSID and a key in double quotes; take them off
    private static String strip(String s) {
        if (s != null && s.length() > 1 && s.startsWith("\"") && s.endsWith("\"")) {
            return s.substring(1, s.length() - 1);
        }
        return s;
    }
}
