package com.androiddc;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.List;

final class FtpCredentials {
    private final byte[] username;
    private final byte[] password;

    private FtpCredentials(String username, String password) {
        this.username = username.getBytes(StandardCharsets.UTF_8);
        this.password = password.getBytes(StandardCharsets.UTF_8);
    }

    static FtpCredentials load(File file) throws IOException {
        List<String> lines = Files.readAllLines(file.toPath(), StandardCharsets.UTF_8);
        if (lines.size() != 2 || !valid(lines.get(0)) || !valid(lines.get(1))) {
            throw new IOException("Invalid FTP credentials");
        }
        return new FtpCredentials(lines.get(0), lines.get(1));
    }

    boolean matchesUser(String value) {
        return MessageDigest.isEqual(username, value.getBytes(StandardCharsets.UTF_8));
    }

    boolean matchesPassword(String value) {
        return MessageDigest.isEqual(password, value.getBytes(StandardCharsets.UTF_8));
    }

    private static boolean valid(String value) {
        return !value.isEmpty() && value.length() <= 128 && value.indexOf('\r') < 0 && value.indexOf('\n') < 0;
    }
}
