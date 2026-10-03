package com.androiddc;

import android.content.ContentProviderOperation;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Build;
import android.os.IBinder;
import android.os.Process;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;

/**
 * Puts a backup's call log, messages or contacts back on a phone, launched by
 * adb through app_process; it is not installed as an app.
 *
 * The phone's own "content" command does the same one row at a time, and it
 * is a shell script that starts a whole Java runtime for every row: about
 * 1.5 s each, which is hours for a phone's call log. This is one runtime for
 * the whole file, talking to the provider the way "content" does.
 *
 * Anything the phone already has (same number, same time, same kind; for a
 * contact the same name and number) is left alone, so running it twice adds
 * nothing the second time.
 *
 * Usage: RestoreWriter calls|messages|contacts file.json [userId]
 * Prints TOTAL n, then ADDED n as it goes, then DONE added skipped.
 */
public final class RestoreWriter {
    private static final String SHELL = "com.android.shell";
    private static final int BATCH = 250;

    private final Object provider;
    private final Object attribution;

    private RestoreWriter(Object provider) {
        this.provider = provider;
        this.attribution = Build.VERSION.SDK_INT >= 31
                ? new android.content.AttributionSource.Builder(Process.myUid()).setPackageName(SHELL).build()
                : null;
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 2) throw new IllegalArgumentException("usage: RestoreWriter calls|messages|contacts file.json [userId]");
        String kind = args[0];
        JSONArray rows = readJson(new File(args[1]));
        int user = args.length > 2 ? Integer.parseInt(args[2]) : 0;
        String authority;
        if ("calls".equals(kind)) authority = "call_log";
        else if ("messages".equals(kind)) authority = "sms";
        else if ("contacts".equals(kind)) authority = "com.android.contacts";
        else throw new IllegalArgumentException("unknown kind: " + kind);

        Object manager = Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null);
        IBinder token = new Binder();
        Object holder = invokeByName(manager, "getContentProviderExternal", authority, user, token, "androiddc-restore");
        if (holder == null) throw new IllegalStateException("no provider for " + authority);
        Object provider = holder.getClass().getField("provider").get(holder);
        try {
            RestoreWriter writer = new RestoreWriter(provider);
            System.out.println("TOTAL " + rows.length());
            if ("calls".equals(kind)) writer.calls(rows);
            else if ("messages".equals(kind)) writer.messages(rows);
            else writer.contacts(rows);
        } finally {
            try { invokeByName(manager, "removeContentProviderExternalAsUser", authority, token, user); }
            catch (Throwable ignored) {
                try { invokeByName(manager, "removeContentProviderExternal", authority, token); } catch (Throwable alsoIgnored) { }
            }
        }
    }

    private void calls(JSONArray rows) throws Exception {
        Uri uri = Uri.parse("content://call_log/calls");
        Set<String> have = keys(uri, new String[] { "number", "date", "type" });
        ArrayList<ContentValues> batch = new ArrayList<>();
        int added = 0, skipped = 0;
        for (int i = 0; i < rows.length(); i++) {
            JSONObject row = rows.getJSONObject(i);
            String number = row.optString("Number", "");
            long when = parseLong(row.optString("When", "0"));
            int type = (int) parseLong(row.optString("Kind", "1"));
            if (!have.add(number + "|" + when + "|" + type)) { skipped++; continue; }
            ContentValues values = new ContentValues();
            values.put("number", number);
            values.put("date", when);
            values.put("duration", parseLong(row.optString("Seconds", "0")));
            values.put("type", type);
            // read and not new: a call from last year must not ring a missed-call notice
            values.put("new", 0);
            values.put("is_read", 1);
            batch.add(values);
            if (batch.size() >= BATCH) { added += flush(uri, batch); System.out.println("ADDED " + added); }
        }
        added += flush(uri, batch);
        System.out.println("DONE " + added + " " + skipped);
    }

    private void messages(JSONArray rows) throws Exception {
        Uri uri = Uri.parse("content://sms");
        Set<String> have = keys(uri, new String[] { "address", "date", "type" });
        ArrayList<ContentValues> batch = new ArrayList<>();
        int added = 0, skipped = 0;
        for (int i = 0; i < rows.length(); i++) {
            JSONObject row = rows.getJSONObject(i);
            String address = row.optString("Number", "");
            long when = parseLong(row.optString("When", "0"));
            int type = (int) parseLong(row.optString("Kind", "1"));
            if (!have.add(address + "|" + when + "|" + type)) { skipped++; continue; }
            ContentValues values = new ContentValues();
            values.put("address", address);
            values.put("date", when);
            values.put("type", type);
            values.put("body", row.optString("Text", ""));
            values.put("read", 1);
            values.put("seen", 1);
            batch.add(values);
            if (batch.size() >= BATCH) { added += flush(uri, batch); System.out.println("ADDED " + added); }
        }
        added += flush(uri, batch);
        System.out.println("DONE " + added + " " + skipped);
    }

    private void contacts(JSONArray rows) throws Exception {
        Uri raw = Uri.parse("content://com.android.contacts/raw_contacts");
        Uri data = Uri.parse("content://com.android.contacts/data");
        Set<String> have = new HashSet<>();
        Cursor cursor = query(Uri.parse("content://com.android.contacts/data/phones"), new String[] { "display_name", "data1" });
        if (cursor != null) {
            try { while (cursor.moveToNext()) have.add(contactKey(cursor.getString(0), cursor.getString(1))); }
            finally { cursor.close(); }
        }
        ArrayList<ContentProviderOperation> ops = new ArrayList<>();
        int added = 0, skipped = 0, waiting = 0;
        for (int i = 0; i < rows.length(); i++) {
            JSONObject row = rows.getJSONObject(i);
            String name = row.optString("Name", "");
            String number = row.optString("Number", "");
            if (number.trim().isEmpty() || !have.add(contactKey(name, number))) { skipped++; continue; }
            int back = ops.size();
            ops.add(ContentProviderOperation.newInsert(raw)
                    .withValue("account_type", null).withValue("account_name", null).build());
            if (!name.trim().isEmpty()) {
                ops.add(ContentProviderOperation.newInsert(data).withValueBackReference("raw_contact_id", back)
                        .withValue("mimetype", "vnd.android.cursor.item/name").withValue("data1", name).build());
            }
            ops.add(ContentProviderOperation.newInsert(data).withValueBackReference("raw_contact_id", back)
                    .withValue("mimetype", "vnd.android.cursor.item/phone_v2").withValue("data1", number)
                    .withValue("data2", 2).build());
            waiting++;
            // the provider refuses a batch of more than 500 operations
            if (ops.size() >= 450) { added += apply(ops, waiting); waiting = 0; System.out.println("ADDED " + added); }
        }
        added += apply(ops, waiting);
        System.out.println("DONE " + added + " " + skipped);
    }

    private static String contactKey(String name, String number) {
        String digits = number == null ? "" : number.replaceAll("[^0-9+]", "");
        return (name == null ? "" : name.trim().toLowerCase()) + "|" + digits;
    }

    private Set<String> keys(Uri uri, String[] columns) throws Exception {
        Set<String> have = new HashSet<>();
        Cursor cursor = query(uri, columns);
        if (cursor == null) return have;
        try {
            while (cursor.moveToNext()) have.add(cursor.getString(0) + "|" + cursor.getLong(1) + "|" + cursor.getInt(2));
        } finally { cursor.close(); }
        return have;
    }

    private int flush(Uri uri, ArrayList<ContentValues> batch) throws Exception {
        if (batch.isEmpty()) return 0;
        Object done = call("bulkInsert", uri, batch.toArray(new ContentValues[0]));
        batch.clear();
        return done instanceof Integer ? (Integer) done : 0;
    }

    private int apply(ArrayList<ContentProviderOperation> ops, int contacts) throws Exception {
        if (ops.isEmpty()) return 0;
        call("applyBatch", "com.android.contacts", new ArrayList<>(ops));
        ops.clear();
        return contacts;
    }

    private Cursor query(Uri uri, String[] projection) throws Exception {
        return (Cursor) call("query", uri, projection);
    }

    /**
     * Calls an IContentProvider method whatever this Android version's
     * signature is: the caller's identity, a Uri, a projection, values, an
     * authority string - each argument is placed by its type, and the rest
     * are null. The newest signature (with AttributionSource) is preferred.
     */
    private Object call(String name, Object... given) throws Exception {
        Method best = null;
        for (Method m : provider.getClass().getMethods()) {
            if (!m.getName().equals(name)) continue;
            if (best == null || score(m) > score(best)) best = m;
        }
        if (best == null) throw new NoSuchMethodException(name);
        Class<?>[] types = best.getParameterTypes();
        Object[] args = new Object[types.length];
        int strings = 0;
        int lastString = -1;
        for (int i = 0; i < types.length; i++) if (types[i] == String.class) lastString = i;
        String authority = null;
        for (Object g : given) if (g instanceof String) authority = (String) g;
        for (int i = 0; i < types.length; i++) {
            Class<?> t = types[i];
            if (t.getName().equals("android.content.AttributionSource")) args[i] = attribution;
            else if (t == String.class) {
                // the authority is the last String; the first one, before it, is the calling package
                if (authority != null && i == lastString) args[i] = authority;
                else args[i] = strings++ == 0 ? SHELL : null;
            } else if (t == int.class) args[i] = 0;
            else if (t == boolean.class) args[i] = false;
            else {
                for (Object g : given) if (g != null && !(g instanceof String) && t.isInstance(g)) { args[i] = g; break; }
            }
        }
        return best.invoke(provider, args);
    }

    private static int score(Method m) {
        int s = m.getParameterTypes().length;
        for (Class<?> t : m.getParameterTypes()) if (t.getName().equals("android.content.AttributionSource")) s += 100;
        return s;
    }

    private static Object invokeByName(Object target, String name, Object... args) throws Exception {
        for (Method m : target.getClass().getMethods()) {
            if (!m.getName().equals(name)) continue;
            Class<?>[] types = m.getParameterTypes();
            if (types.length == args.length) return m.invoke(target, args);
            if (types.length == args.length - 1) {
                Object[] fewer = new Object[types.length];
                System.arraycopy(args, 0, fewer, 0, fewer.length);
                return m.invoke(target, fewer);
            }
        }
        throw new NoSuchMethodException(name);
    }

    private static long parseLong(String text) {
        try { return Long.parseLong(text.trim()); } catch (NumberFormatException e) { return 0; }
    }

    private static JSONArray readJson(File file) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (InputStream in = new FileInputStream(file)) {
            byte[] buffer = new byte[65536];
            int n;
            while ((n = in.read(buffer)) > 0) bytes.write(buffer, 0, n);
        }
        String text = new String(bytes.toByteArray(), StandardCharsets.UTF_8);
        if (text.startsWith("\uFEFF")) text = text.substring(1);
        text = text.trim();
        // one row written by PowerShell is an object, not a list of one
        if (text.startsWith("{")) text = "[" + text + "]";
        return text.isEmpty() ? new JSONArray() : new JSONArray(text);
    }
}
