package agent_store

import agent_domain.*
import stdx.crypto.digest.SHA256
import std.sync.*

// Package-private physical data IO. It cannot select a path/table/column or
// create a Source, prepared child, execution admission, or settlement receipt.
enum FixedJournalWritableCell { CurrentPayload | EventPayload | RunEventPayload }

class FixedJournalTextWriteObservation {
    let bytes: Int64
    let digest: String
    init(bytes: Int64, digest: String) { this.bytes=bytes; this.digest=digest }
}

// Complete UTF8 validation across arbitrary producer chunk boundaries without
// making a whole managed String. The old payload codec remains the producer's.
class FixedJournalTextUtf8 {
    private var remaining: Int64=0
    private var lower: Byte=128
    private var upper: Byte=191
    func write(bytes: Array<Byte>): Unit {
        for (byte in bytes) {
            if (remaining>0) {
                if (byte<lower || byte>upper) {
                    throw IllegalStateException("fixed journal text has invalid UTF8") }
                remaining--; lower=128; upper=191
            } else if (byte<=127) { () }
            else if (byte>=194 && byte<=223) { remaining=1; lower=128; upper=191 }
            else if (byte==224) { remaining=2; lower=160; upper=191 }
            else if (byte>=225 && byte<=236) { remaining=2; lower=128; upper=191 }
            else if (byte==237) { remaining=2; lower=128; upper=159 }
            else if (byte>=238 && byte<=239) { remaining=2; lower=128; upper=191 }
            else if (byte==240) { remaining=3; lower=144; upper=191 }
            else if (byte>=241 && byte<=243) { remaining=3; lower=128; upper=191 }
            else if (byte==244) { remaining=3; lower=128; upper=143 }
            else { throw IllegalStateException("fixed journal text has invalid UTF8") }
        }
    }
    func finish(): Unit {
        if (remaining!=0) { throw IllegalStateException("fixed journal text ends inside a UTF8 scalar") }
    }
}

class FixedJournalTextWriteProgress {
    private let lock=Mutex()
    private let expectedBytes: Int64
    private let expectedDigest: String
    private let check: ()->Result<Unit>
    private let writeChunk: (Int64,Array<Byte>)->Unit
    private let utf8=FixedJournalTextUtf8()
    private let hash=SHA256()
    private var offset: Int64=0
    private var closed=false
    private var failure:?Exception=None
    init(bytes: Int64,digest: String,check: ()->Result<Unit>,writeChunk: (Int64,Array<Byte>)->Unit) {
        if (bytes<0 || bytes>67108864 || !httpIntentDigest(digest)) {
            throw IllegalStateException("fixed journal text extent is outside the original cell bound") }
        expectedBytes=bytes; expectedDigest=digest; this.check=check; this.writeChunk=writeChunk
    }
    func accept(at: Int64,bytes: Array<Byte>): Unit {
        lock.lock()
        try {
            // Escaped callbacks never invoke a retired Source or physical IO.
            if (closed) { throw IllegalStateException("fixed journal text producer is closed") }
            match(failure){case Some(error)=>throw error;case None=>()}
            try {
                if (at!=offset || bytes.size<1 || bytes.size>65536 || bytes.size>expectedBytes-offset) {
                    throw IllegalStateException("fixed journal text producer is not contiguous and bounded") }
                journalStreamCheck(check); utf8.write(bytes); writeChunk(offset,bytes)
                hash.write(bytes); offset+=bytes.size; journalStreamCheck(check)
            } catch(error:Exception) {
                if(failure.isNone()){failure=Some(error)};throw error
            }
        } finally { lock.unlock() }
    }
    func finish(): FixedJournalTextWriteObservation {
        lock.lock()
        try {
            if(closed){throw IllegalStateException("fixed journal text producer is closed")}
            match(failure){case Some(error)=>throw error;case None=>()}
            try {
                if(offset!=expectedBytes){throw IllegalStateException("fixed journal text producer has not reached its exact EOF")}
                journalStreamCheck(check);utf8.finish();let digest=logicalJsonEncodeHex(hash.finish())
                if(digest!=expectedDigest){throw IllegalStateException("fixed journal text bytes differ from the actual extent digest")}
                closed=true;FixedJournalTextWriteObservation(offset,digest)
            } catch(error:Exception) {
                if(failure.isNone()){failure=Some(error)};throw error
            }
        } finally { lock.unlock() }
    }
    // Close waits for any accepted write to finish before physical blob close.
    // It is a local write boundary; it does not attest external worker joins.
    func close(): Unit {lock.lock();try{closed=true}finally{lock.unlock()}}
}

class FixedJournalTextPhysicalHandle {
    var pointer=CPointer<Unit>()
}
