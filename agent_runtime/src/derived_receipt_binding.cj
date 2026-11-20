package agent_runtime

import agent_domain.*
import yjson.*
import yjson_support.*
import std.sync.*

// DATA comparison only. The caller owns the frozen input throughout the scoped
// call. A port may retain this handle, but after return it retains no input.
public class DerivedReceiptBinding {
    private let lock = Mutex()
    private var child: ?OperationId
    private var digest: ?String
    private let recordDigest: Bool

    init(child: OperationId, digest: String, recordDigest: Bool) {
        this.child = Some(child); this.digest = Some(digest); this.recordDigest = recordDigest
    }

    public func matches(operation: OperationId, storedDigest: String): Bool {
        lock.lock()
        try {
            match (child) {
                case Some(value) => value.value == operation.value && digest.getOrThrow() == storedDigest
                case None => false
            }
        } finally { lock.unlock() }
    }

    // Only the receiver's own stored text can enter the resulting Receipt.
    // Leave the caller's verification object intact, even if settlement fails.
    public func checkedReceipt(input: VNextOperationReceipt, storedDigest: String): ?VNextOperationReceipt {
        if (!matches(input.operationId, storedDigest)) { return None }
        if (input.verification.unifiedKind != ValueKind.Object) {
            return if (recordDigest) { None<VNextOperationReceipt> } else { Some(input) }
        }
        // An independently supplied field can be checked, never used instead
        // of the frozen handle or as the persisted backing for the digest.
        match (input.verification.field("request_digest")) {
            case Some(value) => if (value.unifiedKind != ValueKind.Text || value.text != storedDigest) { return None }
            case None => if (!recordDigest) { return Some(input) }
        }
        let verification = objectValue(input.verification.fields.map { field => ValueField(field.name, field.value) })
        verification.put("request_digest", textValue(storedDigest))
        Some(VNextOperationReceipt(input.receiptId, input.operationId, input.outcome, input.detail,
            verification, input.observedAtMillis))
    }

    func revoke(): Unit {
        lock.lock()
        try { child = None<OperationId>; digest = None<String> } finally { lock.unlock() }
    }
}

public func withDerivedReceiptBinding<T>(operation: OperationId, frozenDigest: String,
    recordDigest: Bool, body: (DerivedReceiptBinding) -> T): T {
    let binding = DerivedReceiptBinding(operation, frozenDigest, recordDigest)
    try { body(binding) } finally { binding.revoke() }
}
