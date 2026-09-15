package agent_product

import agent_skills.*
import std.collection.*
import std.io.*
import std.math.*

let PRODUCT_SKILL_MAX_HEADER_BYTES: Int64 = 4096
let PRODUCT_SKILL_MAX_CANDIDATES: Int64 = 128
let PRODUCT_SKILL_MAX_METADATA_BYTES: Int64 = 65536

// Read through the closing frontmatter line, never into the instruction body.
// One-byte reads deliberately avoid a buffered read-ahead of a small body.
// Both bytes and iterations are bounded even for a missing delimiter.
func readProductSkillHeader(stream: InputStream, maxBytes: Int64): String {
    let header = ArrayList<Byte>()
    let line = ArrayList<Byte>()
    let buffer = Array<Byte>(1, repeat: 0)
    var opened = false
    for (_ in 0..maxBytes) {
        if (stream.read(buffer) != 1) { return "" }
        let byte = buffer[0]
        header.add(byte)
        if (byte != 10) {
            line.add(byte)
            continue
        }
        let text = String.fromUtf8(line.toArray()).trimAscii()
        if (!opened) {
            if (text != "---") { return "" }
            opened = true
        } else if (text == "---") {
            return String.fromUtf8(header.toArray())
        }
        line.clear()
    }
    ""
}

// Bound actual reads too: a regular file can grow after the metadata stat.
func readProductSkillText(stream: InputStream, maxBytes: Int64): String {
    let bytes = ArrayList<Byte>()
    while (true) {
        let buffer = Array<Byte>(min(4096, maxBytes - bytes.size + 1), repeat: 0)
        let count = stream.read(buffer)
        if (count == 0) { return String.fromUtf8(bytes.toArray()) }
        if (count < 0 || count > buffer.size || count > maxBytes - bytes.size) {
            throw IllegalStateException("skill content exceeds its read budget")
        }
        for (index in 0..count) { bytes.add(buffer[index]) }
    }
}

// Identity collisions were resolved before this budget is applied. Prefer
// later (workspace, then user, then managed) entries; never resurrect a
// shadowed lower-priority definition when its replacement does not fit.
func boundedProductSkillDescriptors(values: Array<SkillDescriptor>): Array<SkillDescriptor> {
    let selected = ArrayList<SkillDescriptor>()
    var used: Int64 = 0
    var index = values.size
    while (index > 0 && selected.size < PRODUCT_SKILL_MAX_CANDIDATES) {
        index -= 1
        let value = values[index]
        // Charging the common catalog header per entry is conservative and
        // keeps the budget valid if the metadata renderer changes later.
        let bytes = productSkillMetadataPrompt([SkillMetadata(value)]).size
        if (bytes > PRODUCT_SKILL_MAX_METADATA_BYTES - used) { continue }
        selected.add(value)
        used += bytes
    }
    selected.toArray()
}
