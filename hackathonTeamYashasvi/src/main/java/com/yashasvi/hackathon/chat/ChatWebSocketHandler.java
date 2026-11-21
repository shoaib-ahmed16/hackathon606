package com.yashasvi.hackathon.chat;

import com.anthropic.models.messages.MessageParam;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Text WebSocket handler: every incoming frame is a user message; Claude's reply is streamed back as JSON frames
 * {@code {"type":"delta","text":..}} ... {@code {"type":"done"}} (or {@code {"type":"error","message":..}}).
 * Conversation history is kept per socket session.
 */
@Slf4j
@Component
public class ChatWebSocketHandler extends TextWebSocketHandler {

    static final int MAX_HISTORY_MESSAGES = 20;
    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final ClaudeChatService claude;
    private final Map<String, List<MessageParam>> histories = new ConcurrentHashMap<>();

    public ChatWebSocketHandler(ClaudeChatService claude) {
        this.claude = claude;
    }

    @Override
    public void afterConnectionEstablished(WebSocketSession session) {
        log.info("Chat connected: session={} user={}", session.getId(), user(session));
    }

    @Override
    protected void handleTextMessage(WebSocketSession session, TextMessage message) throws IOException {
        String text = message.getPayload().trim();
        if (text.isEmpty()) {
            return;
        }
        List<MessageParam> history = histories.computeIfAbsent(session.getId(), id -> new ArrayList<>());
        history.add(MessageParam.ofUser(text));
        try {
            String reply = claude.stream(List.copyOf(history), delta -> send(session, frame("delta", "text", delta)));
            history.add(MessageParam.ofAssistant(reply));
            trim(history);
            send(session, frame("done", null, null));
        } catch (Exception e) {
            history.remove(history.size() - 1);   // keep history valid (alternating roles) after a failed turn
            String cause = rootCauseMessage(e);
            log.warn("Chat request failed for session {}: {}", session.getId(), cause, e);
            send(session, frame("error", "message", firstLine(cause)));
        }
    }

    @Override
    public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
        histories.remove(session.getId());
        log.info("Chat closed: session={} user={} status={}", session.getId(), user(session), status);
    }

    /** Keeps the last MAX_HISTORY_MESSAGES messages, always starting on a user message. */
    private static void trim(List<MessageParam> history) {
        while (history.size() > MAX_HISTORY_MESSAGES) {
            history.remove(0);
        }
        while (!history.isEmpty() && history.get(0).role() != MessageParam.Role.USER) {
            history.remove(0);
        }
    }

    /** Frame with a stable field order: type first, then the optional payload field. */
    private static Map<String, String> frame(String type, String key, String value) {
        Map<String, String> m = new LinkedHashMap<>();
        m.put("type", type);
        if (key != null) {
            m.put(key, value);
        }
        return m;
    }

    private static void send(WebSocketSession session, Map<String, String> frame) {
        try {
            session.sendMessage(new TextMessage(MAPPER.writeValueAsString(frame)));
        } catch (JsonProcessingException e) {
            throw new IllegalStateException(e);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private static String user(WebSocketSession session) {
        return session.getPrincipal() == null ? "anonymous" : session.getPrincipal().getName();
    }

    private static final Pattern API_ERROR_MESSAGE = Pattern.compile("\"message\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");

    /** Wrapper exceptions carry generic text; the useful provider message is deepest in the cause chain. */
    static String rootCauseMessage(Throwable t) {
        String best = t.getMessage();
        for (Throwable c = t.getCause(); c != null && c != c.getCause(); c = c.getCause()) {
            if (c.getMessage() != null && !c.getMessage().isBlank()) {
                best = c.getMessage();
            }
        }
        return best;
    }

    /** Prefers the "message" field of a JSON API error body, else the first line of the exception text. */
    static String firstLine(String s) {
        if (s == null || s.isBlank()) {
            return "request to the AI model failed";
        }
        Matcher m = API_ERROR_MESSAGE.matcher(s);
        String line = m.find() ? m.group(1).replace("\\\"", "\"") : s.strip().split("\\R", 2)[0];
        return line.length() > 300 ? line.substring(0, 300) + "..." : line;
    }
}
