package agent_product

import agent_domain.*
import std.env.*
import std.fs.*
import std.net.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

// These use the actual Unix reader and an independent standard 144-MiB bank.
// A refused cleanup deliberately stays charged in its own test bank; it must
// not consume a later test's shared production capacity or fake a DATA ACK.
private func ownerLifetimeReadFrame180(peer: ActualProductOwnerPeer180,
    paid: LogicalJsonOwnerReservation, lifetime: Bool, expected: String,
    expired: Bool): (Bool, Bool) {
    let deadline = if (expired) { Some(MonoTime.now()) } else { None<MonoTime> }
    let result = if (lifetime) { peer.readOwnerLifetimeFrame180(paid, deadline) }
        else { peer.readOwnerFrame180(paid, deadline) }
    let matched = match (result) {
        case Result.Err(error) => error.code == expected
        case Result.Ok(value) => expected == "complete" && value == "{\"otherDebt\":false}"
    }
    match (peer.closeOwnerPeer180()) {
        case Result.Err(error) => throw IllegalStateException(error.code)
        case Result.Ok(_) => ()
    }
    (matched, peer.retireAfterOriginalEnclosingHelpers180().isOk())
}

private func ownerLifetimeSocketCase180(lifetime: Bool, reset: Bool, body: Array<Byte>,
    expected: String, clean: Bool, expired!: Bool = false, authenticated!: Bool = false): Unit {
    let parent = match (getVariable("TMPDIR")) { case Some(value) => value; case None => "/tmp" }
    let root = Directory.createTemp(parent).toString()
    let listener = UnixServerSocket(bindAt: root + "/owner.sock")
    let client = UnixSocket(root + "/owner.sock")
    let bank = LogicalJsonOwnerBudget()
    let data = ActualProcessBrokerData180(bank.acquire(65536))
    let paid = data.derive(65536)
    let peer = ActualProductOwnerPeer180(client, data, ProductConfig(), 4096, 4096)
    try {
        listener.bind()
        client.connect(timeout: Some(Duration.second * 5))
        let remote = listener.accept(timeout: Some(Duration.second * 5))
        try {
            peer.initializePhysicalPeer180()
            match (peer.writeOwnerFrame180("probe", None<MonoTime>)) {
                case Result.Err(error) => throw IllegalStateException(error.code)
                case Result.Ok(_) => ()
            }
            if (!reset) {
                // Drain the exact original request before an orderly EOF.
                // Leaving it unread produces a real Unix connection reset.
                let input = Array<Byte>(6, repeat: 0)
                var consumed: Int64 = 0
                while (consumed < 6) {
                    let count = remote.read(input)
                    if (count <= 0) { throw IllegalStateException("fixture request ended before its newline") }
                    consumed += count
                }
            }
            if (body.size > 0) { remote.write(body) }
        } finally { remote.close() }
        if (authenticated) { peer.enableAuthenticatedIdle180() }
        let (matched, retired) = ownerLifetimeReadFrame180(peer, paid, lifetime, expected, expired)
        @Expect(matched)
        @Expect(retired, clean)
        if (retired) {
            // The actual reader/result helper has returned; its peer fields
            // are cleared and only scalar observations escaped that frame.
            paid.close()
            data.retireAfterWholeHandler180()
            @Expect(bank.usage()[1], 0)
        } else {
            @Expect(bank.usage()[1], 16777216)
        }
    } finally {
        let _ = peer.closeOwnerPeer180()
        listener.close()
        remove(root, recursive: true)
    }
}

@Test
class ProductOwnerLifetimeReadTests {
    @TestCase
    func emptyLifetimeResetReturnsOnlyAbsenceAfterRealReaderReturn(): Unit {
        ownerLifetimeSocketCase180(true, true, [], "owner.peer_lifetime_absent", true)
    }
    @TestCase
    func ordinaryEmptyResetKeepsItsOriginalUnknownDebt(): Unit {
        ownerLifetimeSocketCase180(false, true, [], "owner.peer_read_failed", false)
    }
    @TestCase
    func partialLifetimeResetNeverBecomesAnEmptyObservation(): Unit {
        ownerLifetimeSocketCase180(true, true, "{".toArray(), "owner.peer_read_failed", false)
    }
    @TestCase
    func emptyLifetimeEofHasNoOriginalFrameToRetain(): Unit {
        ownerLifetimeSocketCase180(true, false, [], "owner.peer_lifetime_absent", true)
    }
    @TestCase
    func ordinaryEmptyEofPreservesItsOriginalDisconnectContract(): Unit {
        ownerLifetimeSocketCase180(false, false, [], "owner.peer_disconnected", true)
    }
    @TestCase
    func partialLifetimeEofKeepsItsUnconsumedPhysicalBytes(): Unit {
        ownerLifetimeSocketCase180(true, false, "{".toArray(), "owner.peer_frame_incomplete", false)
    }
    @TestCase
    func invalidLifetimeUtf8KeepsItsUnconsumedPhysicalBytes(): Unit {
        ownerLifetimeSocketCase180(true, false, [255u8, 10u8], "owner.peer_read_failed", false)
    }
    @TestCase
    func completeLifetimeResponseSurvivesThePhysicalReader(): Unit {
        ownerLifetimeSocketCase180(true, false, "{\"otherDebt\":false}\n".toArray(), "complete", true)
    }
    @TestCase
    func expiredLifetimeDeadlineIsStillTimeoutNotAbsence(): Unit {
        ownerLifetimeSocketCase180(true, false, [], "owner.peer_frame_timeout", true, expired: true)
    }
    @TestCase
    func authenticatedFrontendCannotOptIntoLifetimeAbsence(): Unit {
        ownerLifetimeSocketCase180(true, false, [], "owner.peer_lifetime_consumer", true, authenticated: true)
    }
}
