package agent_product

import agent_domain.*
import std.collection.*
import std.sync.*
import tool_runtime.*

public class InternalUriResource {
    public let url: String
    public let content: String
    public let contentType: String
    public let notes: Array<String>
    public let immutable: Bool

    public init(
        url: String,
        content: String,
        contentType!: String = "text/plain",
        notes!: Array<String> = [],
        immutable!: Bool = false
    ) {
        this.url = url
        this.content = content
        this.contentType = contentType
        this.notes = notes
        this.immutable = immutable
    }
}

public interface InternalUriHandler {
    func read(
        context: ToolInvocationContext,
        url: String
    ): Result<InternalUriResource>

    func write(
        context: ToolInvocationContext,
        url: String,
        content: String
    ): Result<Unit>

    func writable(): Bool

    func cancel(runId: RunId): Result<Unit> {
        let _ = runId
        Result.Ok(())
    }
}

class InternalUriRegistration {
    let scheme: String
    let handler: InternalUriHandler

    init(scheme: String, handler: InternalUriHandler) {
        this.scheme = scheme
        this.handler = handler
    }
}

public class InternalUriRouter {
    private let lock = Mutex()
    private let registrations = ArrayList<InternalUriRegistration>()

    public init() {}

    public func register(
        scheme: String,
        handler: InternalUriHandler
    ): Result<Unit> {
        let normalized = normalizeUriScheme(scheme)
        if (!validUriScheme(normalized)) {
            return uriError<Unit>(
                "invalid URI scheme: " + scheme
            )
        }
        lock.lock()
        try {
            for (index in 0..registrations.size) {
                if (registrations[index].scheme == normalized) {
                    registrations[index] = InternalUriRegistration(
                        normalized,
                        handler
                    )
                    return Result.Ok(())
                }
            }
            registrations.add(InternalUriRegistration(normalized, handler))
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func unregister(scheme: String): Bool {
        let normalized = normalizeUriScheme(scheme)
        lock.lock()
        try {
            for (index in 0..registrations.size) {
                if (registrations[index].scheme == normalized) {
                    registrations.remove(at: index)
                    return true
                }
            }
            false
        } finally {
            lock.unlock()
        }
    }

    public func schemes(): Array<String> {
        lock.lock()
        try {
            let values = ArrayList<String>()
            for (registration in registrations) {
                values.add(registration.scheme)
            }
            values.toArray()
        } finally {
            lock.unlock()
        }
    }

    public func canHandle(url: String): Bool {
        let scheme = uriScheme(url)
        if (scheme.isNone()) { return false }
        find(scheme.getOrThrow()).isSome()
    }

    public func looksLikeUri(url: String): Bool {
        uriScheme(url).isSome()
    }

    public func read(
        context: ToolInvocationContext,
        url: String
    ): Result<InternalUriResource> {
        let handler = match (handlerFor(url)) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                return Result<InternalUriResource>.Err(error)
        }
        handler.read(context, url)
    }

    public func write(
        context: ToolInvocationContext,
        url: String,
        content: String
    ): Result<Unit> {
        let handler = match (handlerFor(url)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result<Unit>.Err(error)
        }
        if (!handler.writable()) {
            return uriError<Unit>(
                uriScheme(url).getOrThrow() +
                    ":// URLs are read-only for write"
            )
        }
        handler.write(context, url, content)
    }

    public func cancel(runId: RunId): Result<Unit> {
        let handlers = snapshotHandlers()
        for (handler in handlers) {
            match (handler.cancel(runId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        Result.Ok(())
    }

    private func handlerFor(
        url: String
    ): Result<InternalUriHandler> {
        let scheme = match (uriScheme(url)) {
            case Some(value) => value
            case None => return uriError<InternalUriHandler>(
                "not an internal URI: " + url
            )
        }
        match (find(scheme)) {
            case Some(value) => Result.Ok(value)
            case None => uriError<InternalUriHandler>(
                "unknown URI protocol: " + scheme + "://"
            )
        }
    }

    private func find(scheme: String): ?InternalUriHandler {
        lock.lock()
        try {
            for (registration in registrations
                 where registration.scheme == scheme) {
                return Some(registration.handler)
            }
            None
        } finally {
            lock.unlock()
        }
    }

    private func snapshotHandlers(): Array<InternalUriHandler> {
        lock.lock()
        try {
            let values = ArrayList<InternalUriHandler>()
            for (registration in registrations) {
                values.add(registration.handler)
            }
            values.toArray()
        } finally {
            lock.unlock()
        }
    }
}

public func normalizeUriScheme(value: String): String {
    value.trimAscii().toAsciiLower()
}

public func validUriScheme(value: String): Bool {
    let bytes = unsafe { value.rawData() }
    if (bytes.size == 0 || !asciiLetter(bytes[0])) { return false }
    for (byte in bytes) {
        if (!asciiLetter(byte) && !asciiDigit(byte) &&
            byte != b'+' && byte != b'.' && byte != b'-') {
            return false
        }
    }
    true
}

func uriScheme(value: String): ?String {
    let marker = value.indexOf("://")
    if (marker.isNone()) { return None }
    let index = marker.getOrThrow()
    if (index < 1) { return None }
    let scheme = normalizeUriScheme(value[..index])
    if (!validUriScheme(scheme)) { return None }
    Some(scheme)
}

func asciiLetter(value: Byte): Bool {
    (value >= b'a' && value <= b'z') ||
        (value >= b'A' && value <= b'Z')
}

func asciiDigit(value: Byte): Bool {
    value >= b'0' && value <= b'9'
}

func uriError<T>(message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "tool.uri",
        message
    ))
}
