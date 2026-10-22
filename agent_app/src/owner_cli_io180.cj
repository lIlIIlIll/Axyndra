package agent_app

import agent_domain.*
import agent_domain.CancellationToken as OperatorCancellationToken180
import agent_domain.CancellationSource as OperatorCancellationSource180
import std.collection.*
import std.sync.*
import std.time.*
import agent_product.*
import agent_host_runtime.*
import agent_runtime.*
import process4cj.*
import std.env.*
import yjson_support.*
import yjson.*

// Each actual formatter receives its own port. The owner never redirects a
// process descriptor or changes a global Console to serve concurrent clients.
interface CliIo180 {
    func print(text: String): Unit
    func println(text: String): Unit
    func eprintln(text: String): Unit
    func subscribeOwned180(session: ApplicationSession, ordinary: AgentEventSink, owned: OwnedAgentEventSink,
        failures!: ?OwnedFailureEventSink113): Unit
    func println(): Unit
    func flush(): Unit
    func readln(): ?String
    func cancellation180(): OperatorCancellationToken180
    func stdioInput180(): ?(() -> Result<?HostStdioInputFrame180>)
    func stdioOutput180(): ?((String) -> Result<Unit>)
}

class ConsoleCliIo180 <: CliIo180 {
    private let cancellation = OperatorCancellationSource180()
    public func print(text: String): Unit {
        getStdOut().flush()
        writeFdUtf8Checked182(1, text)
    }
    public func println(text: String): Unit {
        getStdOut().flush()
        writeFdUtf8LineChecked122(1, text)
    }
    public func eprintln(text: String): Unit { writeFdUtf8LineChecked122(2, text) }
    public func subscribeOwned180(session: ApplicationSession, ordinary: AgentEventSink, owned: OwnedAgentEventSink,
        failures!: ?OwnedFailureEventSink113): Unit { session.subscribeOwned(ordinary, owned, failures: failures) }
    public func println(): Unit { println("") }
    public func flush(): Unit { getStdOut().flush() }
    public func readln(): ?String {
        let value = getStdIn().readln()
        if (value.isNone()) { cancellation.cancel() }
        value
    }
    public func cancellation180(): OperatorCancellationToken180 { cancellation.token }
    public func stdioInput180(): ?(() -> Result<?HostStdioInputFrame180>) { None<() -> Result<?HostStdioInputFrame180>> }
    public func stdioOutput180(): ?((String) -> Result<Unit>) { None<(String) -> Result<Unit>> }
}

class OwnerCliFailureHelper180 {
    let output: CliFailureOutput113
    let paid: LogicalJsonOwnerReservation
    init(output: CliFailureOutput113, paid: LogicalJsonOwnerReservation) { this.output = output; this.paid = paid }
}
class OwnerCliIo180 <: CliIo180 {
    private let peer: ProductOwnerPeer180
    private let input: OwnerFrontendInput180
    private let metadata: LogicalJsonOwnerReservation
    private let writeLock = Mutex()
    private var outputFrame: Int64 = 0
    private var activeWriteText: ?String = None<String>
    private var activeWritePayment: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private let subscriptions = ArrayList<ApplicationOwnedSubscription113>()
    private let helpers = ArrayList<OwnerCliFailureHelper180>()
    init(peer: ProductOwnerPeer180, input: OwnerFrontendInput180, metadata: LogicalJsonOwnerReservation) {
        this.peer = peer; this.input = input; this.metadata = metadata
    }
    public func print(text: String): Unit { write180(text, "output") }
    public func println(text: String): Unit { write180(text, "output", line: true) }
    public func println(): Unit { write180("\n", "output") }
    public func eprintln(text: String): Unit { write180(text, "error_output", line: true) }
    public func subscribeOwned180(session: ApplicationSession, ordinary: AgentEventSink, owned: OwnedAgentEventSink,
        failures!: ?OwnedFailureEventSink113): Unit {
        metadata.ensureRetainedPeak(65536 + (subscriptions.size + 1) * 4096)
        let paid = peer.deriveOwnerFrameData180(65536)
        subscriptions.add(session.subscribeRetirableOwned113(paid, ordinary, owned, failures: failures))
    }
    public func retireSubscriptions180(session: ApplicationSession): Bool {
        if (activeWritePayment.isSome()) { return false }
        session.collectOwnedCheckpointFailure113()
        for (token in subscriptions) {
            if (!session.unsubscribeRetirableOwned113(token) || !token.retireAfterUnsubscribe113()) { return false }
        }
        subscriptions.clear()
        for (helper in helpers) { if (helper.output.hasPending()) { return false } }
        closeReturnedHelpers180()
        true
    }
    func retainFailureHelper180(output: CliFailureOutput113, paid: LogicalJsonOwnerReservation): Unit {
        metadata.ensureRetainedPeak(65536 + (subscriptions.size + helpers.size + 1) * 4096)
        helpers.add(OwnerCliFailureHelper180(output, paid))
    }
    private func closeReturnedHelpers180(): Unit {
        for (helper in helpers) { helper.paid.close() }
        helpers.clear()
    }
    // writeOwnerFrame180 returns only after the real bounded physical write.
    // There is no buffered stdout or Unit-callback success to flush/ACK.
    public func flush(): Unit { write180("", "output") }
    private func write180(text: String, kind: String, line!: Bool = false): Unit {
        writeLock.lock()
        try {
            let paid = peer.deriveOwnerFrameData180(65536 + text.size * 8)
            activeWritePayment = Some(paid); activeWriteText = Some(text)
            writeHelper180(activeWriteText.getOrThrow(), kind, line: line)
            activeWriteText = None<String>; activeWritePayment = None<LogicalJsonOwnerReservation>
            paid.close()
        } finally { writeLock.unlock() }
    }
    private func writeHelper180(text: String, kind: String, line!: Bool): Unit {
        let bytes = unsafe { text.rawData() }
        let until = MonoTime.now() + Duration.millisecond * 5000
        var start: Int64 = 0
        while (start < bytes.size || (start == 0 && bytes.isEmpty())) {
            var end = min(bytes.size, start + 65536)
            while (end < bytes.size && (bytes[end] & 192u8) == 128u8) { end-- }
            let chunk = String.fromUtf8(bytes[start..end])
            let part = if (line && end == bytes.size) { chunk + "\n" } else { chunk }
            outputFrame++
            input.expectOutput180(outputFrame, until)
            let frame = encodeAgentValue(objectValue([
                ValueField("frame", integerValue(outputFrame)),
                ValueField("kind", textValue(kind)), ValueField("text", textValue(part)),
                ValueField("final", boolValue(end == bytes.size))]))
            match (peer.writeOwnerFrame180(frame)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
            }
            match (input.awaitOutputReturn180(outputFrame, until)) {
                case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
                case Result.Ok(_) => ()
            }
            if (end == bytes.size) { break }
            start = end
        }
    }
    public func cancellation180(): OperatorCancellationToken180 { input.cancellation180() }
    public func stdioInput180(): ?(() -> Result<?HostStdioInputFrame180>) {
        Some({ => input.takeOwnedStdioInput180() })
    }
    public func stdioOutput180(): ?((String) -> Result<Unit>) {
        Some({ frame => print(frame); Result<Unit>.Ok(()) })
    }
    public func readln(): ?String {
        match (peer.writeOwnerFrame180(encodeAgentValue(objectValue([
            ValueField("kind", textValue("read"))])))) {
            case Result.Ok(_) => input.nextLine180()
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
        }
    }
}
let consoleCliIo180: CliIo180 = ConsoleCliIo180()
