package agent_tui

import std.sync.*

// Presentation DATA only. This capsule grants no Source, Tool or execution
// permission. The concrete producer/receiver supplies its existing bank loan;
// this type never constructs a bank or infers an output acknowledgement.
public class TuiPluginViewDocument {
    private var metadata: ?String
    private var model: ?String
    private var primary: ?String
    private var reserve: ?(Int64) -> Unit
    private var retire: ?() -> Unit
    private let lock = Mutex()
    private var closed = false
    private var consumers: Int64 = 0

    public init(metadataJson: String, modelJson: String, primaryContent: String,
        reserveUi: (Int64) -> Unit, retireSource: () -> Unit) {
        metadata = Some(metadataJson); model = Some(modelJson); primary = Some(primaryContent)
        reserve = Some(reserveUi); retire = Some(retireSource)
    }
    // Borrowed values. The trusted renderer must clear its model, editor and
    // layout references in a whole helper before closing this document.
    public func metadataJson(): String {
        lock.lock(); try { metadata.getOrThrow() } finally { lock.unlock() }
    }
    public func modelJson(): String {
        lock.lock(); try { model.getOrThrow() } finally { lock.unlock() }
    }
    public func primaryContent(): String {
        lock.lock(); try { primary.getOrThrow() } finally { lock.unlock() }
    }
    public func reserveUiBytes(peak: Int64): Unit {
        lock.lock()
        try {
            if (closed || peak < 0) { throw IllegalStateException("view.presentation_closed") }
            reserve.getOrThrow()(peak)
        } finally { lock.unlock() }
    }
    public func withPresentation<T>(consume: (String, String, String) -> T): T {
        lock.lock()
        try {
            if (closed) { throw IllegalStateException("view.presentation_closed") }
            consumers++
        } finally { lock.unlock() }
        try { consumePresentationHelper(consume) }
        finally { presentationHelperReturned() }
    }
    public func captureFields(build: () -> Array<TuiPluginViewField>): TuiPluginViewFields {
        lock.lock()
        try {
            if (closed) { throw IllegalStateException("view.presentation_closed") }
            consumers++
        } finally { lock.unlock() }
        try { TuiPluginViewFields(build(), { => presentationHelperReturned() }) }
        catch (error: Exception) { presentationHelperReturned(); throw error }
    }
    private func consumePresentationHelper<T>(consume: (String, String, String) -> T): T {
        consume(metadata.getOrThrow(), model.getOrThrow(), primary.getOrThrow())
    }
    private func presentationHelperReturned(): Unit {
        lock.lock()
        let callback = try { consumers--; takeRetirementLocked() } finally { lock.unlock() }
        match (callback) { case Some(actual) => actual(); case None => () }
    }
    public func close(): Unit {
        lock.lock()
        let callback = try { closed = true; takeRetirementLocked() } finally { lock.unlock() }
        match (callback) { case Some(actual) => actual(); case None => () }
    }
    private func takeRetirementLocked(): ?() -> Unit {
        if (!closed || consumers != 0 || retire.isNone()) { return None<() -> Unit> }
        metadata = None; model = None; primary = None; reserve = None
        let callback = retire; retire = None
        callback
    }
}

public class TuiPluginViewField {
    public let id: String
    public let value: String
    public init(id: String, value: String) { this.id = id; this.value = value }
}

// A real asynchronous user-input producer holds the presentation's DATA
// invoice until its complete backend/send helper has returned. Task closures
// retain this empty capsule after close, not the original large fields.
public class TuiPluginViewFields {
    private var values: ?Array<TuiPluginViewField>
    private var release: ?() -> Unit
    private let lock = Mutex()
    private var readers: Int64 = 0
    private var closed = false
    init(values: Array<TuiPluginViewField>, release: () -> Unit) {
        this.values = Some(values); this.release = Some(release)
    }
    public func withFields<T>(consume: (Array<TuiPluginViewField>) -> T): T {
        lock.lock()
        try {
            if (closed) { throw IllegalStateException("view.fields_closed") }
            readers++
        } finally { lock.unlock() }
        try { fieldsHelper(consume) }
        finally {
            lock.lock()
            let callback = try { readers--; takeRetirementLocked() } finally { lock.unlock() }
            match (callback) { case Some(actual) => actual(); case None => () }
        }
    }
    private func fieldsHelper<T>(consume: (Array<TuiPluginViewField>) -> T): T {
        consume(values.getOrThrow())
    }
    public func close(): Unit {
        lock.lock()
        let callback = try { closed = true; takeRetirementLocked() } finally { lock.unlock() }
        match (callback) { case Some(actual) => actual(); case None => () }
    }
    private func takeRetirementLocked(): ?() -> Unit {
        if (!closed || readers != 0 || release.isNone()) { return None<() -> Unit> }
        values = None
        let callback = release; release = None
        callback
    }
}
