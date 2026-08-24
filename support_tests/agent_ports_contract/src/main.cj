package agent_ports_contract

import agent_domain.*
import agent_ports.*
import std.collection.*

main(): Int64 {
    let port: ModelPort = EchoModelPort()
    let deltas = ArrayList<String>()
    let result = port.execute(
        ModelRequest(
            "fixture",
            [ModelMessage(
                ModelRole.User,
                [ModelBlock(ModelBlockKind.Text, text: "hello")]
            )],
            streaming: true
        ),
        { event =>
            match (event) {
                case ModelEvent.TextDelta(text) => deltas.add(text)
                case _ => ()
            }
        }
    )
    match (result) {
        case Result.Ok(reply) =>
            expect(reply.blocks[0].text == "hello", "typed model reply")
        case Result.Err(error) =>
            throw IllegalStateException(error.message)
    }
    expect(deltas.size == 1 && deltas[0] == "hello",
           "typed model event sink")
    println("agent_ports contract passed")
    0
}

class EchoModelPort <: ModelPort {
    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let text = request.messages[0].blocks[0].text
        events(ModelEvent.TextDelta(text))
        events(ModelEvent.UsageUpdated(1, 1))
        events(ModelEvent.Completed)
        Result.Ok(ModelReply(
            [ModelBlock(ModelBlockKind.Text, text: text)],
            stopReason: "end_turn",
            inputTokens: 1,
            outputTokens: 1
        ))
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
