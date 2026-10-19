package agent_sdk

import yjson.*
import yjson_support.*
import std.deriving.*

// Native wire SDK range. Legacy cooperative business authoring APIs are
// retired; the supported native surface is frozen by the native API gate.
public let AGENT_SDK_VERSION = "2.1.0"

public enum SdkResult<T> {
    Ok(T) | Err(SdkError)

    public func isOk(): Bool {
        match (this) { case Ok(_) => true; case Err(_) => false }
    }
}

@Derive[Equatable]
public enum SdkErrorKind {
    Validation | Preparation | Decode | Unsupported | Cancelled | Deadline
}

public class SdkError <: Exception {
    public let kind: SdkErrorKind
    public let code: String
    public let details: JsonNode

    public init(
        kind: SdkErrorKind,
        code: String,
        message: String,
        details!: JsonNode = jsonObject([])
    ) {
        super(message)
        let normalized = code.trimAscii()
        if (normalized == "" || details.unifiedKind != UnifiedJsonKind.Object) {
            throw IllegalArgumentException("SDK error code and object details are required")
        }
        this.kind = kind
        this.code = normalized
        this.details = details
    }
}











public interface InvocationCancellation {
    func isCancelled(): Bool
    func reason(): String
}

public class NeverCancelled <: InvocationCancellation {
    public init() {}
    public func isCancelled(): Bool { false }
    public func reason(): String { "" }
}

public class InvocationDeadline {
    public let expiresAtMillis: Int64
    public init(expiresAtMillis!: Int64 = 0) {
        if (expiresAtMillis < 0) { throw IllegalArgumentException("deadline must not be negative") }
        this.expiresAtMillis = expiresAtMillis
    }
    public func isSet(): Bool { expiresAtMillis > 0 }
    public func exceeded(nowMillis: Int64): Bool {
        expiresAtMillis > 0 && nowMillis >= expiresAtMillis
    }
}
