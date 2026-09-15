package agent_product

import agent_skills.*
import std.collection.*
import std.math.*
import std.unicode.*

let PRODUCT_SKILL_MAX_AUTOMATIC: Int64 = 3
let PRODUCT_SKILL_MAX_ROUTING_BYTES: Int64 = 32768
let PRODUCT_SKILL_MAX_ROUTING_TERMS: Int64 = 512

class ProductSkillCandidate {
    let id: String
    let score: Int64
    init(id: String, score: Int64) { this.id = id; this.score = score }
}

// A provider-neutral pre-Run router. It consumes metadata, never instructions,
// references, permissions or tools. Selected content is frozen by SkillStack.
func selectProductSkills(available: Array<SkillMetadata>, prompt: String): Array<String> {
    // Unknown/malformed mentions must not fall back to an unrelated automatic
    // selection. Dollar-bearing shell text also opts out of automatic routing.
    if (prompt.contains("$")) {
        let explicit = ArrayList<String>()
        for (metadata in available where productSkillTriggered(metadata, prompt, available)) {
            explicit.add(metadata.id)
        }
        return explicit.toArray()
    }
    if (prompt.size > PRODUCT_SKILL_MAX_ROUTING_BYTES) { return [] }
    let terms = productSkillTerms(prompt)
    let candidates = ArrayList<ProductSkillCandidate>()
    for (metadata in available) {
        let score = productSkillScore(metadata, terms)
        if (score == 0) { continue }
        candidates.add(ProductSkillCandidate(metadata.id, score))
        var index = candidates.size - 1
        while (index > 0 && productSkillCandidateBefore(candidates[index], candidates[index - 1])) {
            let previous = candidates[index - 1]
            candidates[index - 1] = candidates[index]
            candidates[index] = previous
            index -= 1
        }
        if (candidates.size > PRODUCT_SKILL_MAX_AUTOMATIC) {
            candidates.remove(at: candidates.size - 1)
        }
    }
    let selected = ArrayList<String>()
    for (candidate in candidates) { selected.add(candidate.id) }
    selected.toArray()
}

func productSkillCandidateBefore(left: ProductSkillCandidate, right: ProductSkillCandidate): Bool {
    left.score > right.score || (left.score == right.score && left.id < right.id)
}

func productSkillScore(metadata: SkillMetadata, task: Array<String>): Int64 {
    var score: Int64 = 0
    for (name in [metadata.id, metadata.name]) {
        if (productSkillPhraseMatches(task, productSkillTerms(name))) { score = max(score, 8) }
    }
    for (trigger in metadata.triggers) {
        if (productSkillPhraseMatches(task, productSkillTerms(trigger))) { score = max(score, 6) }
    }
    let matched = ArrayList<String>()
    for (term in productSkillTerms(metadata.description)) {
        if (task.contains(term) && !matched.contains(term)) { matched.add(term) }
    }
    // One generic description word is not sufficient evidence. Repeating a
    // keyword cannot inflate relevance or outrank an exact name match.
    if (matched.size >= 2) { score = max(score, min(4, matched.size)) }
    score
}

func productSkillPhraseMatches(task: Array<String>, phrase: Array<String>): Bool {
    if (phrase.isEmpty() || phrase.size > task.size) { return false }
    for (start in 0..task.size - phrase.size + 1) {
        var matches = true
        for (offset in 0..phrase.size where task[start + offset] != phrase[offset]) {
            matches = false
            break
        }
        if (matches) { return true }
    }
    false
}

// ASCII case-insensitive words; non-ASCII runes are retained, never sliced by
// byte offsets. This is lexical routing, not semantic/cross-language search.
func productSkillTerms(value: String): Array<String> {
    let terms = ArrayList<String>()
    let word = ArrayList<Byte>()
    let separators = "-_/\\.:,;!?()[]{}<>\"'`=+|，。！？；：、（）【】".toRuneArray()
    for (rune in value.toAsciiLower().toRuneArray()) {
        if (rune.isWhiteSpace() || separators.contains(rune)) {
            productSkillAddTerm(terms, String.fromUtf8(word.toArray()))
            word.clear()
            if (terms.size > PRODUCT_SKILL_MAX_ROUTING_TERMS) { return [] }
        } else {
            for (byte in rune.toString().toArray()) { word.add(byte) }
        }
    }
    productSkillAddTerm(terms, String.fromUtf8(word.toArray()))
    if (terms.size > PRODUCT_SKILL_MAX_ROUTING_TERMS) { return [] }
    terms.toArray()
}

func productSkillAddTerm(terms: ArrayList<String>, word: String): Unit {
    if (word == "" || word.toRuneArray().size < 2) { return }
    if (["the", "a", "an", "and", "or", "for", "to", "of", "in", "on", "with",
        "is", "are", "be", "this", "that", "it", "please", "use", "skill", "skills",
        "agent", "task", "help"].contains(word)) { return }
    terms.add(word)
}
