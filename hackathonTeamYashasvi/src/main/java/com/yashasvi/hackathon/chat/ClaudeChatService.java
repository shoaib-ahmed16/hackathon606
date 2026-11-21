package com.yashasvi.hackathon.chat;

import com.anthropic.client.AnthropicClient;
import com.anthropic.client.okhttp.AnthropicOkHttpClient;
import com.anthropic.core.http.StreamResponse;
import com.anthropic.models.messages.CacheControlEphemeral;
import com.anthropic.models.messages.MessageCreateParams;
import com.anthropic.models.messages.MessageParam;
import com.anthropic.models.messages.OutputConfig;
import com.anthropic.models.messages.RawMessageStreamEvent;
import com.anthropic.models.messages.StopReason;
import com.anthropic.models.messages.ThinkingConfigAdaptive;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.function.Consumer;

/** Thin wrapper over the Anthropic Java SDK: streams one Claude reply for a conversation. */
@Slf4j
@Service
public class ClaudeChatService {

    static final String SYSTEM_PROMPT = "You are a helpful assistant chatting with a user in a terminal. "
            + "Keep answers concise and use plain text (no markdown).";

    private final AnthropicClient client;
    private final String model;
    private final OutputConfig.Effort effort;
    private final long maxTokens;

    public ClaudeChatService(@Value("${chat.anthropic.api-key}") String apiKey,
                             @Value("${chat.anthropic.model}") String model,
                             @Value("${chat.anthropic.effort}") String effort,
                             @Value("${chat.anthropic.max-tokens}") long maxTokens) {
        this.client = AnthropicOkHttpClient.builder().apiKey(apiKey).build();
        this.model = model;
        this.effort = OutputConfig.Effort.of(effort.trim().toLowerCase());
        this.maxTokens = maxTokens;
    }

    /**
     * Streams the reply for {@code history} (must end with a user message); each text delta goes to
     * {@code onDelta}. Returns the full reply text. Throws on API errors or a refusal.
     */
    public String stream(List<MessageParam> history, Consumer<String> onDelta) {
        MessageCreateParams params = MessageCreateParams.builder()
                .model(model)
                .maxTokens(maxTokens)
                .system(SYSTEM_PROMPT)
                .messages(history)
                .thinking(ThinkingConfigAdaptive.builder().build())
                .outputConfig(OutputConfig.builder().effort(effort).build())
                // auto prompt caching of the growing conversation prefix (short prompts are below the minimum and skip it)
                .cacheControl(CacheControlEphemeral.builder().build())
                .build();

        StringBuilder reply = new StringBuilder();
        try (StreamResponse<RawMessageStreamEvent> stream = client.messages().createStreaming(params)) {
            stream.stream().forEach(event -> {
                event.contentBlockDelta().flatMap(d -> d.delta().text()).ifPresent(t -> {
                    reply.append(t.text());
                    onDelta.accept(t.text());
                });
                event.messageStart().ifPresent(s -> log.debug("cache read={} created={}",
                        s.message().usage().cacheReadInputTokens(), s.message().usage().cacheCreationInputTokens()));
                event.messageDelta().flatMap(d -> d.delta().stopReason()).ifPresent(r -> {
                    if (r.equals(StopReason.REFUSAL)) {
                        throw new IllegalStateException("the model declined to answer this request");
                    }
                });
            });
        }
        return reply.toString();
    }
}
