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
    while (header.size < maxBytes) {
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
    while (bytes.size <= maxBytes) {
        let buffer = Array<Byte>(min(4096, maxBytes - bytes.size + 1), repeat: 0)
        let count = stream.read(buffer)
        if (count == 0) { return String.fromUtf8(bytes.toArray()) }
        if (count < 0 || count > buffer.size || count > maxBytes - bytes.size) {
            throw IllegalStateException("skill content exceeds its read budget")
        }
        for (index in 0..count) { bytes.add(buffer[index]) }
    }
    throw IllegalStateException("skill content exceeds its read budget")
}

// PromptBuilder escapes external data by doubling original backslashes and
// replacing '<'/'>' with six-byte \u003c/\u003e sequences. Charge that final
// representation rather than the raw catalog text so the 64 KiB budget remains
// valid after the available-skills section is rendered.
func productSkillEscapedMetadataBytes(source: String): Int64 {
    var size: Int64 = 0
    for (byte in source.toArray()) {
        if (byte == 92) {
            size += 2
        } else if (byte == 60 || byte == 62) {
            size += 6
        } else {
            size += 1
        }
    }
    size
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
        let bytes = productSkillEscapedMetadataBytes(
            productSkillMetadataPrompt([SkillMetadata(value)])
        )
        if (bytes > PRODUCT_SKILL_MAX_METADATA_BYTES - used) { continue }
        selected.add(value)
        used += bytes
    }
    selected.toArray()
}
