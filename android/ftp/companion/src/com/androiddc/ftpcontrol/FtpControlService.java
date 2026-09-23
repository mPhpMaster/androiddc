package com.androiddc.ftpcontrol;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import java.io.OutputStream;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

public final class FtpControlService extends Service {
    private static final String CHANNEL = "ftp_running";
    private static final int NOTIFICATION_ID = 4121;

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) { stopSelf(); return START_NOT_STICKY; }
        if ("stop".equals(intent.getAction())) {
            int port = getPreferences().getInt("control_port", -1);
            String token = getPreferences().getString("stop_token", "");
            if (!token.equals(intent.getStringExtra("stop_token"))) return START_NOT_STICKY;
            new Thread(() -> {
                boolean stopped = false;
                if (port > 0 && token.length() >= 32) {
                    try (Socket socket = new Socket()) {
                        socket.connect(new InetSocketAddress("127.0.0.1", port), 3000);
                        socket.setSoTimeout(3000);
                        OutputStream output = socket.getOutputStream();
                        output.write((token + "\n").getBytes(StandardCharsets.UTF_8));
                        output.flush();
                        BufferedReader reply = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
                        stopped = "STOPPED".equals(reply.readLine());
                    } catch (Exception failure) {
                        android.util.Log.e("AndroidDcFtp", "Could not stop FTP server", failure);
                    }
                }
                if (!stopped) return;
                getPreferences().edit().clear().apply();
                stopForeground(true);
                stopSelf();
            }, "androiddc-ftp-stop").start();
            return START_NOT_STICKY;
        }
        int port = intent.getIntExtra("control_port", -1);
        String token = intent.getStringExtra("stop_token");
        if (port < 1 || port > 65535 || token == null || token.length() < 32) {
            stopSelf();
            return START_NOT_STICKY;
        }
        getPreferences().edit().putInt("control_port", port).putString("stop_token", token).apply();
        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            new NotificationChannel(CHANNEL, "AndroidDC FTP", NotificationManager.IMPORTANCE_LOW));
        Intent stopIntent = new Intent(this, FtpControlService.class).setAction("stop")
            .putExtra("stop_token", token);
        PendingIntent stopAction = PendingIntent.getService(this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder builder = Build.VERSION.SDK_INT >= 26
            ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
        Notification notification = builder.setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("AndroidDC FTP is running")
            .setContentText("Phone storage is shared. Tap Stop to end sharing.")
            .setOngoing(true)
            .addAction(new Notification.Action.Builder(null, "Stop FTP", stopAction).build())
            .build();
        startForeground(NOTIFICATION_ID, notification);
        return START_NOT_STICKY;
    }

    private android.content.SharedPreferences getPreferences() {
        return getSharedPreferences("ftp_control", MODE_PRIVATE);
    }
}
