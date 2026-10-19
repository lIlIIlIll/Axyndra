package agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import agent_sdk.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

// These names identify fields, not restored execution authority. Text leaves
// are compared in their actual private backing or copied to a paid byte owner.
public enum PluginRecordText { Locator | VersionLock | RevisionLock | IntegrityLock | ContentLock }
public enum PluginDescriptorText {
    Id | Namespace | Version | Source | Root | ManifestPath | OverlayPath |
    CompatibilityProfile | Entrypoint | SdkRange | ProtocolRange | ContentDigest |
    DeclaredContentDigest | Signature
}
public enum PluginComponentText { RelativePath | Name | Identity }
public enum PluginDependencyText { Name | VersionRange }
public enum PluginHookText { Event | Matcher | Command }
public enum PluginContributionText { Name | InputAttachmentField }
public enum PluginContributionDependencyText { Namespace | VersionRange | Name }
public enum PluginRegistryErrorText { Message | Source | Field }
public enum PluginRegistryStaticReason { None | MetadataCapacity | ExecutionNotCurrent | InstalledRecordAbsent | ComponentAliasInvalid }

public enum PluginRegistryResult<T> {
    Ok(T) | Err(PluginRegistryOwnedError)
    public func isOk(): Bool { match (this) { case Ok(_) => true; case Err(_) => false } }
}

// No String, Array or raw callback is exported. A receiver derives its actual
// copied-data payment BEFORE allocating its own String/DOM/private holder. The
// copy can outlive this byte owner, while both share the original Native bank.
public class OwnedRegistryUtf8 {
    private let lock = Mutex()
    private var bytes: ?Array<UInt8>
    private var payment: ?LogicalJsonOwnerReservation
    init(bytes: Array<UInt8>, payment: LogicalJsonOwnerReservation) {
        this.bytes = Some(bytes); this.payment = Some(payment)
    }
    public prop byteCount: Int64 {
        get() { lock.lock(); try { bytes.getOrThrow().size } finally { lock.unlock() } }
    }
    public func byteAt(index: Int64): UInt8 {
        lock.lock(); try { bytes.getOrThrow()[index] } finally { lock.unlock() }
    }
    public func deriveCopiedDataPayment(invoice: Int64): LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (invoice < 0 || invoice > 134217728) {
                throw LogicalJsonPayloadError("registry copied data invoice is outside its original aggregate")
            }
            let actual = payment.getOrThrow().deriveRetainedLease()
            try { actual.ensureRetainedPeak(invoice); actual }
            catch (error: Exception) { actual.close(); throw error }
        } finally { lock.unlock() }
    }
    public func close(): Unit {
        lock.lock()
        try {
            // A numeric borrow holds this lock until its real helper returns.
            // Private byte references are removed before any payment retires.
            bytes = None
            match (payment) { case Some(value) => payment = None; value.close(); case None => () }
        } finally { lock.unlock() }
    }
}

// Only package code can see raw records. The closed public handle keeps no raw
// leaf alive. Registry/pin scope closure clears this exact backing, including
// every descriptor/component view, before retiring its data payment.
class PluginRegistryOwnedBacking {
    private let lock = Mutex()
    private var record: ?RawProductPluginRecord
    private var descriptor: ?PluginPackageDescriptor
    private var error: ?PluginPackageError
    private var payment: ?PluginRegistryMetadataPayment
    private var viewCost: Int64 = 0
    init(record: RawProductPluginRecord, payment: PluginRegistryMetadataPayment) {
        this.record = Some(record); descriptor = None; error = None; this.payment = Some(payment)
    }
    init(descriptor: PluginPackageDescriptor, payment: PluginRegistryMetadataPayment) {
        record = None; this.descriptor = Some(descriptor); error = None; this.payment = Some(payment)
    }
    init(error: PluginPackageError, payment: PluginRegistryMetadataPayment) {
        record = None; descriptor = None; this.error = Some(error); this.payment = Some(payment)
    }
    func withRecord<T>(action: (RawProductPluginRecord) -> T): T {
        lock.lock(); try { requireOpen(); action(record.getOrThrow()) } finally { lock.unlock() }
    }
    func withDescriptor<T>(action: (PluginPackageDescriptor) -> T): T {
        lock.lock()
        try {
            requireOpen()
            match (record) { case Some(value) => action(value.descriptor); case None => action(descriptor.getOrThrow()) }
        } finally { lock.unlock() }
    }
    func withError<T>(action: (PluginPackageError) -> T): T {
        lock.lock(); try { requireOpen(); action(error.getOrThrow()) } finally { lock.unlock() }
    }
    private func requireOpen(): Unit {
        if (payment.isNone()) { throw LogicalJsonPayloadError("registry owned metadata is closed") }
    }
    func prepayView(): Unit {
        lock.lock()
        try {
            requireOpen()
            if (viewCost > 134217728 - 512) { throw LogicalJsonPayloadError("registry metadata views exceed their original aggregate") }
            payment.getOrThrow().growBy(512); viewCost += 512
        } finally { lock.unlock() }
    }
    // Called inside the actual synchronous package helper while its backing
    // remains locked. No unowned output crosses the public boundary.
    func copyTextLocked(text: String): OwnedRegistryUtf8 {
        requireOpen()
        let actual = payment.getOrThrow().deriveLogicalData(text.size * 8 + 2048)
        try { OwnedRegistryUtf8(text.toArray(), actual) }
        catch (error: Exception) { actual.close(); throw error }
    }
    func copyInvoiceLocked(invoice: Int64): LogicalJsonOwnerReservation {
        requireOpen(); payment.getOrThrow().deriveLogicalData(invoice)
    }
    func ownedError(code: String, message: String, source: String, field: String): PluginRegistryOwnedError {
        lock.lock()
        try {
            requireOpen()
            let actual = payment.getOrThrow().derivePayment()
            try {
                actual.ensureRetainedPeak((code.size + message.size + source.size + field.size) * 8 + 8192)
                let value = pluginOwnedErrorCopyFrame78(code, message, source, field)
                PluginRegistryOwnedError(code, Some(PluginRegistryOwnedBacking(value, actual)))
            } catch (error: Exception) { actual.close(); throw error }
        } finally { lock.unlock() }
    }
    func close(): Unit {
        lock.lock()
        try {
            record = None; descriptor = None; error = None
            match (payment) { case Some(value) => payment = None; value.close(); case None => () }
        } finally { lock.unlock() }
    }
}

public class ProductPluginRecord {
    private let backing: PluginRegistryOwnedBacking
    private let descriptorView: OwnedPluginPackageDescriptor
    init(backing: PluginRegistryOwnedBacking) {
        this.backing = backing; descriptorView = OwnedPluginPackageDescriptor(backing)
    }
    public prop descriptor: OwnedPluginPackageDescriptor { get() { descriptorView } }
    public prop enabled: Bool { get() { backing.withRecord({ value => value.enabled }) } }
    public prop explicitlyDisabled: Bool { get() { backing.withRecord({ value => value.explicitlyDisabled }) } }
    public prop importedAt: Int64 { get() { backing.withRecord({ value => value.importedAt }) } }
    public prop sourceKind: PluginSourceKind { get() { backing.withRecord({ value => value.sourceKind }) } }
    public prop scope: PluginInstallScope { get() { backing.withRecord({ value => value.scope }) } }
    public func textEquals(field: PluginRecordText, expected: String): Bool {
        backing.withRecord({ value => pluginOwnedRecordText(value, field) == expected })
    }
    public func descriptorTextEqualsRecord(descriptorField: PluginDescriptorText, recordField: PluginRecordText): Bool {
        backing.withRecord({ value => pluginOwnedDescriptorText(value.descriptor, descriptorField) == pluginOwnedRecordText(value, recordField) })
    }
    public func sameText(field: PluginRecordText, other: ProductPluginRecord, otherField: PluginRecordText): Bool {
        // Caller-owned handles have private immutable graphs. Obtain a paid
        // numeric copy instead of nesting two metadata locks in reverse order.
        let left = backing.withRecord({ value => backing.copyTextLocked(pluginOwnedRecordText(value, field)) })
        try { other.backing.withRecord({ value => pluginOwnedUtf8EqualsText(left, pluginOwnedRecordText(value, otherField)) }) }
        finally { left.close() }
    }
    public func copyText(field: PluginRecordText): PluginRegistryResult<OwnedRegistryUtf8> {
        try { PluginRegistryResult.Ok(backing.withRecord({ value => backing.copyTextLocked(pluginOwnedRecordText(value, field)) })) }
        catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
    public func copyJson(): PluginRegistryResult<OwnedRegistryUtf8> {
        try {
            PluginRegistryResult.Ok(backing.withRecord({ value =>
                let actual = backingCopyInvoice78(backing, pluginOwnedRecordInvoice78(value) * 8 + 65536)
                try { pluginOwnedRecordJsonFrame78(value, actual) }
                catch (error: Exception) { actual.close(); throw error }
            }))
        } catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
    func withRecord<T>(action: (RawProductPluginRecord) -> T): T { backing.withRecord(action) }
    public func ownedError(code: String, message: String, source!: String = "", field!: String = ""): PluginRegistryOwnedError {
        try { backing.ownedError(code, message, source, field) }
        catch (_: LogicalJsonPayloadError) { PluginRegistryOwnedError("plugin.registry_metadata_capacity", None) }
    }
    public func close(): Unit { backing.close() }
}

public class OwnedPluginPackageDescriptor {
    private let backing: PluginRegistryOwnedBacking
    init(backing: PluginRegistryOwnedBacking) { this.backing = backing }
    public func deriveCopiedDataPayment(invoice: Int64): LogicalJsonOwnerReservation {
        backing.withDescriptor({ _ => backing.copyInvoiceLocked(invoice) })
    }
    public prop ecosystem: PluginEcosystem { get() { backing.withDescriptor({ value => value.ecosystem }) } }
    public prop family: PluginManifestFamily { get() { backing.withDescriptor({ value => value.family }) } }
    public prop entryKind: PluginEntryKind { get() { backing.withDescriptor({ value => value.entryKind }) } }
    public func textEquals(field: PluginDescriptorText, expected: String): Bool {
        backing.withDescriptor({ value => pluginOwnedDescriptorText(value, field) == expected })
    }
    public func sameText(field: PluginDescriptorText, other: OwnedPluginPackageDescriptor, otherField: PluginDescriptorText): Bool {
        let left = backing.withDescriptor({ value => backing.copyTextLocked(pluginOwnedDescriptorText(value, field)) })
        try { other.backing.withDescriptor({ value => pluginOwnedUtf8EqualsText(left, pluginOwnedDescriptorText(value, otherField)) }) }
        finally { left.close() }
    }
    public func copyText(field: PluginDescriptorText): PluginRegistryResult<OwnedRegistryUtf8> {
        try { PluginRegistryResult.Ok(backing.withDescriptor({ value => backing.copyTextLocked(pluginOwnedDescriptorText(value, field)) })) }
        catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
    public prop componentCount: Int64 { get() { backing.withDescriptor({ value => value.components.size }) } }
    public func component(index: Int64): OwnedPluginComponent {
        backing.withDescriptor({ value => if (index < 0 || index >= value.components.size) { throw IndexOutOfBoundsException() } })
        backing.prepayView(); OwnedPluginComponent(backing, index)
    }
    public prop capabilityCount: Int64 { get() { backing.withDescriptor({ value => value.requestedCapabilities.size }) } }
    public func capabilityEquals(index: Int64, expected: String): Bool {
        backing.withDescriptor({ value => value.requestedCapabilities[index] == expected })
    }
    public func hasCapability(expected: String): Bool {
        backing.withDescriptor({ value =>
            for (capability in value.requestedCapabilities) { if (capability == expected) { return true } }; false
        })
    }
    public func copyCapability(index: Int64): PluginRegistryResult<OwnedRegistryUtf8> {
        try { PluginRegistryResult.Ok(backing.withDescriptor({ value => backing.copyTextLocked(value.requestedCapabilities[index]) })) }
        catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
    public prop dependencyCount: Int64 { get() { backing.withDescriptor({ value => value.dependencies.size }) } }
    public func dependency(index: Int64): OwnedPluginPackageDependency {
        backing.withDescriptor({ value => if (index < 0 || index >= value.dependencies.size) { throw IndexOutOfBoundsException() } })
        backing.prepayView(); OwnedPluginPackageDependency(backing, index)
    }
    public prop hookCount: Int64 { get() { backing.withDescriptor({ value => value.hookDeclarations.size }) } }
    public func hook(index: Int64): OwnedPluginHookDeclaration {
        backing.withDescriptor({ value => if (index < 0 || index >= value.hookDeclarations.size) { throw IndexOutOfBoundsException() } })
        backing.prepayView(); OwnedPluginHookDeclaration(backing, index)
    }
    public prop contributionCount: Int64 { get() { backing.withDescriptor({ value => value.contributions.size }) } }
    // Scalar data predicate only. No contribution view, String, Array or
    // authority leaves the existing locked immutable backing.
    public func hasContribution(kind: PluginContributionKind, name: String): Bool {
        backing.withDescriptor({ value =>
            var found = false
            for (item in value.contributions) {
                if (item.kind == kind && item.name == name) { found = true }
            }
            found
        })
    }
    // Closed scalar read under the actual private backing lock. No name,
    // contribution array, descriptor or callback leaves this original owner.
    public func hasToolExecutionProfile205(name: String, profile: PluginToolExecutionProfile): Bool {
        backing.withDescriptor({ value =>
            var found = false
            for (item in value.contributions) {
                if (item.kind == PluginContributionKind.Tool && item.name == name && item.executionProfile == profile) { found = true }
            }
            found
        })
    }
    public func contribution(index: Int64): OwnedPluginContribution {
        backing.withDescriptor({ value => if (index < 0 || index >= value.contributions.size) { throw IndexOutOfBoundsException() } })
        backing.prepayView(); OwnedPluginContribution(backing, index)
    }
    public prop componentDependencyCount: Int64 {
        get() { backing.withDescriptor({ value => value.componentDependencies.size }) }
    }
    public func componentDependency(index: Int64): OwnedPluginContributionDependency {
        // The existing getter clones at most 32 entries. Its full bounded
        // getter copy is prepaid before calling that original getter.
        backing.prepayView()
        backing.withDescriptor({ value => if (index < 0 || index >= value.componentDependencies.size) { throw IndexOutOfBoundsException() } })
        OwnedPluginContributionDependency(backing, index)
    }
    public prop missingDependencyCount: Int64 { get() { backing.withDescriptor({ value => value.missingDependencies.size }) } }
    public func copyMissingDependency(index: Int64): PluginRegistryResult<OwnedRegistryUtf8> {
        try { PluginRegistryResult.Ok(backing.withDescriptor({ value => backing.copyTextLocked(value.missingDependencies[index]) })) }
        catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
    public func copyDiagnosticJson(): PluginRegistryResult<OwnedRegistryUtf8> {
        try {
            PluginRegistryResult.Ok(backing.withDescriptor({ value =>
                let actual = backingCopyInvoice78(backing, pluginOwnedDescriptorInvoice78(value) * 8 + 65536)
                try { pluginOwnedDescriptorJsonFrame78(value, actual) }
                catch (error: Exception) { actual.close(); throw error }
            }))
        } catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
    public func copyCompleteJson(): PluginRegistryResult<OwnedRegistryUtf8> {
        try {
            PluginRegistryResult.Ok(backing.withDescriptor({ value =>
                let actual = backingCopyInvoice78(backing, pluginOwnedDescriptorInvoice78(value) * 8 + 65536)
                try { pluginOwnedCompleteDescriptorJsonFrame78(value, actual) }
                catch (error: Exception) { actual.close(); throw error }
            }))
        } catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
    public func close(): Unit { backing.close() }
}

public class OwnedPluginComponent {
    private let backing: PluginRegistryOwnedBacking
    private let index: Int64
    init(backing: PluginRegistryOwnedBacking, index: Int64) { this.backing = backing; this.index = index }
    public prop kind: PluginComponentKind { get() { backing.withDescriptor({ value => value.components[index].kind }) } }
    public prop status: PluginComponentStatus { get() { backing.withDescriptor({ value => value.components[index].status }) } }
    public prop dependencyCount: Int64 { get() { backing.withDescriptor({ value => value.components[index].dependencies.size }) } }
    public func textEquals(field: PluginComponentText, expected: String): Bool {
        backing.withDescriptor({ value => pluginOwnedComponentText(value.components[index], field) == expected })
    }
    public func copyText(field: PluginComponentText): PluginRegistryResult<OwnedRegistryUtf8> {
        try { PluginRegistryResult.Ok(backing.withDescriptor({ value => backing.copyTextLocked(pluginOwnedComponentText(value.components[index], field)) })) }
        catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
    public func copyDependency(selected: Int64): PluginRegistryResult<OwnedRegistryUtf8> {
        try { PluginRegistryResult.Ok(backing.withDescriptor({ value => backing.copyTextLocked(value.components[index].dependencies[selected]) })) }
        catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
}

public class OwnedPluginPackageDependency {
    private let backing: PluginRegistryOwnedBacking
    private let index: Int64
    init(backing: PluginRegistryOwnedBacking, index: Int64) { this.backing = backing; this.index = index }
    public prop optional: Bool { get() { backing.withDescriptor({ value => value.dependencies[index].optional }) } }
    public prop development: Bool { get() { backing.withDescriptor({ value => value.dependencies[index].development }) } }
    public func copyText(field: PluginDependencyText): PluginRegistryResult<OwnedRegistryUtf8> {
        try { PluginRegistryResult.Ok(backing.withDescriptor({ value =>
            let item = value.dependencies[index]
            backing.copyTextLocked(match (field) { case PluginDependencyText.Name => item.name; case PluginDependencyText.VersionRange => item.versionRange })
        })) } catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
}

public class OwnedPluginHookDeclaration {
    private let backing: PluginRegistryOwnedBacking
    private let index: Int64
    init(backing: PluginRegistryOwnedBacking, index: Int64) { this.backing = backing; this.index = index }
    public prop timeoutMillis: Int64 { get() { backing.withDescriptor({ value => value.hookDeclarations[index].timeoutMillis }) } }
    public func textEquals(field: PluginHookText, expected: String): Bool {
        backing.withDescriptor({ value => pluginOwnedHookText(value.hookDeclarations[index], field) == expected })
    }
    public func copyText(field: PluginHookText): PluginRegistryResult<OwnedRegistryUtf8> {
        try { PluginRegistryResult.Ok(backing.withDescriptor({ value => backing.copyTextLocked(pluginOwnedHookText(value.hookDeclarations[index], field)) })) }
        catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
}

public class OwnedPluginContribution {
    private let backing: PluginRegistryOwnedBacking
    private let index: Int64
    init(backing: PluginRegistryOwnedBacking, index: Int64) { this.backing = backing; this.index = index }
    public prop kind: PluginContributionKind { get() { backing.withDescriptor({ value => value.contributions[index].kind }) } }
    public prop supportsPreparationReference: Bool { get() { backing.withDescriptor({ value => value.contributions[index].supportsPreparationReference }) } }
    public prop executionProfile: PluginToolExecutionProfile { get() { backing.withDescriptor({ value => value.contributions[index].executionProfile }) } }
    public prop inputAttachmentMaxBytes: Int64 { get() { backing.withDescriptor({ value => value.contributions[index].inputAttachmentMaxBytes }) } }
    public func copyText(field: PluginContributionText): PluginRegistryResult<OwnedRegistryUtf8> {
        try { PluginRegistryResult.Ok(backing.withDescriptor({ value =>
            let item = value.contributions[index]
            backing.copyTextLocked(match (field) { case PluginContributionText.Name => item.name; case PluginContributionText.InputAttachmentField => item.inputAttachmentField })
        })) } catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
    public prop allowedControlCount: Int64 {
        get() { backing.prepayView(); backing.withDescriptor({ value => value.contributions[index].allowedUserControls().size }) }
    }
    public func copyAllowedControl(selected: Int64): PluginRegistryResult<OwnedRegistryUtf8> {
        try {
            backing.prepayView()
            PluginRegistryResult.Ok(backing.withDescriptor({ value => backing.copyTextLocked(value.contributions[index].allowedUserControls()[selected]) }))
        } catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
}

public class OwnedPluginContributionDependency {
    private let backing: PluginRegistryOwnedBacking
    private let index: Int64
    init(backing: PluginRegistryOwnedBacking, index: Int64) { this.backing = backing; this.index = index }
    public prop kind: PluginContributionKind {
        get() { backing.prepayView(); backing.withDescriptor({ value => value.componentDependencies[index].kind }) }
    }
    public func copyText(field: PluginContributionDependencyText): PluginRegistryResult<OwnedRegistryUtf8> {
        try {
            backing.prepayView()
            PluginRegistryResult.Ok(backing.withDescriptor({ value =>
                let item = value.componentDependencies[index]
                backing.copyTextLocked(match (field) {
                    case PluginContributionDependencyText.Namespace => item.namespace
                    case PluginContributionDependencyText.VersionRange => item.versionRange
                    case PluginContributionDependencyText.Name => item.name
                })
            }))
        } catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
}

public class OwnedPluginRecordList {
    private let lock = Mutex()
    private var records: ?Array<?ProductPluginRecord>
    private var payment: ?PluginRegistryMetadataPayment
    init(records: Array<?ProductPluginRecord>, payment: PluginRegistryMetadataPayment) {
        this.records = Some(records); this.payment = Some(payment)
    }
    public prop size: Int64 { get() { lock.lock(); try { records.getOrThrow().size } finally { lock.unlock() } } }
    public func isEmpty(): Bool { size == 0 }
    public func deriveCopiedDataPayment(invoice: Int64): LogicalJsonOwnerReservation {
        lock.lock(); try { payment.getOrThrow().deriveLogicalData(invoice) } finally { lock.unlock() }
    }
    public func at(index: Int64): ProductPluginRecord {
        lock.lock(); try { records.getOrThrow()[index].getOrThrow() } finally { lock.unlock() }
    }
    public func take(index: Int64): ProductPluginRecord {
        lock.lock()
        try {
            var selected = records.getOrThrow()
            let result = selected[index].getOrThrow()
            selected[index] = None<ProductPluginRecord>
            records = Some(selected)
            result
        } finally { lock.unlock() }
    }
    public func close(): Unit {
        lock.lock()
        try {
            match (records) { case Some(values) => for (value in values) { match (value) { case Some(actual) => actual.close(); case None => () } }; records = None; case None => () }
            match (payment) { case Some(value) => payment = None; value.close(); case None => () }
        } finally { lock.unlock() }
    }
}

public class PluginRegistryOwnedError {
    // All production codes are fixed categories, never parsed document data.
    public let code: String
    private let backing: ?PluginRegistryOwnedBacking
    private let reason: PluginRegistryStaticReason
    init(code: String, backing: ?PluginRegistryOwnedBacking,
        reason!: PluginRegistryStaticReason = PluginRegistryStaticReason.MetadataCapacity) {
        this.code = pluginRegistryStaticCode78(code); this.backing = backing; this.reason = reason
    }
    public prop staticReason: PluginRegistryStaticReason {
        get() { if (backing.isNone()) { reason } else { PluginRegistryStaticReason.None } }
    }
    public func textEquals(field: PluginRegistryErrorText, expected: String): Bool {
        match (backing) {
            case Some(value) => value.withError({ error => pluginOwnedErrorText(error, field) == expected })
            case None =>
                if (!fieldIsStaticMessage78(field)) { return expected == "" }
                match (reason) {
                    case PluginRegistryStaticReason.MetadataCapacity => expected == "registry metadata cannot fit the original shared capacity"
                    case PluginRegistryStaticReason.ExecutionNotCurrent => expected == "installed execution pin is not current"
                    case PluginRegistryStaticReason.InstalledRecordAbsent => expected == "installed record is absent"
                    case PluginRegistryStaticReason.ComponentAliasInvalid => expected == "initial context configuration or its exact installed binding is unavailable"
                    case PluginRegistryStaticReason.None => false
                }
        }
    }
    public func copyText(field: PluginRegistryErrorText): PluginRegistryResult<OwnedRegistryUtf8> {
        match (backing) {
            case Some(value) =>
                try { PluginRegistryResult.Ok(value.withError({ error => value.copyTextLocked(pluginOwnedErrorText(error, field)) })) }
                catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
            case None => pluginRegistryStaticFailure78(code)
        }
    }
    public func close(): Unit { match (backing) { case Some(value) => value.close(); case None => () } }
    public static func capacity(): PluginRegistryOwnedError { PluginRegistryOwnedError("plugin.registry_metadata_capacity", None) }
}

public class OwnedRegistryTextList {
    private let lock = Mutex()
    private var values: ?Array<String>
    private var payment: ?PluginRegistryMetadataPayment
    init(values: Array<String>, payment: PluginRegistryMetadataPayment) { this.values = Some(values); this.payment = Some(payment) }
    public prop size: Int64 { get() { lock.lock(); try { values.getOrThrow().size } finally { lock.unlock() } } }
    public func isEmpty(): Bool { size == 0 }
    public func contains(expected: String): Bool {
        lock.lock(); try { values.getOrThrow().contains(expected) } finally { lock.unlock() }
    }
    public func copyAt(index: Int64): PluginRegistryResult<OwnedRegistryUtf8> {
        lock.lock()
        try {
            let value = values.getOrThrow()[index]
            let actual = payment.getOrThrow().deriveLogicalData(value.size * 8 + 2048)
            try { PluginRegistryResult.Ok(OwnedRegistryUtf8(value.toArray(), actual)) }
            catch (error: Exception) { actual.close(); throw error }
        } catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
        finally { lock.unlock() }
    }
    public func copyJson(): PluginRegistryResult<OwnedRegistryUtf8> {
        lock.lock()
        try {
            let texts = values.getOrThrow(); var invoice: Int64 = 65536
            for (text in texts) { invoice = pluginRegistryInvoiceAdd78(invoice, text.size * 64 + 4096) }
            let actual = payment.getOrThrow().deriveLogicalData(invoice)
            try { PluginRegistryResult.Ok(pluginOwnedTextListJsonFrame78(texts, actual)) }
            catch (error: Exception) { actual.close(); throw error }
        } catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
        finally { lock.unlock() }
    }
    public func close(): Unit {
        lock.lock()
        try {
            values = None
            match (payment) { case Some(value) => payment = None; value.close(); case None => () }
        } finally { lock.unlock() }
    }
}

public class OwnedRegistryErrorList {
    private let lock = Mutex()
    private var values: ?Array<PluginRegistryOwnedError>
    private var payment: ?PluginRegistryMetadataPayment
    init(values: Array<PluginRegistryOwnedError>, payment: PluginRegistryMetadataPayment) { this.values = Some(values); this.payment = Some(payment) }
    public prop size: Int64 { get() { lock.lock(); try { values.getOrThrow().size } finally { lock.unlock() } } }
    public func isEmpty(): Bool { size == 0 }
    public func deriveCopiedDataPayment(invoice: Int64): LogicalJsonOwnerReservation {
        lock.lock(); try { payment.getOrThrow().deriveLogicalData(invoice) } finally { lock.unlock() }
    }
    public func at(index: Int64): PluginRegistryOwnedError { lock.lock(); try { values.getOrThrow()[index] } finally { lock.unlock() } }
    public func close(): Unit {
        lock.lock()
        try {
            match (values) { case Some(items) => for (item in items) { item.close() }; values = None; case None => () }
            match (payment) { case Some(value) => payment = None; value.close(); case None => () }
        } finally { lock.unlock() }
    }
}

// An explicit incoming DATA packet. It provides no raw output, borrowed getter
// or execution grant. Registry prepays and DEEP COPIES its complete graph before
// retaining any host-owned state; it never refunds the caller's original DTO.
public class PluginRegistryCallerRecordInput {
    private let lock = Mutex()
    private var value: ?RawProductPluginRecord
    public init(descriptor: PluginPackageDescriptor, sourceKind: PluginSourceKind, locator: String,
        versionLock: String, revisionLock: String, integrityLock: String, contentLock: String,
        enabled: Bool, importedAt: Int64, scope!: PluginInstallScope = PluginInstallScope.User,
        explicitlyDisabled!: Bool = false) {
        value = Some(RawProductPluginRecord(descriptor, sourceKind, locator, versionLock, revisionLock,
            integrityLock, contentLock, enabled, importedAt, scope: scope, explicitlyDisabled: explicitlyDisabled))
    }
    func withInput<T>(action: (RawProductPluginRecord) -> T): T {
        lock.lock(); try { action(value.getOrThrow()) } finally { lock.unlock() }
    }
    public func close(): Unit { lock.lock(); try { value = None } finally { lock.unlock() } }
}

func pluginOwnedTextListJsonFrame78(values: Array<String>, payment: LogicalJsonOwnerReservation): OwnedRegistryUtf8 {
    let text = jsonArray(values.map({ value => jsonString(value) })).stringify()
    OwnedRegistryUtf8(text.toArray(), payment)
}
func pluginOwnedErrorCopyFrame78(code: String, message: String, source: String, field: String): PluginPackageError {
    PluginPackageError(code, String.fromUtf8(message.toArray()),
        source: String.fromUtf8(source.toArray()), field: String.fromUtf8(field.toArray()))
}

// These package helpers are reached only after beforeCopiedRecord78 has paid
// the full occurrence SUM and all constructor/String/Array clone scratch.
// They never export a raw DTO to an owned-output caller.
func pluginOwnedDeepCopyText78(value: String): String { String.fromUtf8(value.toArray()) }
func pluginOwnedDeepCopyDescriptor78(value: PluginPackageDescriptor): PluginPackageDescriptor {
    let components = value.components.map({ item => PluginComponent(item.kind,
        pluginOwnedDeepCopyText78(item.relativePath), status: item.status,
        name: pluginOwnedDeepCopyText78(item.name), identity: pluginOwnedDeepCopyText78(item.identity),
        dependencies: item.dependencies.map({ text => pluginOwnedDeepCopyText78(text) })) })
    let dependencies = value.dependencies.map({ item => PluginPackageDependency(
        pluginOwnedDeepCopyText78(item.name), pluginOwnedDeepCopyText78(item.versionRange),
        optional: item.optional, development: item.development) })
    let hooks = value.hookDeclarations.map({ item => PluginHookDeclaration(pluginOwnedDeepCopyText78(item.event),
        pluginOwnedDeepCopyText78(item.matcher), pluginOwnedDeepCopyText78(item.command), item.timeoutMillis) })
    let componentDependencies = value.componentDependencies.map({ item => PluginContributionDependency(
        pluginOwnedDeepCopyText78(item.namespace), pluginOwnedDeepCopyText78(item.versionRange),
        item.kind, pluginOwnedDeepCopyText78(item.name)) })
    let contributions = value.contributions.map({ item => PluginContributionDefinition(pluginOwnedDeepCopyText78(item.name),
        item.kind, supportsPreparationReference: item.supportsPreparationReference,
        allowedUserControls: item.allowedUserControls().map({ text => pluginOwnedDeepCopyText78(text) }),
        executionProfile: item.executionProfile, inputAttachmentField: pluginOwnedDeepCopyText78(item.inputAttachmentField),
        inputAttachmentMaxBytes: item.inputAttachmentMaxBytes) })
    PluginPackageDescriptor(pluginOwnedDeepCopyText78(value.id), pluginOwnedDeepCopyText78(value.version),
        value.ecosystem, value.family, pluginOwnedDeepCopyText78(value.source),
        root: pluginOwnedDeepCopyText78(value.root), manifestPath: pluginOwnedDeepCopyText78(value.manifestPath),
        overlayPath: pluginOwnedDeepCopyText78(value.overlayPath), compatibilityProfile: pluginOwnedDeepCopyText78(value.compatibilityProfile),
        components: components, hookDeclarations: hooks, dependencies: dependencies, componentDependencies: componentDependencies,
        missingDependencies: value.missingDependencies.map({ text => pluginOwnedDeepCopyText78(text) }),
        entrypoint: pluginOwnedDeepCopyText78(value.entrypoint),
        requestedCapabilities: value.requestedCapabilities.map({ text => pluginOwnedDeepCopyText78(text) }),
        sdkRange: pluginOwnedDeepCopyText78(value.sdkRange), protocolRange: pluginOwnedDeepCopyText78(value.protocolRange),
        contentDigest: pluginOwnedDeepCopyText78(value.contentDigest), declaredContentDigest: pluginOwnedDeepCopyText78(value.declaredContentDigest),
        signature: pluginOwnedDeepCopyText78(value.signature), entryKind: value.entryKind, contributions: contributions)
}
func pluginOwnedDeepCopyRecord78(value: RawProductPluginRecord): RawProductPluginRecord {
    RawProductPluginRecord(pluginOwnedDeepCopyDescriptor78(value.descriptor), value.sourceKind,
        pluginOwnedDeepCopyText78(value.locator), pluginOwnedDeepCopyText78(value.versionLock),
        pluginOwnedDeepCopyText78(value.revisionLock), pluginOwnedDeepCopyText78(value.integrityLock),
        pluginOwnedDeepCopyText78(value.contentLock), value.enabled, value.importedAt,
        scope: value.scope, explicitlyDisabled: value.explicitlyDisabled)
}

func pluginRegistryStaticFailure78<T>(code: String,
    reason!: PluginRegistryStaticReason = PluginRegistryStaticReason.MetadataCapacity): PluginRegistryResult<T> {
    PluginRegistryResult.Err(PluginRegistryOwnedError(code, None, reason: reason))
}
func fieldIsStaticMessage78(field: PluginRegistryErrorText): Bool {
    match (field) { case PluginRegistryErrorText.Message => true; case _ => false }
}
func pluginOwnedErrorText(value: PluginPackageError, field: PluginRegistryErrorText): String {
    match (field) {
        case PluginRegistryErrorText.Message => value.message
        case PluginRegistryErrorText.Source => value.source
        case PluginRegistryErrorText.Field => value.field
    }
}
func pluginOwnedRecordText(value: RawProductPluginRecord, field: PluginRecordText): String {
    match (field) {
        case PluginRecordText.Locator => value.locator
        case PluginRecordText.VersionLock => value.versionLock
        case PluginRecordText.RevisionLock => value.revisionLock
        case PluginRecordText.IntegrityLock => value.integrityLock
        case PluginRecordText.ContentLock => value.contentLock
    }
}
func pluginOwnedDescriptorText(value: PluginPackageDescriptor, field: PluginDescriptorText): String {
    match (field) {
        case PluginDescriptorText.Id => value.id
        case PluginDescriptorText.Namespace => value.namespace
        case PluginDescriptorText.Version => value.version
        case PluginDescriptorText.Source => value.source
        case PluginDescriptorText.Root => value.root
        case PluginDescriptorText.ManifestPath => value.manifestPath
        case PluginDescriptorText.OverlayPath => value.overlayPath
        case PluginDescriptorText.CompatibilityProfile => value.compatibilityProfile
        case PluginDescriptorText.Entrypoint => value.entrypoint
        case PluginDescriptorText.SdkRange => value.sdkRange
        case PluginDescriptorText.ProtocolRange => value.protocolRange
        case PluginDescriptorText.ContentDigest => value.contentDigest
        case PluginDescriptorText.DeclaredContentDigest => value.declaredContentDigest
        case PluginDescriptorText.Signature => value.signature
    }
}
func pluginOwnedComponentText(value: PluginComponent, field: PluginComponentText): String {
    match (field) {
        case PluginComponentText.RelativePath => value.relativePath
        case PluginComponentText.Name => value.name
        case PluginComponentText.Identity => value.identity
    }
}
func pluginOwnedHookText(value: PluginHookDeclaration, field: PluginHookText): String {
    match (field) {
        case PluginHookText.Event => value.event
        case PluginHookText.Matcher => value.matcher
        case PluginHookText.Command => value.command
    }
}
func pluginOwnedUtf8EqualsText(value: OwnedRegistryUtf8, text: String): Bool {
    if (value.byteCount != text.size) { return false }
    // Text belongs to the locked private backing; this bounded temporary copy
    // is included in its prepaid formatter/copy extent.
    let bytes = text.toArray()
    for (index in 0..bytes.size) { if (value.byteAt(index) != bytes[index]) { return false } }; true
}

// Full per-occurrence invoices, including all old supported fields. Counting
// does not serialize the graph or clone an unbounded Array.
func pluginOwnedComponentInvoice78(value: PluginComponent): Int64 {
    var bytes = 2048 + (value.relativePath.size + value.name.size + value.identity.size) * 8
    for (text in value.dependencies) { bytes = pluginRegistryInvoiceAdd78(bytes, text.size * 8 + 512) }; bytes
}
func pluginOwnedDescriptorInvoice78(value: PluginPackageDescriptor): Int64 {
    var bytes: Int64 = 8192
    for (text in [value.id, value.namespace, value.version, value.source, value.root,
        value.manifestPath, value.overlayPath, value.compatibilityProfile, value.entrypoint,
        value.sdkRange, value.protocolRange, value.contentDigest, value.declaredContentDigest, value.signature]) {
        bytes = pluginRegistryInvoiceAdd78(bytes, text.size * 8 + 512)
    }
    for (item in value.components) { bytes = pluginRegistryInvoiceAdd78(bytes, pluginOwnedComponentInvoice78(item)) }
    for (item in value.dependencies) {
        bytes = pluginRegistryInvoiceAdd78(bytes, (item.name.size + item.versionRange.size) * 8 + 2048)
    }
    for (item in value.hookDeclarations) {
        bytes = pluginRegistryInvoiceAdd78(bytes, (item.event.size + item.matcher.size + item.command.size) * 8 + 2048)
    }
    // Existing componentDependencies/allowedUserControls getters have bounded
    // copies. Their full clone scratch is paid by the fixed header first.
    for (item in value.componentDependencies) {
        bytes = pluginRegistryInvoiceAdd78(bytes, (item.namespace.size + item.versionRange.size + item.name.size) * 8 + 2048)
    }
    for (item in value.contributions) {
        bytes = pluginRegistryInvoiceAdd78(bytes, (item.name.size + item.inputAttachmentField.size) * 8 + 2048)
        for (text in item.allowedUserControls()) { bytes = pluginRegistryInvoiceAdd78(bytes, text.size * 8 + 512) }
    }
    for (text in value.missingDependencies) { bytes = pluginRegistryInvoiceAdd78(bytes, text.size * 8 + 512) }
    for (text in value.requestedCapabilities) { bytes = pluginRegistryInvoiceAdd78(bytes, text.size * 8 + 512) }; bytes
}
func pluginOwnedRecordInvoice78(value: RawProductPluginRecord): Int64 {
    var bytes = pluginOwnedDescriptorInvoice78(value.descriptor) + 4096
    for (text in [value.locator, value.versionLock, value.revisionLock, value.integrityLock, value.contentLock]) {
        bytes = pluginRegistryInvoiceAdd78(bytes, text.size * 8 + 512)
    }; bytes
}
func pluginRegistryInvoiceAdd78(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || right > 134217728 - left) {
        throw LogicalJsonPayloadError("registry metadata exceeds its original aggregate")
    }; left + right
}

func backingCopyInvoice78(backing: PluginRegistryOwnedBacking, invoice: Int64): LogicalJsonOwnerReservation {
    backing.copyInvoiceLocked(invoice)
}
func pluginOwnedDescriptorJsonFrame78(value: PluginPackageDescriptor, payment: LogicalJsonOwnerReservation): OwnedRegistryUtf8 {
    let text = pluginPackageDiagnosticValue(value).stringify()
    OwnedRegistryUtf8(text.toArray(), payment)
}
func pluginOwnedCompleteDescriptorJsonFrame78(value: PluginPackageDescriptor, payment: LogicalJsonOwnerReservation): OwnedRegistryUtf8 {
    let text = pluginOwnedCompleteDescriptorValue78(value).stringify()
    OwnedRegistryUtf8(text.toArray(), payment)
}
func pluginOwnedCompleteDescriptorValue78(value: PluginPackageDescriptor): JsonNode {
    let components = ArrayList<JsonNode>()
    for (item in value.components) {
        components.add(jsonObject([
            JsonObjectEntry("kind", jsonString(registryContextComponentKind(item.kind))),
            JsonObjectEntry("status", jsonString(match (item.status) {
                case PluginComponentStatus.Supported => "supported"
                case PluginComponentStatus.Blocked => "blocked"
                case PluginComponentStatus.Unsupported => "unsupported"
                case PluginComponentStatus.Unverified => "unverified"
            })),
            JsonObjectEntry("relative_path", jsonString(item.relativePath)),
            JsonObjectEntry("name", jsonString(item.name)),
            JsonObjectEntry("identity", jsonString(item.identity)),
            JsonObjectEntry("dependencies", jsonArray(item.dependencies.map({ text => jsonString(text) })))
        ]))
    }
    let dependencies = ArrayList<JsonNode>()
    for (item in value.dependencies) {
        dependencies.add(jsonObject([
            JsonObjectEntry("name", jsonString(item.name)),
            JsonObjectEntry("version_range", jsonString(item.versionRange)),
            JsonObjectEntry("optional", jsonBool(item.optional)),
            JsonObjectEntry("development", jsonBool(item.development))
        ]))
    }
    let hooks = ArrayList<JsonNode>()
    for (item in value.hookDeclarations) {
        hooks.add(jsonObject([
            JsonObjectEntry("event", jsonString(item.event)),
            JsonObjectEntry("matcher", jsonString(item.matcher)),
            JsonObjectEntry("command", jsonString(item.command)),
            JsonObjectEntry("timeout_millis", jsonNumber(item.timeoutMillis.toString()))
        ]))
    }
    let componentDependencies = ArrayList<JsonNode>()
    for (item in value.componentDependencies) {
        componentDependencies.add(jsonObject([
            JsonObjectEntry("namespace", jsonString(item.namespace)),
            JsonObjectEntry("version_range", jsonString(item.versionRange)),
            JsonObjectEntry("kind", jsonString(pluginContributionKindName(item.kind))),
            JsonObjectEntry("name", jsonString(item.name))
        ]))
    }
    let contributions = ArrayList<JsonNode>()
    for (item in value.contributions) {
        contributions.add(jsonObject([
            JsonObjectEntry("kind", jsonString(pluginContributionKindName(item.kind))),
            JsonObjectEntry("name", jsonString(item.name)),
            JsonObjectEntry("supports_preparation_reference", jsonBool(item.supportsPreparationReference)),
            JsonObjectEntry("allowed_user_controls", jsonArray(item.allowedUserControls().map({ text => jsonString(text) }))),
            JsonObjectEntry("input_attachment_field", jsonString(item.inputAttachmentField)),
            JsonObjectEntry("input_attachment_max_bytes", jsonNumber(item.inputAttachmentMaxBytes.toString())),
            JsonObjectEntry("execution_profile", jsonString(match (item.executionProfile) {
                case PluginToolExecutionProfile.Brokered => "brokered"
                case PluginToolExecutionProfile.DataOnly => "data_only"
            }))
        ]))
    }
    jsonObject([
        JsonObjectEntry("id", jsonString(value.id)),
        JsonObjectEntry("namespace", jsonString(value.namespace)),
        JsonObjectEntry("version", jsonString(value.version)),
        JsonObjectEntry("ecosystem", jsonString(match (value.ecosystem) { case PluginEcosystem.Pi => "pi"; case PluginEcosystem.Codex => "codex"; case PluginEcosystem.Axyndra => "axyndra" })),
        JsonObjectEntry("family", jsonString(match (value.family) { case PluginManifestFamily.Pi => "pi"; case PluginManifestFamily.Codex => "codex"; case PluginManifestFamily.Axyndra => "axyndra" })),
        JsonObjectEntry("source", jsonString(value.source)),
        JsonObjectEntry("root", jsonString(value.root)),
        JsonObjectEntry("manifest_path", jsonString(value.manifestPath)),
        JsonObjectEntry("overlay_path", jsonString(value.overlayPath)),
        JsonObjectEntry("compatibility_profile", jsonString(value.compatibilityProfile)),
        JsonObjectEntry("components", jsonArray(components.toArray())),
        JsonObjectEntry("dependencies", jsonArray(dependencies.toArray())),
        JsonObjectEntry("hook_declarations", jsonArray(hooks.toArray())),
        JsonObjectEntry("component_dependencies", jsonArray(componentDependencies.toArray())),
        JsonObjectEntry("missing_dependencies", jsonArray(value.missingDependencies.map({ text => jsonString(text) }))),
        JsonObjectEntry("entrypoint", jsonString(value.entrypoint)),
        JsonObjectEntry("entry_kind", jsonString(pluginEntryKindName(value.entryKind))),
        JsonObjectEntry("contributions", jsonArray(contributions.toArray())),
        JsonObjectEntry("requested_capabilities", jsonArray(value.requestedCapabilities.map({ text => jsonString(text) }))),
        JsonObjectEntry("sdk_range", jsonString(value.sdkRange)),
        JsonObjectEntry("protocol_range", jsonString(value.protocolRange)),
        JsonObjectEntry("content_digest", jsonString(value.contentDigest)),
        JsonObjectEntry("declared_content_digest", jsonString(value.declaredContentDigest)),
        JsonObjectEntry("signature", jsonString(value.signature))
    ])
}
func pluginOwnedRecordJsonFrame78(value: RawProductPluginRecord, payment: LogicalJsonOwnerReservation): OwnedRegistryUtf8 {
    let text = jsonObject([
        JsonObjectEntry("namespace", jsonString(value.descriptor.namespace)),
        JsonObjectEntry("id", jsonString(value.descriptor.id)),
        JsonObjectEntry("version", jsonString(value.descriptor.version)),
        JsonObjectEntry("root", jsonString(value.descriptor.root)),
        JsonObjectEntry("source_kind", jsonString(pluginSourceKindName(value.sourceKind))),
        JsonObjectEntry("scope", jsonString(pluginScopeName(value.scope))),
        JsonObjectEntry("locator", jsonString(value.locator)),
        JsonObjectEntry("version_lock", jsonString(value.versionLock)),
        JsonObjectEntry("revision", jsonString(value.revisionLock)),
        JsonObjectEntry("integrity", jsonString(value.integrityLock)),
        JsonObjectEntry("content_digest", jsonString(value.contentLock)),
        JsonObjectEntry("enabled", jsonBool(value.enabled)),
        JsonObjectEntry("explicitly_disabled", jsonBool(value.explicitlyDisabled)),
        JsonObjectEntry("imported_at", jsonNumber(value.importedAt.toString())),
        JsonObjectEntry("descriptor", pluginOwnedCompleteDescriptorValue78(value.descriptor))
    ]).stringify()
    OwnedRegistryUtf8(text.toArray(), payment)
}
