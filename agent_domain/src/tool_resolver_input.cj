package agent_domain

import std.sync.*
import yjson.*

// A path belongs to the reader, not the invocation. MemberAt permits complete
// object traversal without handing the caller a source-owned key or DOM node.
public enum ToolResolverStep { Field(String) | Index(Int64) | MemberAt(Int64) }
public enum ToolResolverText {
    CallId | Name | Scalar(Array<ToolResolverStep>) | Key(Array<ToolResolverStep>, Int64)
}

// Data-only access for one descriptor callback. Results are scalars or bytes
// written into the caller's buffer. Even a saved input cannot retain a leaf
// after the actual invocation of the resolver has unwound.
public class ToolResolverInput {
    private let lock = Mutex()
    private var active: ?ToolCall
    init(call: ToolCall) { active = Some(call) }

    private func current(): ToolCall {
        match (active) { case Some(call) => call
            case None => throw IllegalStateException("tool resolver input is closed") }
    }
    private func at(path: Array<ToolResolverStep>): ?AgentValue {
        var value = current().arguments
        for (step in path) {
            match (step) {
                case ToolResolverStep.Field(name) =>
                    if (value.kind() != JsonKind.Object) { return None }
                    match (value.asObject().get(name)) { case Some(item) => value = item; case None => return None }
                case ToolResolverStep.Index(index) =>
                    if (value.kind() != JsonKind.Array || index < 0 || index >= value.asArray().size()) { return None }
                    value = value.asArray().get(index).getOrThrow()
                case ToolResolverStep.MemberAt(index) =>
                    if (value.kind() != JsonKind.Object || index < 0 || index >= value.asObject().size()) { return None }
                    value = value.asObject().valueAt(index)
            }
        }
        Some(value)
    }
    // Module-private. Only fixed Domain projections may use the raw node;
    // their public results must contain no references into the input graph.
    func domainProjection<T>(action: (ToolCall) -> T): T {
        lock.lock(); try { action(current()) } finally { lock.unlock() }
    }
    func projectNode<T>(path: Array<ToolResolverStep>, action: (AgentValue) -> T): T {
        lock.lock(); try { action(at(path).getOrThrow()) } finally { lock.unlock() }
    }
    public func argumentsMatchCanonical(expected: String): Bool {
        lock.lock(); try { canonicalAgentValueMatches(current().arguments, expected) } finally { lock.unlock() }
    }
    public func kind(path: Array<ToolResolverStep>): ?JsonKind {
        lock.lock(); try { match (at(path)) { case Some(value) => Some(value.kind()); case None => None } }
        finally { lock.unlock() }
    }
    public func count(path: Array<ToolResolverStep>): Int64 {
        lock.lock()
        try {
            let value = at(path).getOrThrow()
            match (value.kind()) { case JsonKind.Array => value.asArray().size(); case JsonKind.Object => value.asObject().size()
                case _ => throw IllegalArgumentException("resolver value is not a container") }
        } finally { lock.unlock() }
    }
    public func boolean(path: Array<ToolResolverStep>): Bool {
        lock.lock(); try { at(path).getOrThrow().asBool() } finally { lock.unlock() }
    }
    private func selected(text: ToolResolverText): String {
        match (text) {
            case ToolResolverText.Name => current().name
            case ToolResolverText.CallId => current().callId
            case ToolResolverText.Scalar(path) =>
                let value = at(path).getOrThrow()
                match (value.kind()) { case JsonKind.String => value.asString(); case JsonKind.Number => value.asNumberText()
                    case _ => throw IllegalArgumentException("resolver value is not text or a number") }
            case ToolResolverText.Key(path, index) => at(path).getOrThrow().asObject().nameAt(index)
        }
    }
    public func textEquals(text: ToolResolverText, expected: String): Bool {
        lock.lock(); try { selected(text) == expected } finally { lock.unlock() }
    }
    public func nameStartsWith(prefix: String): Bool {
        lock.lock(); try { current().name.startsWith(prefix) } finally { lock.unlock() }
    }
    public func hasKind(path: Array<ToolResolverStep>, expected: JsonKind): Bool {
        lock.lock(); try { match (at(path)) { case Some(value) => value.kind() == expected; case None => false } }
        finally { lock.unlock() }
    }
    public func listSizeOrZero(path: Array<ToolResolverStep>): Int64 {
        lock.lock(); try { match (at(path)) {
            case Some(value) => if (value.kind() == JsonKind.Array) { value.asArray().size() } else { 0 }
            case None => 0
        } } finally { lock.unlock() }
    }
    // Text returned to a consumer must have its own backing storage.
    public func copyText(text: ToolResolverText): String {
        lock.lock(); try { String.fromUtf8(selected(text).toArray()) } finally { lock.unlock() }
    }
    public func stringField(name: String): String {
        lock.lock(); try { match (at([ToolResolverStep.Field(name)])) {
            case Some(value) => if (value.kind() == JsonKind.String) { String.fromUtf8(value.asString().toArray()) } else { "" }
            case None => ""
        } } finally { lock.unlock() }
    }
    public func byteCount(text: ToolResolverText): Int64 {
        lock.lock(); try { selected(text).size } finally { lock.unlock() }
    }
    public func readBytes(text: ToolResolverText, offset: Int64, destination: Array<Byte>): Int64 {
        lock.lock()
        try {
            let value = selected(text)
            if (offset < 0 || offset > value.size) { throw IndexOutOfBoundsException() }
            let size = min(destination.size, value.size - offset)
            let bytes = unsafe { value.rawData() }
            for (index in 0..size) { destination[index] = bytes[offset + index] }
            size
        } finally { lock.unlock() }
    }
    func revoke(): Unit { lock.lock(); try { active = None<ToolCall> } finally { lock.unlock() } }
}

public func withToolResolverInput<T>(call: ToolCall, action: (ToolResolverInput) -> T): T {
    let input = ToolResolverInput(call)
    try { action(input) } finally { input.revoke() }
}
