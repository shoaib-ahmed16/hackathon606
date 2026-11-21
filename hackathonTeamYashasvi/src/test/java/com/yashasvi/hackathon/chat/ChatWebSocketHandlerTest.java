package com.yashasvi.hackathon.chat;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.anthropic.models.messages.MessageParam;
import java.util.List;
import java.util.function.Consumer;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;

class ChatWebSocketHandlerTest {

    private final ClaudeChatService claude = mock(ClaudeChatService.class);
    private final WebSocketSession session = mock(WebSocketSession.class);
    private final ChatWebSocketHandler handler = new ChatWebSocketHandler(claude);

    private List<String> sent() throws Exception {
        ArgumentCaptor<TextMessage> c = ArgumentCaptor.forClass(TextMessage.class);
        verify(session, atLeastOnce()).sendMessage(c.capture());
        return c.getAllValues().stream().map(TextMessage::getPayload).toList();
    }

    @SuppressWarnings("unchecked")
    private void replyWith(String... deltas) {
        doAnswer(inv -> {
            Consumer<String> onDelta = inv.getArgument(1);
            for (String d : deltas) {
                onDelta.accept(d);
            }
            return String.join("", deltas);
        }).when(claude).stream(anyList(), any(Consumer.class));
    }

    @Test
    void streamsDeltasThenDone() throws Exception {
        when(session.getId()).thenReturn("s1");
        replyWith("hello ", "there");

        handler.handleTextMessage(session, new TextMessage("hi"));

        assertEquals(List.of(
                "{\"type\":\"delta\",\"text\":\"hello \"}",
                "{\"type\":\"delta\",\"text\":\"there\"}",
                "{\"type\":\"done\"}"), sent());
    }

    @Test
    @SuppressWarnings("unchecked")
    void secondTurnSendsFullHistory() throws Exception {
        when(session.getId()).thenReturn("s1");
        replyWith("a");
        handler.handleTextMessage(session, new TextMessage("one"));
        handler.handleTextMessage(session, new TextMessage("two"));

        ArgumentCaptor<List<MessageParam>> c = ArgumentCaptor.forClass(List.class);
        verify(claude, org.mockito.Mockito.times(2)).stream(c.capture(), any(Consumer.class));
        assertEquals(1, c.getAllValues().get(0).size());
        assertEquals(3, c.getAllValues().get(1).size());   // user, assistant, user
    }

    @Test
    @SuppressWarnings("unchecked")
    void failureBecomesErrorFrameAndDoesNotPolluteHistory() throws Exception {
        when(session.getId()).thenReturn("s1");
        when(claude.stream(anyList(), any(Consumer.class)))
                .thenThrow(new IllegalStateException("401 invalid x-api-key\nmore detail"));

        handler.handleTextMessage(session, new TextMessage("hi"));

        String out = sent().get(0);
        assertTrue(out.startsWith("{\"type\":\"error\""), out);
        assertTrue(out.contains("401 invalid x-api-key") && !out.contains("more detail"), out);

        replyWith("ok");
        handler.handleTextMessage(session, new TextMessage("again"));
        ArgumentCaptor<List<MessageParam>> c = ArgumentCaptor.forClass(List.class);
        verify(claude, org.mockito.Mockito.times(2)).stream(c.capture(), any(Consumer.class));
        assertEquals(1, c.getAllValues().get(1).size());   // failed turn was dropped
    }

    @Test
    @SuppressWarnings("unchecked")
    void blankMessagesAreIgnored() throws Exception {
        handler.handleTextMessage(session, new TextMessage("   "));
        verify(session, never()).sendMessage(any());
        verify(claude, never()).stream(anyList(), any(Consumer.class));
    }

    @Test
    @SuppressWarnings("unchecked")
    void closingTheSocketForgetsItsHistory() throws Exception {
        when(session.getId()).thenReturn("s1");
        replyWith("a");
        handler.handleTextMessage(session, new TextMessage("one"));
        handler.afterConnectionClosed(session, CloseStatus.NORMAL);
        handler.handleTextMessage(session, new TextMessage("two"));

        ArgumentCaptor<List<MessageParam>> c = ArgumentCaptor.forClass(List.class);
        verify(claude, org.mockito.Mockito.times(2)).stream(c.capture(), any(Consumer.class));
        assertEquals(1, c.getAllValues().get(1).size());
    }

    @Test
    void jsonErrorBodyIsReducedToItsMessage() {
        String body = "HTTP 401 - {\n \"error\": {\n \"message\": \"invalid x-api-key\",\n \"type\": \"authentication_error\"\n }\n}";
        assertEquals("invalid x-api-key", ChatWebSocketHandler.firstLine(body));
    }

    @Test
    void wrapperMessageIsReplacedByRootCause() {
        Exception e = new RuntimeException("wrapper", new IllegalStateException("400. something specific"));
        assertEquals("400. something specific", ChatWebSocketHandler.rootCauseMessage(e));
    }
}
