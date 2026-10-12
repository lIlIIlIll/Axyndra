package agent_domain

import std.collection.*
import std.convert.*
import std.math.*
import std.overflow.*

// A display/optimistic-edit tag, not a cryptographic integrity or authority proof.
// Shared by host file primitives and external consumers so whitespace handling
// and the legacy 16-bit xxHash32 representation cannot drift between packages.
public func normalizedContentTag(content: String): String {
    let value = contentTagXxHash32(normalizeContentTagText(content)) & UInt32(0xffff)
    var encoded = value.toString(radix: 16).toAsciiUpper()
    while (encoded.size < 4) { encoded = "0" + encoded }
    encoded
}
func normalizeContentTagText(content: String): Array<Byte> {
    let result = ArrayList<Byte>()
    let bytes = unsafe { content.rawData() }
    var pending = ArrayList<Byte>()
    for (byte in bytes) {
        if (byte == b' ' || byte == b'\t' || byte == b'\r') {
            pending.add(byte)
        } else {
            if (byte != b'\n') { result.add(all: pending) }
            pending = ArrayList<Byte>()
            result.add(byte)
        }
    }
    result.toArray()
}

func contentTagXxHash32(bytes: Array<Byte>): UInt32 {
    let prime1 = UInt32(2654435761)
    let prime2 = UInt32(2246822519)
    let prime3 = UInt32(3266489917)
    let prime4 = UInt32(668265263)
    let prime5 = UInt32(374761393)
    var index: Int64 = 0
    var hash: UInt32
    if (bytes.size >= 16) {
        var v1 = prime1.wrappingAdd(prime2)
        var v2 = prime2
        var v3 = UInt32(0)
        var v4 = UInt32(0).wrappingSub(prime1)
        while (index <= bytes.size - 16) {
            v1 = contentTagXxRound(v1, contentTagReadUInt32(bytes, index))
            v2 = contentTagXxRound(v2, contentTagReadUInt32(bytes, index + 4))
            v3 = contentTagXxRound(v3, contentTagReadUInt32(bytes, index + 8))
            v4 = contentTagXxRound(v4, contentTagReadUInt32(bytes, index + 12))
            index += 16
        }
        hash = rotate(v1, Int8(1))
        hash = hash.wrappingAdd(rotate(v2, Int8(7)))
        hash = hash.wrappingAdd(rotate(v3, Int8(12)))
        hash = hash.wrappingAdd(rotate(v4, Int8(18)))
    } else {
        hash = prime5
    }
    hash = hash.wrappingAdd(UInt32(bytes.size))
    while (index <= bytes.size - 4) {
        let word = contentTagReadUInt32(bytes, index)
        hash = hash.wrappingAdd(word.wrappingMul(prime3))
        hash = rotate(hash, Int8(17)).wrappingMul(prime4)
        index += 4
    }
    while (index < bytes.size) {
        let byte = UInt32(bytes[index])
        hash = hash.wrappingAdd(byte.wrappingMul(prime5))
        hash = rotate(hash, Int8(11)).wrappingMul(prime1)
        index += 1
    }
    hash = hash ^ (hash >> 15)
    hash = hash.wrappingMul(prime2)
    hash = hash ^ (hash >> 13)
    hash = hash.wrappingMul(prime3)
    hash ^ (hash >> 16)
}

func contentTagXxRound(accumulator: UInt32, input: UInt32): UInt32 {
    let multiplied = input.wrappingMul(UInt32(2246822519))
    let added = accumulator.wrappingAdd(multiplied)
    rotate(added, Int8(13)).wrappingMul(UInt32(2654435761))
}

func contentTagReadUInt32(bytes: Array<Byte>, index: Int64): UInt32 {
    let first = UInt32(bytes[index])
    let second = UInt32(bytes[index + 1]) << 8
    let third = UInt32(bytes[index + 2]) << 16
    let fourth = UInt32(bytes[index + 3]) << 24
    first | second | third | fourth
}
