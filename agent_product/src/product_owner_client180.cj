package agent_product

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.sync.*
import std.net.*
import process4cj.*

// One actual client controller owns its private full frontend helper. A failed
// factory, spawn, writer or cleanup remains in this bounded concrete registry.
private let ownerClientRegistryLock180 = Mutex()
private var ownerClientRegistry180: ?ActualOwnerClientRegistry180 = None<ActualOwnerClientRegistry180>
private var ownerClientRegistryPending180: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>

class ActualOwnerClientRegistry180 {
    private let paid: LogicalJsonOwnerReservation
    private let slots: Array<?ActualOwnerClientRoot180>
    private let lock = Mutex()
    private var pendingPayment180: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var pendingData180: ?ActualProcessBrokerData180 = None<ActualProcessBrokerData180>
    private var pendingConfig180: ?ProductConfig = None<ProductConfig>
    private var pendingRequest180: ?AgentValue = None<AgentValue>
    private var pendingFactory180: ?(ProductOwnerPeer180) -> ProductOwnerClientFrontend180 = None<(ProductOwnerPeer180) -> ProductOwnerClientFrontend180>
    init(paid: LogicalJsonOwnerReservation) {
        this.paid = paid; slots = Array<?ActualOwnerClientRoot180>(32, repeat: None<ActualOwnerClientRoot180>)
    }
    func runActualClient180(config: ProductConfig, request: AgentValue,
        create: (ProductOwnerPeer180) -> ProductOwnerClientFrontend180,
        allocate: (Int64) -> LogicalJsonOwnerReservation): Int64 {
        lock.lock()
        let selected: Int64
        let root: ActualOwnerClientRoot180
        try {
            var vacant: Int64 = -1
            for (index in 0..slots.size) { if (slots[index].isNone()) { vacant = index; break } }
            if (pendingPayment180.isSome() || pendingData180.isSome()) { return 1 }
            if (vacant < 0) { return 1 }
            let loan = allocate(65536)
            pendingPayment180 = Some(loan); pendingConfig180 = Some(config); pendingRequest180 = Some(request); pendingFactory180 = Some(create)
            let data = ActualProcessBrokerData180(loan); pendingData180 = Some(data); data.fundValue(request)
            root = ActualOwnerClientRoot180(data, config, request, create)
            selected = vacant; slots[selected] = Some(root)
            pendingPayment180 = None<LogicalJsonOwnerReservation>; pendingData180 = None<ActualProcessBrokerData180>
            pendingConfig180 = None<ProductConfig>; pendingRequest180 = None<AgentValue>; pendingFactory180 = None<(ProductOwnerPeer180) -> ProductOwnerClientFrontend180>

        } finally { lock.unlock() }
        let result = root.runOriginalPrivateClient180()
        if (root.retireAfterOriginalPrivateClient180()) {
            lock.lock(); try { slots[selected] = None<ActualOwnerClientRoot180> } finally { lock.unlock() }
        } else { return 1 }
        result
    }
}

class ActualOwnerClientRoot180 {
    private let data: ActualProcessBrokerData180
    private var configuration: ?ProductConfig
    private var request: ?AgentValue
    private var factory: ?(ProductOwnerPeer180) -> ProductOwnerClientFrontend180
    private var broker: ?ProductProcessBroker = None<ProductProcessBroker>
    private var peer: ?ActualProductOwnerPeer180 = None<ActualProductOwnerPeer180>
    private var frontend: ?ProductOwnerClientFrontend180 = None<ProductOwnerClientFrontend180>
    private var socket180: ?UnixSocket = None<UnixSocket>
    private var rendezvous180: ?ActualOwnerFrontendRendezvous180 = None<ActualOwnerFrontendRendezvous180>
    private var failure: ?Exception = None<Exception>
    private var diagnosticFailure180: ?Exception = None<Exception>
    private var originalHelperReturned180 = false
    init(data: ActualProcessBrokerData180, configuration: ProductConfig, request: AgentValue,
        factory: (ProductOwnerPeer180) -> ProductOwnerClientFrontend180) {
        this.data = data; this.configuration = Some(configuration); this.request = Some(request); this.factory = Some(factory)
    }
    func installPhysicalPeerBeforeConnect180(value: ActualProductOwnerPeer180): Unit { peer = Some(value) }
    func installPhysicalSocketBeforePeerConstruction180(value: UnixSocket): Unit { socket180 = Some(value) }
    func currentData180(): ActualProcessBrokerData180 { data }
    private let cleanupFailures180 = Array<?Exception>(3, repeat: None<Exception>)
    func runOriginalPrivateClient180(): Int64 {
        var result: Int64 = 1
        try { result = invokeOriginalWholeClientHelper180(); originalHelperReturned180 = true }
        catch (error: OwnedCanonicalDataFailure113) { failure = Some(error); emitOriginalFailure180(error.error.describe()) }
        catch (error: Exception) { failure = Some(error); emitOriginalFailure180("owner.frontend_failed: " + error.message) }
        closeOriginalClientHelpers180()
        for (error in cleanupFailures180) { if (error.isSome()) { return 1 } }
        result
    }
    private func closeOriginalClientHelpers180(): Unit {
        // Physical close unblocks reads. All three actual cleanup helpers run
        // even when an earlier helper failed; each original exception is held.
        try { match (peer) { case Some(actual) => match (actual.closeOwnerPeer180()) {
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(_) => () }; case None => () } }
        catch (error: Exception) { cleanupFailures180[0] = Some(error) }
        try { match (frontend) { case Some(actual) => match (actual.closeOwnerClientFrontend180()) {
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(_) => () }; case None => () } }
        catch (error: Exception) { cleanupFailures180[1] = Some(error) }
        try { match (peer) { case Some(actual) => match (actual.closeConcreteFrontendHelper180()) {
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(_) => () }; case None => () } }
        catch (error: Exception) { cleanupFailures180[2] = Some(error) }
    }

    private func emitOriginalFailure180(message: String): Unit {
        try { writeFdUtf8Checked182(2, message + "\n") }
        catch (error: Exception) { diagnosticFailure180 = Some(error) }
    }
    private func invokeOriginalWholeClientHelper180(): Int64 {
        let config = configuration.getOrThrow()

        let workspace = LocalWorkspace(config.workspaceRoot).rootPath()
        data.fund(65536 + workspace.size * 2, 64)
        let actualBroker = ProductProcessBroker(config.stateRoot, workspace, configuration180: Some(config))
        broker = Some(actualBroker)
        let actualPeer = match (actualBroker.openFrontend180(request.getOrThrow(), this)) {
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(value) => value }
        let actualFrontend = factory.getOrThrow()(actualPeer)
        frontend = Some(actualFrontend)
        let exit = actualFrontend.runOwnerClientFrontend180()
        exit
    }
    func retireAfterOriginalPrivateClient180(): Bool {
        if (!originalHelperReturned180 || failure.isSome()) { return false }
        for (error in cleanupFailures180) { if (error.isSome()) { return false } }
        let result = retireOriginalPeerHelper180()
        match (result) { case Result.Err(error) => failure = Some(OwnedCanonicalDataFailure113(error)); return false; case Result.Ok(_) => () }
        frontend = None<ProductOwnerClientFrontend180>; peer = None<ActualProductOwnerPeer180>; socket180 = None<UnixSocket>
        try {
            // The original frontend, physical peer and all its helpers have
            // returned before registering this separate scalar observation.
            rendezvous180 = Some(broker.getOrThrow().newFrontendRendezvous180(data))
            let debt = rendezvous180.getOrThrow().observeWholeHelper180()
            rendezvous180.getOrThrow().closeAfterWholeObservation180()
            if (!debt) { rendezvous180.getOrThrow().waitForOriginalPhysicalReturn180() }
            rendezvous180 = None<ActualOwnerFrontendRendezvous180>
        } catch (error: Exception) {
            failure = Some(error); emitOriginalFailure180("owner.shutdown_pending: " + error.message); return false
        }
        broker = None<ProductProcessBroker>
        factory = None<(ProductOwnerPeer180) -> ProductOwnerClientFrontend180>; request = None<AgentValue>; configuration = None<ProductConfig>
        data.retireAfterWholeHandler180(); true
    }
    private func retireOriginalPeerHelper180(): Result<Unit> {
        match (peer) { case Some(actual) => actual.retireAfterOriginalEnclosingHelpers180(); case None => Result.Ok(()) }
    }
}

public func runProductOwnerClientFrontend180(configuration: ProductConfig, request: AgentValue,
    create: (ProductOwnerPeer180) -> ProductOwnerClientFrontend180,
    allocate!: (Int64) -> LogicalJsonOwnerReservation): Int64 {
    ownerClientRegistryLock180.lock()
    let registry = try {
        if (ownerClientRegistry180.isNone()) {
            let paid = allocate(262144); ownerClientRegistryPending180 = Some(paid)
            let actual = ActualOwnerClientRegistry180(paid); ownerClientRegistry180 = Some(actual)
            ownerClientRegistryPending180 = None<LogicalJsonOwnerReservation>
        }
        ownerClientRegistry180.getOrThrow()
    } finally { ownerClientRegistryLock180.unlock() }
    registry.runActualClient180(configuration, request, create, allocate)
}

