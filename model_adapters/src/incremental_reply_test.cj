package model_adapters

import agent_domain as domain
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func incrementalReplyFixture(): String {
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"incremental\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"fixture\",\"content\":[],\"usage\":{\"input_tokens\":11,\"output_tokens\":0}}}\n\n" +
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" +
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"answer 雪\"}}\n\n" +
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" +
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n" +
    "data: {\"type\":\"message_stop\"}\n\n"
}

class IncrementalReplyTestTransport <: ProviderTransport {
    let body: String
    let incremental: Bool
    let comments: Int64
    var invocations: Int64 = 0
    init(body: String, incremental: Bool, comments!: Int64 = 0) {
        this.body = body; this.incremental = incremental; this.comments = comments
    }
    public func usesIncrementalStreamReply(): Bool { incremental }
    public func post(provider: ProviderSpec, payload: String, streaming: Bool,
        requestId: String, chunks: (String) -> Unit): domain.Result<String> {
        let _ = (provider, payload, requestId)
        invocations += 1
        if (streaming) {
            let comment = ":" + String.fromUtf8(Array<Byte>(4093, repeat: b' ')) + "\n\n"
            @Expect(comment.toArray().size, 4096)
            for (_ in 0..comments) { chunks(comment) }
            // Breaks are arbitrary transport boundaries, including inside
            // SSE field names. The existing decoder retains its own buffer.
            for (line in body.split("\n")) { chunks(line); chunks("\n") }
            domain.Result.Ok(if (incremental) { "not a captured SSE body" } else { body })
        } else { domain.Result.Ok(body) }
    }
}

func incrementalReplyPort(transport: ProviderTransport): ProviderModelPort {
    ProviderModelPort(ProviderSpec("fixture", ProviderProtocol.Messages, "fixture", "https://provider.invalid",
        "UNUSED_KEY", provider: "anthropic", dialect: Some(ProviderDialect.AnthropicMessages)), transport)
}
func incrementalReplyRequest(streaming!: Bool = true): domain.ModelRequest {
    domain.ModelRequest("fixture", [domain.ModelMessage(domain.ModelRole.User,
        [domain.ModelBlock(domain.ModelBlockKind.Text, text: "test")])],
        streaming: streaming, requestId: "incremental-test", toolChoice: domain.ModelToolChoice.NoTools)
}

@Test
class IncrementalProviderReplyTests {
    @TestCase
    func sameDecoderTerminalMatchesCapturedReplayWithoutASecondBody(): Unit {
        let fresh = IncrementalReplyTestTransport(incrementalReplyFixture(), true)
        let replay = IncrementalReplyTestTransport(incrementalReplyFixture(), false)
        let events = ArrayList<domain.ModelEvent>()
        let left = incrementalReplyPort(fresh).execute(incrementalReplyRequest(), { event => events.add(event) }).value().getOrThrow()
        let right = incrementalReplyPort(replay).execute(incrementalReplyRequest(), {_ => ()}).value().getOrThrow()
        @Expect(left.blocks.size, right.blocks.size)
        @Expect(left.blocks[0].text, "answer 雪")
        @Expect(left.blocks[0].text, right.blocks[0].text)
        @Expect(left.usage.inputTokens, right.usage.inputTokens)
        @Expect(left.usage.outputTokens, right.usage.outputTokens)
        @Expect(left.stopReason, right.stopReason)
        var completed: Int64 = 0; var terminals: Int64 = 0; var closed: Int64 = 0
        for (event in events) {
            match (event) {
                case domain.ModelEvent.Completed => completed += 1
                case domain.ModelEvent.ProviderProgress(domain.ProviderStreamEvent.StreamTransportClosed) => closed += 1
                case domain.ModelEvent.ProviderProgress(domain.ProviderStreamEvent.MessageTerminalObserved(_)) => terminals += 1
                case _ => ()
            }
        }
        @Expect(completed, 1); @Expect(terminals, 1); @Expect(closed, 1)
        @Expect(fresh.invocations, 1)
    }

    @TestCase
    func sixtyFourMiBOfCommentsDoesNotRequireCapturedBodyReplay(): Unit {
        let commentCount: Int64 = 16384
        @Expect(commentCount * 4096, 67108864)
        let transport = IncrementalReplyTestTransport(incrementalReplyFixture(), true, comments: commentCount)
        let reply = match (incrementalReplyPort(transport).execute(incrementalReplyRequest(), {_ => ()})) {
            case domain.Result.Ok(value) => value
            case domain.Result.Err(error) => throw IllegalStateException("incremental comment stream: " + error.describe())
        }
        @Expect(reply.blocks[0].text, "answer 雪")
        @Expect(reply.usage.inputTokens, 11)
        @Expect(reply.usage.outputTokens, 3)
        @Expect(transport.invocations, 1)
    }

    @TestCase
    func incompleteStreamPreservesTheReplayFailureAndUsageEvidence(): Unit {
        let source = incrementalReplyFixture().replace("data: {\"type\":\"message_stop\"}\n\n", "")
        let left = incrementalReplyPort(IncrementalReplyTestTransport(source, true)).execute(incrementalReplyRequest(), {_ => ()}).error().getOrThrow()
        let right = incrementalReplyPort(IncrementalReplyTestTransport(source, false)).execute(incrementalReplyRequest(), {_ => ()}).error().getOrThrow()
        @Expect(left.code, right.code)
        @Expect(left.code, "llm.stream_terminal_missing")
        @Expect(left.retryable, right.retryable)
        @Expect(left.fields.size, right.fields.size)
        for (index in 0..left.fields.size) {
            @Expect(left.fields[index].name, right.fields[index].name)
            @Expect(left.fields[index].value, right.fields[index].value)
        }
    }

    @TestCase
    func callbackFailureCannotBecomeAnAcceptedIncrementalReply(): Unit {
        let result = incrementalReplyPort(IncrementalReplyTestTransport(incrementalReplyFixture(), true)).execute(
            incrementalReplyRequest(), {_ => throw IllegalStateException("private callback failure")})
        @Expect(result.isError())
        @Expect(result.error().getOrThrow().code, "model.stream_callback_failed")
        @Expect(!result.error().getOrThrow().message.contains("private callback failure"))
    }
}
