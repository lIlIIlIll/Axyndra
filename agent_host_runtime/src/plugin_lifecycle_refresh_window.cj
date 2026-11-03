package agent_host_runtime

import agent_domain.*
import agent_ports.*
import tool_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

// Private host construction. This window owns one actual Refresh root's I/O
// scope, and never exposes the raw ProcessChannel or renews a startup grant.
class HostLifecycleRefreshWindow {
    private let lease: HostPluginLifecycleLease
    let context: ToolInvocationContext
    let prepared: PreparedToolInvocation
    let scope: HostLifecycleIoScope
    let outputTicket: ProcessChannelOutputWindow
    let outputBaseline: Int64
    let maxOutput: Int64
    private let maxInput: Int64
    private let maxWrites: Int64
    private let planText: String
    private let lock = Mutex()
    private var closing = false
    private var released = false
    private var active: Int64 = 0
    private var inputBytes: Int64 = 0
    private var readBytes: Int64 = 0
    private var writes: Int64 = 0
    init(lease: HostPluginLifecycleLease, context: ToolInvocationContext,
        prepared: PreparedToolInvocation, plan: AgentValue, scope: HostLifecycleIoScope, outputTicket: ProcessChannelOutputWindow) {
        this.lease = lease; this.context = context; this.prepared = prepared
        this.scope = scope; this.outputTicket = outputTicket; this.outputBaseline = outputTicket.baselineBytes
        planText = stringifyUnifiedJson(plan)
        let limits = plan.field("window").getOrThrow()
        maxInput = hostLifecycleInt(limits, "max_input_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES)
        maxOutput = hostLifecycleInt(limits, "max_output_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES)
        maxWrites = hostLifecycleInt(limits, "max_writes", 256)
    }
    prop plan: AgentValue { get() { parseUnifiedJson(planText, maxBytes: 131072) } }
    func ownedBy(owner: HostPluginLifecycleLease): Bool { refEq(owner, lease) }
    func readyForCommit(): Bool {
        if (scope.isCancelled()) { return false }
        lock.lock(); try { closing && released && active == 0 } finally { lock.unlock() }
    }
    func closedOrCancelled(): Bool {
        lock.lock(); let closed = try { closing } finally { lock.unlock() }
        closed || scope.isCancelled()
    }
    func reserveWrite(bytes: Int64): Bool {
        if (scope.isCancelled()) { return false }
        lock.lock()
        try {
            if (closing || bytes < 1 || bytes > maxInput - inputBytes || writes >= maxWrites) { return false }
            inputBytes += bytes; writes += 1; true
        } finally { lock.unlock() }
    }
    func reserveRead(bytes: Int64): Bool {
        lock.lock()
        try {
            if (closing || bytes < 0 || bytes > maxOutput - readBytes) { return false }
            readBytes += bytes; true
        } finally { lock.unlock() }
    }
    private func enter(): Bool {
        if (scope.isCancelled()) { return false }
        lock.lock(); try { if (closing) { false } else { active += 1; true } } finally { lock.unlock() }
    }
    private func leave(): Unit {
        lock.lock()
        let release = try {
            active -= 1
            if (closing && active == 0 && !released) { released = true; true } else { false }
        } finally { lock.unlock() }
        if (release) { let _ = lease.closeRefresh(this) }
    }
    func read(stream: ProcessChannelStream, maxBytes: Int64, waitMillis: Int64): Result<ProcessChannelRead> {
        if (!enter()) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_closed") }
        try { lease.readRefresh(this, stream, maxBytes, waitMillis) } finally { leave() }
    }
    func write(bytes: Array<Byte>): Result<Unit> {
        if (!enter()) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_closed") }
        try { lease.writeRefresh(this, bytes) } finally { leave() }
    }
    func close(): Unit {
        lock.lock()
        let release = try {
            closing = true
            if (active == 0 && !released) { released = true; true } else { false }
        } finally { lock.unlock() }
        if (release) { let _ = lease.closeRefresh(this) }
    }
}
