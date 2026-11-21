package com.yashasvi.hackathon.cli;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.WebSocket;
import java.util.Map;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * Terminal chat client. Logs in to get a JWT, opens the chat WebSocket and lets you talk to the bot.
 *
 * <pre>./gradlew -q --console=plain chat</pre>
 * Settings (env or system property): CHAT_URL (default http://localhost:8888), CHAT_USER, CHAT_PASSWORD.
 * Type /quit to leave.
 */
public class TerminalChatClient {

    private static final String LOGIN_PATH = "/api/v1/login";
    private static final String CHAT_PATH = "/ws/chat";
    private static final ObjectMapper MAPPER = new ObjectMapper();

    public static void main(String[] args) throws Exception {
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
        String baseUrl = setting("CHAT_URL", "http://localhost:8888", in, null);
        String user = setting("CHAT_USER", null, in, "Username (email): ");
        String password = setting("CHAT_PASSWORD", null, in, "Password: ");

        HttpClient http = HttpClient.newHttpClient();
        String token = login(http, baseUrl, user, password);
        System.out.println("Logged in as " + user + ". Type a message, /quit to exit.");

        BlockingQueue<String> replies = new LinkedBlockingQueue<>();
        CompletableFuture<Void> closed = new CompletableFuture<>();
        String wsUrl = baseUrl.replaceFirst("^http", "ws") + CHAT_PATH;

        WebSocket ws = http.newWebSocketBuilder()
                .header("Authorization", "Bearer " + token)
                .buildAsync(URI.create(wsUrl), new Listener(replies, closed))
                .exceptionally(e -> {
                    System.err.println("Could not open WebSocket: " + rootMessage(e));
                    System.exit(1);
                    return null;
                })
                .join();

        String line;
        while (!closed.isDone()) {
            System.out.print("you> ");
            System.out.flush();
            line = in.readLine();
            if (line == null || line.trim().equalsIgnoreCase("/quit")) {
                break;
            }
            if (line.isBlank()) {
                continue;
            }
            ws.sendText(line, true).join();
            System.out.print("bot> ");
            System.out.flush();
            // the listener prints streamed deltas live; a token arrives here once the reply is complete
            if (replies.poll(180, TimeUnit.SECONDS) == null) {
                System.out.println("(no reply within 180s)");
            }
        }
        ws.sendClose(WebSocket.NORMAL_CLOSURE, "bye").exceptionally(e -> null).join();
        System.out.println("Bye.");
        System.exit(0);
    }

    private static String login(HttpClient http, String baseUrl, String user, String password) throws Exception {
        String body = MAPPER.writeValueAsString(Map.of("username", user, "password", password));
        HttpRequest req = HttpRequest.newBuilder(URI.create(baseUrl + LOGIN_PATH))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();
        HttpResponse<String> res;
        try {
            res = http.send(req, HttpResponse.BodyHandlers.ofString());
        } catch (java.io.IOException e) {
            throw fail("Cannot reach " + baseUrl + " (is the app running?): " + rootMessage(e));
        }
        JsonNode token = res.statusCode() / 100 == 2 ? MAPPER.readTree(res.body()).path("obj").path("jwtToken") : null;
        if (token == null || token.asText().isBlank()) {
            throw fail("Login failed (HTTP " + res.statusCode() + "). Register first via POST /api/v1/signIn.");
        }
        return token.asText();
    }

    private static String setting(String key, String def, BufferedReader in, String prompt) throws Exception {
        String v = System.getenv(key);
        if (v == null || v.isBlank()) {
            v = System.getProperty(key);
        }
        if (v == null || v.isBlank()) {
            if (prompt == null) {
                return def;
            }
            System.out.print(prompt);
            System.out.flush();
            v = in.readLine();
        }
        return v == null ? "" : v.trim();
    }

    private static IllegalStateException fail(String msg) {
        System.err.println(msg);
        System.exit(1);
        return new IllegalStateException(msg);
    }

    private static String rootMessage(Throwable t) {
        while (t.getCause() != null) {
            t = t.getCause();
        }
        return t.getMessage() == null ? t.toString() : t.getMessage();
    }

    private static class Listener implements WebSocket.Listener {
        private final BlockingQueue<String> replies;
        private final CompletableFuture<Void> closed;
        private final StringBuilder buffer = new StringBuilder();

        Listener(BlockingQueue<String> replies, CompletableFuture<Void> closed) {
            this.replies = replies;
            this.closed = closed;
        }

        @Override
        public CompletionStage<?> onText(WebSocket ws, CharSequence data, boolean last) {
            buffer.append(data);
            if (last) {
                handleFrame(buffer.toString());
                buffer.setLength(0);
            }
            ws.request(1);
            return null;
        }

        private void handleFrame(String json) {
            try {
                JsonNode frame = MAPPER.readTree(json);
                switch (frame.path("type").asText()) {
                    case "delta" -> {
                        System.out.print(frame.path("text").asText());
                        System.out.flush();
                    }
                    case "done" -> {
                        System.out.println();
                        replies.add("done");
                    }
                    case "error" -> {
                        System.out.println("[error] " + frame.path("message").asText());
                        replies.add("error");
                    }
                    default -> System.out.println(json);
                }
            } catch (Exception e) {
                System.out.println(json);
                replies.add("raw");
            }
        }

        @Override
        public CompletionStage<?> onClose(WebSocket ws, int statusCode, String reason) {
            System.out.println("\n[connection closed by server]");
            closed.complete(null);
            replies.add("");
            return null;
        }

        @Override
        public void onError(WebSocket ws, Throwable error) {
            System.err.println("\n[connection error] " + rootMessage(error));
            closed.complete(null);
            replies.add("");
        }
    }
}
