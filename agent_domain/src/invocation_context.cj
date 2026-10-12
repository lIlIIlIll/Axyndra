package agent_domain

import std.collection.*
import std.deriving.*

// Context describes model-visible material, never execution authority. There is
// deliberately no privileged/system trust level for provider-authored content.
@Derive[Equatable]
public enum ContextContentTrust { UserSelected | UntrustedData }

// A locator is frozen metadata, not a grant and not proof that mutable remote
// bytes are immutable. Only already loaded content has a verified local digest;
// the provider's controlled reader remains responsible for unresolved locators.
public class ContextResourceReference {
    public let id: String
    public let locator: String
    public let trust: ContextContentTrust
    public let content: ?String
    public let contentDigest: ?String

    public init(
        id: String,
        locator: String,
        trust!: ContextContentTrust = ContextContentTrust.UntrustedData,
        content!: ?String = None
    ) {
        if (!validContextIdentity(id) || !validContextIdentity(locator)) {
            throw IllegalArgumentException("context reference identity is invalid")
        }
        this.id = id
        this.locator = locator
        this.trust = trust
        this.content = content
        this.contentDigest = match (content) {
            case Some(value) => Some(modelPolicySha256Text(value))
            case None => None
        }
    }
}

// Owner and contribution IDs are provider-neutral. Names/descriptions/routing
// rules belong to their provider and are intentionally absent from this view.
public class InvocationContextContribution {
    public let owner: String
    public let id: String
    public let sourceRef: String
    public let content: String
    public let trust: ContextContentTrust
    public let validUntilMillis: Int64
    private let resourceValues: Array<ContextResourceReference>

    public init(
        owner: String,
        id: String,
        sourceRef: String,
        content: String,
        trust: ContextContentTrust,
        references!: Array<ContextResourceReference> = [],
        validUntilMillis!: Int64 = 0
    ) {
        if (!validContextIdentity(owner) || !validContextIdentity(id) ||
            !validContextIdentity(sourceRef)) {
            throw IllegalArgumentException("context contribution identity is invalid")
        }
        if (validUntilMillis < 0) { throw IllegalArgumentException("context.validity_invalid") }
        let resources = ArrayList<ContextResourceReference>()
        for (reference in references) {
            for (existing in resources where existing.id == reference.id) {
                throw IllegalArgumentException("duplicate context resource identity")
            }
            resources.add(reference)
        }
        this.owner = owner
        this.id = id
        this.sourceRef = sourceRef
        this.content = content
        this.trust = trust
        this.resourceValues = resources.toArray()
        this.validUntilMillis = validUntilMillis
    }

    public func references(): Array<ContextResourceReference> {
        let result = ArrayList<ContextResourceReference>()
        for (reference in resourceValues) { result.add(reference) }
        result.toArray()
    }

    public func reference(id: String): ?ContextResourceReference {
        for (value in resourceValues where value.id == id) { return Some(value) }
        None
    }
}

// A derived, immutable view of the Run's existing frozen context. sourceDigest
// describes that source snapshot; it is not an authenticity or permission proof.
// The Run snapshot codec persists this same immutable input, without a second
// catalog/version authority. Nested calls forward the same projection.
public class InvocationContextProjection {
    public let sourceDigest: String
    private let values: Array<InvocationContextContribution>

    public init(
        contributions!: Array<InvocationContextContribution> = [],
        sourceDigest!: String = ""
    ) {
        if (sourceDigest != "" && !validContextDigest(sourceDigest)) {
            throw IllegalArgumentException("context source digest must be SHA-256")
        }
        let snapshot = ArrayList<InvocationContextContribution>()
        for (contribution in contributions) {
            for (existing in snapshot where existing.owner == contribution.owner &&
                existing.id == contribution.id) {
                throw IllegalArgumentException("duplicate context contribution identity")
            }
            snapshot.add(contribution)
        }
        this.values = snapshot.toArray()
        this.sourceDigest = sourceDigest
    }

    public func contributions(): Array<InvocationContextContribution> {
        let result = ArrayList<InvocationContextContribution>()
        for (contribution in values) { result.add(contribution) }
        result.toArray()
    }

    public func contribution(owner: String, id: String): ?InvocationContextContribution {
        for (value in values where value.owner == owner && value.id == id) {
            return Some(value)
        }
        None
    }
}

func validContextIdentity(value: String): Bool {
    value.trimAscii() != "" && !value.contains("\u{0000}")
}

func validContextDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) {
            return false
        }
    }
    true
}
