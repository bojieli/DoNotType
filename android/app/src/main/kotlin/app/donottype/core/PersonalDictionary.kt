package app.donottype.core

import org.json.JSONArray
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/** A bounded spelling reference entered by the user or learned from an opted-in correction. */
object PersonalDictionary {
    const val MAX_TERMS = 100
    const val MAX_CHARACTERS_PER_TERM = 50

    class ValidationException(message: String) : IllegalArgumentException(message)

    fun normalize(raw: String): String {
        if (raw.any { it == '\r' || it == '\n' }) {
            throw ValidationException("A dictionary entry must fit on one line.")
        }
        val term = raw.trim().split(Regex("\\s+")).filter(String::isNotEmpty).joinToString(" ")
        if (term.isEmpty()) throw ValidationException("Enter a word or phrase.")
        if (term.codePointCount(0, term.length) > MAX_CHARACTERS_PER_TERM) {
            throw ValidationException(
                "Dictionary entries can be at most $MAX_CHARACTERS_PER_TERM characters.",
            )
        }
        return term
    }

    fun sanitize(raw: Iterable<String>?): List<String> {
        val seen = mutableSetOf<String>()
        return buildList {
            for (value in raw ?: emptyList()) {
                val term = runCatching { normalize(value) }.getOrNull() ?: continue
                if (!seen.add(term.lowercase())) continue
                add(term)
                if (size == MAX_TERMS) break
            }
        }
    }

    fun add(raw: String, terms: Iterable<String>): List<String> {
        val current = sanitize(terms)
        if (current.size >= MAX_TERMS) {
            throw ValidationException("The dictionary can contain at most $MAX_TERMS entries.")
        }
        val term = normalize(raw)
        if (current.any { it.equals(term, ignoreCase = true) }) {
            throw ValidationException("“$term” is already in the dictionary.")
        }
        return current + term
    }

    fun entriesFromCsv(data: ByteArray): List<String> {
        val decoder = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        var text = try {
            decoder.decode(ByteBuffer.wrap(data)).toString()
        } catch (_: Exception) {
            throw ValidationException("The file is not UTF-8 text.")
        }
        text = text.removePrefix("\uFEFF").replace("\r\n", "\n").replace('\r', '\n')
        val seen = mutableSetOf<String>()
        return buildList {
            text.split('\n').forEachIndexed { index, line ->
                if (line.isBlank()) return@forEachIndexed
                val term = normalize(csvField(line, index + 1))
                if (!seen.add(term.lowercase())) return@forEachIndexed
                add(term)
                if (size > MAX_TERMS) {
                    throw ValidationException("The dictionary can contain at most $MAX_TERMS entries.")
                }
            }
        }
    }

    fun referenceBlock(raw: Iterable<String>): String? {
        val terms = sanitize(raw)
        if (terms.isEmpty()) return null
        return """
            PERSONAL DICTIONARY — SPELLING REFERENCE ONLY, DO NOT TRANSCRIBE
            The user supplied the JSON strings below as possible spellings. Use an entry only when
            the same word or phrase is audible. The list is not evidence that an entry was spoken,
            and it never overrides clear audio. Digits, versions and quantities come from audio
            alone even when an entry contains a number.
            ${JSONArray(terms)}
            END PERSONAL DICTIONARY. The audio is still the ONLY thing to transcribe.
        """.trimIndent()
    }

    fun keyterms(raw: Iterable<String>, maxTerms: Int, maxCharsPerTerm: Int): List<String> {
        if (maxTerms <= 0) return emptyList()
        return sanitize(raw).filter {
            it.none(Char::isDigit) && it.codePointCount(0, it.length) <= maxCharsPerTerm
        }.take(maxTerms)
    }

    fun mergeKeyterms(
        dictionary: Iterable<String>,
        derived: Iterable<String>,
        maxTerms: Int,
        maxCharsPerTerm: Int,
    ): List<String> {
        val result = keyterms(dictionary, maxTerms, maxCharsPerTerm).toMutableList()
        val seen = result.mapTo(mutableSetOf()) { it.lowercase() }
        for (term in derived) {
            if (term.codePointCount(0, term.length) > maxCharsPerTerm) continue
            if (!seen.add(term.lowercase())) continue
            result.add(term)
            if (result.size == maxTerms) break
        }
        return result
    }

    /** Returns only spelling/capitalisation fixes, never insertions, deletions or number changes. */
    fun learnedCandidates(original: String, corrected: String): List<String> {
        if (original == corrected) return emptyList()
        val left = tokenize(original)
        val right = tokenize(corrected)
        val candidates = mutableListOf<String>()
        for ((before, after) in alignedDifferences(left, right)) {
            if (classify(before, after) == Difference.SPELLING_FIXED) {
                usableLearnedTerm(after.joinToString(" "))?.let(candidates::add)
            } else {
                bestSpellingSubspan(before, after)?.let(candidates::add)
            }
        }
        if (left.size == right.size) {
            left.zip(right).forEach { (before, after) ->
                if (normalizeToken(before) == normalizeToken(after) && before != after &&
                    before.equals(after, ignoreCase = true)
                ) {
                    usableLearnedTerm(after)?.let(candidates::add)
                }
            }
        }
        return sanitize(candidates)
    }

    private fun csvField(line: String, lineNumber: Int): String {
        val trimmed = line.trim()
        if (!trimmed.startsWith('"')) {
            if (line.contains(',')) throw ValidationException(
                "Line $lineNumber has more than one CSV column. Use one entry per row.",
            )
            return line
        }
        val value = StringBuilder()
        var index = 1
        var closed = false
        while (index < trimmed.length) {
            if (trimmed[index] == '"') {
                if (index + 1 < trimmed.length && trimmed[index + 1] == '"') {
                    value.append('"'); index += 2; continue
                }
                closed = true; index++; break
            }
            value.append(trimmed[index++])
        }
        if (!closed) throw ValidationException(
            "Line $lineNumber has an unterminated or malformed quoted value.",
        )
        val remainder = trimmed.substring(index).trim()
        if (remainder.isNotEmpty()) {
            if (remainder.startsWith(',')) throw ValidationException(
                "Line $lineNumber has more than one CSV column. Use one entry per row.",
            )
            throw ValidationException(
                "Line $lineNumber has an unterminated or malformed quoted value.",
            )
        }
        return value.toString()
    }

    private enum class Difference { SPELLING_FIXED, CONTENT_CHANGED }
    private data class Span(val left: List<String>, val right: List<String>)

    private fun tokenize(text: String): List<String> = text.split(Regex("\\s+"))
        .filter { normalizeToken(it).isNotEmpty() }

    private fun normalizeToken(text: String): String =
        text.lowercase().filter { it.isLetterOrDigit() }

    private fun digitRuns(text: String): List<String> = Regex("\\d+").findAll(text).map { it.value }.toList()

    private fun classify(left: List<String>, right: List<String>): Difference {
        if (left.isEmpty() || right.isEmpty()) return Difference.CONTENT_CHANGED
        val lhs = left.joinToString(" ")
        val rhs = right.joinToString(" ")
        if (digitRuns(lhs) != digitRuns(rhs)) return Difference.CONTENT_CHANGED
        return if (phoneticKey(lhs) == phoneticKey(rhs)) Difference.SPELLING_FIXED
        else Difference.CONTENT_CHANGED
    }

    private fun phoneticKey(text: String): String {
        var value = text.lowercase().filter(Char::isLetter)
        if (value.isEmpty()) return ""
        listOf(
            "sch" to "sk", "ph" to "f", "ck" to "k", "kn" to "n",
            "wr" to "r", "gn" to "n", "gh" to "", "wh" to "w",
        ).forEach { (from, to) -> value = value.replace(from, to) }
        val mapped = buildString {
            value.forEachIndexed { index, character ->
                when (character) {
                    'c' -> append(
                        if (value.getOrNull(index + 1)?.let { "eiy".contains(it) } == true) 's'
                        else 'k',
                    )
                    'q' -> append('k')
                    'x' -> append("ks")
                    'z' -> append('s')
                    'v' -> append('f')
                    'a', 'e', 'i', 'o', 'u', 'y' -> append('a')
                    'h', 'w' -> Unit
                    else -> append(character)
                }
            }
        }
        return buildString { mapped.forEach { if (lastOrNull() != it) append(it) } }
    }

    private fun alignedDifferences(left: List<String>, right: List<String>): List<Span> {
        val lengths = Array(left.size + 1) { IntArray(right.size + 1) }
        for (i in left.lastIndex downTo 0) for (j in right.lastIndex downTo 0) {
            lengths[i][j] = if (normalizeToken(left[i]) == normalizeToken(right[j])) {
                lengths[i + 1][j + 1] + 1
            } else {
                maxOf(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        val spans = mutableListOf<Span>()
        val pendingLeft = mutableListOf<String>()
        val pendingRight = mutableListOf<String>()
        fun flush() {
            if (pendingLeft.isEmpty() && pendingRight.isEmpty()) return
            spans.add(Span(pendingLeft.toList(), pendingRight.toList()))
            pendingLeft.clear(); pendingRight.clear()
        }
        var i = 0
        var j = 0
        while (i < left.size && j < right.size) {
            if (normalizeToken(left[i]) == normalizeToken(right[j])) {
                flush(); i++; j++
            } else if (lengths[i + 1][j] >= lengths[i][j + 1]) {
                pendingLeft.add(left[i++])
            } else {
                pendingRight.add(right[j++])
            }
        }
        while (i < left.size) pendingLeft.add(left[i++])
        while (j < right.size) pendingRight.add(right[j++])
        flush()
        return spans
    }

    private fun usableLearnedTerm(raw: String): String? {
        val candidate = raw.trim(*"\"“”‘’(),;:!?[]{} \t\r\n".toCharArray())
        val term = runCatching { normalize(candidate) }.getOrNull() ?: return null
        return term.takeIf {
            it.codePointCount(0, it.length) >= 3 && it.any(Char::isLetter) && it.none(Char::isDigit)
        }
    }

    private fun bestSpellingSubspan(left: List<String>, right: List<String>): String? {
        var best: Pair<Int, String>? = null
        for (leftStart in left.indices) for (rightStart in right.indices) {
            for (leftCount in 1..minOf(3, left.size - leftStart)) {
                for (rightCount in 1..minOf(3, right.size - rightStart)) {
                    val lhs = left.subList(leftStart, leftStart + leftCount)
                    val rhs = right.subList(rightStart, rightStart + rightCount)
                    if (classify(lhs, rhs) != Difference.SPELLING_FIXED) continue
                    val term = usableLearnedTerm(rhs.joinToString(" ")) ?: continue
                    val candidate = leftCount + rightCount to term
                    if (best == null || candidate.first > best!!.first) best = candidate
                }
            }
        }
        return best?.second
    }
}
