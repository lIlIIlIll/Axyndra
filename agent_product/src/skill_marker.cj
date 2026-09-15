package agent_product

import agent_skills.*
import std.math.*
import std.unicode.*

func productSkillTriggered(metadata: SkillMetadata, prompt: String, available: Array<SkillMetadata>): Bool {
    // Explicit markers preserve longest-name and Unicode boundary semantics.
    // Automatic routing is separate and can never augment an explicit choice.
    let text = prompt.toRuneArray()
    for (index in 0..text.size where text[index] == r'$') {
        if (index > 0 && !productSkillMarkerBoundary(text[index - 1])) { continue }
        let length = max(productSkillMarkerLength(text, index + 1, metadata.id),
            productSkillMarkerLength(text, index + 1, metadata.name))
        if (length == 0) { continue }
        var longer = false
        for (candidate in available) {
            if (productSkillMarkerLength(text, index + 1, candidate.id) > length ||
                productSkillMarkerLength(text, index + 1, candidate.name) > length) {
                longer = true
                break
            }
        }
        if (!longer) { return true }
    }
    false
}

func productSkillMarkerLength(text: Array<Rune>, start: Int64, name: String): Int64 {
    let marker = name.toRuneArray()
    if (marker.isEmpty() || start + marker.size > text.size) { return 0 }
    for (offset in 0..marker.size where text[start + offset] != marker[offset]) { return 0 }
    let end = start + marker.size
    if (end < text.size && !productSkillMarkerBoundary(text[end])) { return 0 }
    marker.size
}

func productSkillMarkerBoundary(value: Rune): Bool {
    // Names are not restricted to ASCII slugs. Only text separators delimit
    // mentions; other Unicode characters (including combining marks), '-' and
    // '_' continue a name. Declared names containing separators match in full.
    value.isWhiteSpace() || "()[]{}<>.,!?;:'\"`，。！？；：、（）【】《》「」『』“”‘’".toRuneArray().contains(value)
}
