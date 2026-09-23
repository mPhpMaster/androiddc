package com.androiddc;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.*;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** A small FTP server launched by adb/app_process; it is not installed as an app. */
public final class RawFtpServer {
    private final File root;
    private final int port;
    private final FtpCredentials credentials;
    private final ExecutorService clients = Executors.newCachedThreadPool();

    private RawFtpServer(File root, int port, FtpCredentials credentials) throws IOException {
        this.root = root.getCanonicalFile();
        this.port = port;
        this.credentials = credentials;
        if (!this.root.isDirectory()) throw new IOException("FTP root is not a directory: " + root);
    }

    public static void main(String[] args) throws Exception {
        File root = new File(args.length > 0 ? args[0] : "/sdcard");
        int port = args.length > 1 ? Integer.parseInt(args[1]) : 2121;
        if (args.length < 3) throw new IOException("Credentials file is required");
        new RawFtpServer(root, port, FtpCredentials.load(new File(args[2]))).run();
    }

    private void run() throws IOException {
        try (ServerSocket server = new ServerSocket()) {
            server.setReuseAddress(true);
            server.bind(new InetSocketAddress("0.0.0.0", port));
            System.out.println("READY ftp://" + lanAddress() + ":" + port + "/ root=" + root);
            System.out.flush();
            while (true) {
                Socket socket = server.accept();
                clients.execute(() -> handle(socket));
            }
        }
    }

    private void handle(Socket control) {
        ServerSocket passive = null;
        File cwd = root;
        long restartAt = 0;
        boolean authenticated = false;
        boolean validUser = false;
        int failures = 0;
        try (Socket socket = control;
             BufferedReader in = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
             BufferedWriter out = new BufferedWriter(new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.UTF_8))) {
            socket.setSoTimeout(300000);
            reply(out, 220, "AndroidDC raw FTP ready");
            String line;
            while ((line = in.readLine()) != null) {
                String command;
                String arg;
                int space = line.indexOf(' ');
                if (space < 0) { command = line.toUpperCase(Locale.ROOT); arg = ""; }
                else { command = line.substring(0, space).toUpperCase(Locale.ROOT); arg = line.substring(space + 1); }
                try {
                    if (command.equals("USER")) {
                        authenticated = false;
                        validUser = credentials.matchesUser(arg);
                        reply(out, 331, "Password required");
                        continue;
                    }
                    if (command.equals("PASS")) {
                        authenticated = validUser && credentials.matchesPassword(arg);
                        validUser = false;
                        if (authenticated) {
                            failures = 0;
                            reply(out, 230, "Logged in");
                            System.out.println("SESSION AUTHENTICATED");
                        }
                        else {
                            reply(out, 530, "Invalid username or password");
                            if (++failures >= 5) return;
                        }
                        continue;
                    }
                    if (!authenticated && !command.equals("SYST") && !command.equals("FEAT") &&
                            !command.equals("OPTS") && !command.equals("CLNT") && !command.equals("QUIT")) {
                        reply(out, 530, "Please log in");
                        continue;
                    }
                    switch (command) {
                        case "SYST": reply(out, 215, "UNIX Type: L8"); break;
                        case "FEAT":
                            out.write("211-Features\r\n UTF8\r\n EPSV\r\n SIZE\r\n MDTM\r\n211 End\r\n"); out.flush(); break;
                        case "OPTS": case "CLNT": reply(out, 200, "OK"); break;
                        case "TYPE": reply(out, 200, "Type set"); break;
                        case "NOOP": reply(out, 200, "OK"); break;
                        case "PWD": reply(out, 257, "\"" + virtualPath(cwd) + "\""); break;
                        case "CWD":
                            File next = resolve(cwd, arg);
                            if (!next.isDirectory()) reply(out, 550, "Not a directory");
                            else { cwd = next; reply(out, 250, "Directory changed"); }
                            break;
                        case "CDUP": cwd = resolve(cwd, ".."); reply(out, 250, "Directory changed"); break;
                        case "PASV":
                            close(passive); passive = new ServerSocket(0, 1);
                            byte[] ip = InetAddress.getByName(lanAddress()).getAddress();
                            int p = passive.getLocalPort();
                            reply(out, 227, "Entering Passive Mode (" + (ip[0]&255) + "," + (ip[1]&255) + "," + (ip[2]&255) + "," + (ip[3]&255) + "," + (p/256) + "," + (p%256) + ")");
                            break;
                        case "EPSV":
                            close(passive); passive = new ServerSocket(0, 1);
                            reply(out, 229, "Entering Extended Passive Mode (|||" + passive.getLocalPort() + "|)");
                            break;
                        case "LIST": case "NLST":
                            File listed = arg.isEmpty() || arg.startsWith("-") ? cwd : resolve(cwd, arg);
                            ServerSocket listSocket = requirePassive(passive); passive = null;
                            reply(out, 150, "Opening data connection");
                            try (ServerSocket ps = listSocket; Socket data = ps.accept(); BufferedWriter dataOut = new BufferedWriter(new OutputStreamWriter(data.getOutputStream(), StandardCharsets.UTF_8))) {
                                File[] files = listed.isDirectory() ? listed.listFiles() : new File[]{listed};
                                if (files != null) for (File f : files) {
                                    if (command.equals("NLST")) dataOut.write(f.getName() + "\r\n");
                                    else dataOut.write(listLine(f) + "\r\n");
                                }
                            }
                            reply(out, 226, "Transfer complete");
                            break;
                        case "SIZE":
                            File sized = resolve(cwd, arg);
                            if (!sized.isFile()) reply(out, 550, "Not a file"); else reply(out, 213, Long.toString(sized.length()));
                            break;
                        case "MDTM":
                            File dated = resolve(cwd, arg);
                            if (!dated.exists()) reply(out, 550, "Not found");
                            else { SimpleDateFormat fmt = new SimpleDateFormat("yyyyMMddHHmmss", Locale.US); fmt.setTimeZone(TimeZone.getTimeZone("UTC")); reply(out, 213, fmt.format(new Date(dated.lastModified()))); }
                            break;
                        case "REST": restartAt = Long.parseLong(arg); reply(out, 350, "Restart position accepted"); break;
                        case "RETR":
                            File source = resolve(cwd, arg);
                            if (!source.isFile()) { reply(out, 550, "Not a file"); break; }
                            ServerSocket readSocket = requirePassive(passive); passive = null;
                            reply(out, 150, "Opening data connection");
                            try (ServerSocket ps = readSocket; Socket data = ps.accept(); RandomAccessFile file = new RandomAccessFile(source, "r"); OutputStream dataOut = data.getOutputStream()) {
                                file.seek(Math.min(restartAt, file.length())); copy(new FileInputStream(file.getFD()), dataOut);
                            }
                            restartAt = 0; reply(out, 226, "Transfer complete");
                            break;
                        case "STOR":
                            File target = resolve(cwd, arg);
                            ServerSocket writeSocket = requirePassive(passive); passive = null;
                            reply(out, 150, "Opening data connection");
                            try (ServerSocket ps = writeSocket; Socket data = ps.accept(); OutputStream file = new FileOutputStream(target, restartAt > 0)) { copy(data.getInputStream(), file); }
                            restartAt = 0; reply(out, 226, "Transfer complete");
                            break;
                        case "QUIT": reply(out, 221, "Goodbye"); return;
                        default: reply(out, 502, "Command not implemented");
                    }
                } catch (Exception e) {
                    reply(out, 550, e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage());
                    close(passive); passive = null; restartAt = 0;
                }
            }
        } catch (IOException ignored) {
        } finally { close(passive); }
    }

    private File resolve(File cwd, String raw) throws IOException {
        String path = raw == null ? "" : raw.replace('\\', '/');
        File candidate = path.startsWith("/") ? new File(root, path.substring(1)) : new File(cwd, path);
        candidate = candidate.getCanonicalFile();
        String rootPath = root.getPath();
        if (!candidate.getPath().equals(rootPath) && !candidate.getPath().startsWith(rootPath + File.separator)) throw new IOException("Path outside FTP root");
        return candidate;
    }

    private String virtualPath(File file) throws IOException {
        String relative = root.toURI().relativize(file.getCanonicalFile().toURI()).getPath();
        return relative.isEmpty() ? "/" : "/" + relative.replaceAll("/$", "");
    }

    private static String listLine(File f) {
        SimpleDateFormat fmt = new SimpleDateFormat("MMM dd HH:mm", Locale.US);
        String mode = f.isDirectory() ? "drwxr-xr-x" : "-rw-r--r--";
        return mode + " 1 android android " + f.length() + " " + fmt.format(new Date(f.lastModified())) + " " + f.getName();
    }

    private static void reply(BufferedWriter out, int code, String message) throws IOException { out.write(code + " " + message + "\r\n"); out.flush(); }
    private static ServerSocket requirePassive(ServerSocket socket) throws IOException { if (socket == null) throw new IOException("Use PASV or EPSV first"); socket.setSoTimeout(15000); return socket; }
    private static void copy(InputStream in, OutputStream out) throws IOException { byte[] buf = new byte[65536]; int n; while ((n = in.read(buf)) >= 0) out.write(buf, 0, n); out.flush(); }
    private static void close(Closeable c) { if (c != null) try { c.close(); } catch (IOException ignored) {} }

    private static String lanAddress() throws SocketException {
        Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
        while (interfaces.hasMoreElements()) {
            NetworkInterface net = interfaces.nextElement();
            if (!net.isUp() || net.isLoopback()) continue;
            Enumeration<InetAddress> addresses = net.getInetAddresses();
            while (addresses.hasMoreElements()) {
                InetAddress address = addresses.nextElement();
                if (address instanceof Inet4Address && !address.isLoopbackAddress()) return address.getHostAddress();
            }
        }
        return "127.0.0.1";
    }
}
