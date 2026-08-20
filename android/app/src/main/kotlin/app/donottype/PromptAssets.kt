package app.donottype

import android.content.Context
import app.donottype.core.Fidelity
import app.donottype.core.RewriteStyle
import app.donottype.core.SummaryStyle
import app.donottype.core.TranscriptMode
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/**
 * One file in `prompt/`.
 *
 * The contract used to be a single markdown file with the live text fenced off by
 * `<!-- BEGIN SYSTEM -->` markers, which meant a loader had to tell payload from prose by
 * convention — and it got that wrong for as long as the markers existed, because the file
 * documented its own markers and a first-match search found the documentation. A part is a whole
 * file now. Everything in it is sent, so there is nothing to skip and nothing to mis-match.
 */
data class PromptPart(
    val id: String,
    val relativePath: String,
    val placeholder: String?,
    val group: String,
    val label: String,
) {
    /**
     * Whether this part is substituted into another part.
     *
     * The one transform in the whole loader: a clause is written as a wrapped paragraph and joined
     * into a single line on load, so source wrapping never changes the instruction.
     */
    val isClause: Boolean get() = placeholder == null

    /** One line on what this part does, for the editor that has room to say so. */
    val summaryLine: String get() = when {
        id == "system" -> "Sent on every request. Must contain {{FIDELITY_RULE}}."
        id == "rewrite" -> "Sent only when a rewrite style is chosen."
        id == "summary" -> "Sent only when a summary style is chosen."
        group == "Fidelity" -> "Substituted into the transcription block."
        group == "Rewrite styles" -> "Substituted into the rewrite block."
        else -> "Substituted into the summary block."
    }

    companion object {
        val SYSTEM = PromptPart("system", "system.md", "{{FIDELITY_RULE}}", "Blocks", "Transcription")
        val REWRITE = PromptPart("rewrite", "rewrite.md", "{{STYLE_RULE}}", "Blocks", "Rewrite")
        val SUMMARY = PromptPart("summary", "summary.md", "{{SUMMARY_RULE}}", "Blocks", "Summary")

        fun of(fidelity: Fidelity) =
            PromptPart("fidelity:${fidelity.id}", "fidelity/${fidelity.id}.md", null, "Fidelity", fidelity.id)

        fun of(style: RewriteStyle) =
            PromptPart("style:${style.id}", "style/${style.id}.md", null, "Rewrite styles", style.id)

        fun of(style: SummaryStyle) =
            PromptPart(
                "summary-style:${style.id}", "summary-style/${style.id}.md", null,
                "Summary styles", style.id,
            )

        /** Every part that has a file, in the order a settings list should show them. */
        val all: List<PromptPart> = buildList {
            add(SYSTEM)
            add(REWRITE)
            add(SUMMARY)
            Fidelity.entries.forEach { add(of(it)) }
            RewriteStyle.entries.filter { it.isRewrite }.forEach { add(of(it)) }
            SummaryStyle.entries.forEach { add(of(it)) }
        }

        fun parse(id: String): PromptPart? = all.firstOrNull { it.id.equals(id.trim(), true) }
    }
}

/**
 * Reads prompt parts out of the APK assets, or the user's edited copy of one.
 *
 * The same files the macOS app bundles and the eval harness runs against — copied into `assets/`
 * by the Gradle build rather than duplicated, so the platforms cannot drift.
 *
 * The override is per part rather than all-or-nothing, which is the point of the split. Someone who
 * tuned `fidelity/light.md` keeps getting shipped updates to `system.md`, and a part they never
 * touched cannot be stale. The old single-file override froze the whole contract at whatever it
 * looked like on the day it was edited: a prompt customised before the summary stage existed had no
 * summary block at all, and the stage failed outright rather than falling back.
 */
object PromptAssets {
    private const val ASSET_DIRECTORY = "prompt"
    private const val OVERRIDE_DIRECTORY = "prompt"
    private const val LEGACY_FILE = "PROMPT.md"

    private val cache = mutableMapOf<String, String>()

    /**
     * The split of an old single-file override runs once, on the first read of any part.
     *
     * Android has no Application subclass to hang a launch hook on, and there are four ways in —
     * the IME, the settings screen, the file transcriber and the accessibility service. Doing it
     * here means it cannot be reached through a door that forgot to call it.
     */
    @Volatile private var migrationChecked = false

    private fun ensureMigrated(context: Context) {
        if (migrationChecked) return
        migrationChecked = true
        runCatching { migrateLegacyPrompt(context) }
    }

    /** What a migration from the single-file format did, for the message that reports it. */
    data class Migration(val migrated: List<PromptPart>, val archivedAt: File)

    private fun overrideFile(context: Context, part: PromptPart) =
        File(File(context.filesDir, OVERRIDE_DIRECTORY), part.relativePath)

    private fun legacyFile(context: Context) = File(context.filesDir, LEGACY_FILE)

    fun isCustom(context: Context, part: PromptPart): Boolean {
        ensureMigrated(context)
        return overrideFile(context, part).exists()
    }

    fun customParts(context: Context): List<PromptPart> =
        PromptPart.all.filter { isCustom(context, it) }

    fun hasCustomPrompt(context: Context): Boolean = customParts(context).isNotEmpty()

    /**
     * Line endings are normalised to LF everywhere a part is read.
     *
     * Git checks these files out with CRLF on Windows under the default autocrlf, and the Gradle
     * build copies whatever the checkout produced straight into the APK. Without this an APK built
     * on Windows would send different bytes for the same contract than one built on a Mac — which
     * is exactly the drift a shared file is supposed to prevent.
     */
    private fun normaliseLineEndings(text: String): String =
        text.replace("\r\n", "\n").replace("\r", "\n").trim()

    fun bundledText(context: Context, part: PromptPart): String =
        normaliseLineEndings(
            context.assets.open("$ASSET_DIRECTORY/${part.relativePath}")
                .bufferedReader().use { it.readText() }
        )

    /** The text as it sits on disk, unjoined — what an editor should show and save. */
    fun editableText(context: Context, part: PromptPart): String {
        ensureMigrated(context)
        val custom = overrideFile(context, part)
        if (custom.exists()) {
            val text = runCatching { custom.readText() }.getOrNull()
            if (!text.isNullOrBlank()) return normaliseLineEndings(text)
        }
        return bundledText(context, part)
    }

    /** The part's text, exactly as it will be sent. */
    fun text(context: Context, part: PromptPart): String {
        // Before the cache, not inside it: migrating writes override files and clears entries, and
        // doing that halfway through populating one is a needless ordering puzzle.
        ensureMigrated(context)
        val cached = cache.getOrPut(part.id) { editableText(context, part) }
        require(cached.isNotEmpty()) {
            "${part.relativePath} is empty. A part file is sent in full, so an empty one would " +
                "send nothing for ${part.id}."
        }
        return if (part.isClause) cached.replace("\n", " ") else cached
    }

    /**
     * Validated before writing. A part that cannot build would fail mid-dictation rather than at
     * the moment of editing.
     */
    fun saveCustomPrompt(context: Context, template: String, part: PromptPart) {
        validate(template, part)
        val destination = overrideFile(context, part)
        writeAtomically(destination, template.trim() + "\n")
        cache.remove(part.id)
    }

    /** Restores one part. The others keep whatever they are. */
    fun restoreDefault(context: Context, part: PromptPart) {
        overrideFile(context, part).delete()
        cache.remove(part.id)
    }

    fun restoreAll(context: Context) {
        customParts(context).forEach { restoreDefault(context, it) }
    }

    /**
     * Checks that a part will build. Much less than the old whole-file validation had to check: a
     * part the user has not edited cannot be missing, because the shipped one is still there.
     */
    fun validate(template: String, part: PromptPart) {
        require(template.isNotBlank()) {
            "${part.id} is empty. A part file is sent in full, so an empty one sends nothing."
        }
        val placeholder = part.placeholder
        require(placeholder == null || template.contains(placeholder)) {
            "${part.id} needs a $placeholder placeholder — without it the clause chosen in " +
                "settings would never reach the model."
        }
    }

    fun systemInstruction(context: Context, fidelity: Fidelity): String =
        assemble(context, PromptPart.SYSTEM, PromptPart.of(fidelity))

    /** The style rule alone, for folding a rewrite into the request that carries the audio. */
    fun styleClause(context: Context, style: RewriteStyle): String =
        text(context, PromptPart.of(style))

    /**
     * The instruction for whichever second stage a mode asks for, or null when it asks for none.
     *
     * One entry point, so a caller cannot route a summary through the rewrite part by picking the
     * wrong method — which is the mistake the two-part split exists to make impossible. A rewrite
     * may never drop a fact; a summary exists to.
     */
    fun secondStageInstruction(context: Context, mode: TranscriptMode): String? = when (mode) {
        is TranscriptMode.Verbatim -> null
        is TranscriptMode.Rewrite -> assemble(context, PromptPart.REWRITE, PromptPart.of(mode.style))
        is TranscriptMode.Summary -> assemble(context, PromptPart.SUMMARY, PromptPart.of(mode.style))
    }

    /** Whether the prompt in force can run a mode's second stage at all. */
    fun supportsSecondStage(context: Context, mode: TranscriptMode): Boolean =
        runCatching { secondStageInstruction(context, mode) }.isSuccess

    /**
     * Splits a pre-split `PROMPT.md` override into part files, once.
     *
     * Only parts that actually differ from the shipped text become overrides. A user who edited one
     * fidelity clause and left everything else alone should end up with one override, not twelve —
     * twelve would pin the whole contract at the version they happened to copy, which is the failure
     * mode the split exists to remove.
     *
     * Returns null when there is nothing to migrate. Never throws for a malformed old file: an
     * unparseable prompt means the user gets the shipped one, which is what would have happened
     * before.
     */
    fun migrateLegacyPrompt(context: Context): Migration? {
        val legacy = legacyFile(context)
        if (!legacy.exists()) return null

        val text = runCatching { legacy.readText() }.getOrNull() ?: return null
        val parsed = LegacyPromptFile(text)
        if (!parsed.isLegacyFormat) return null

        val found = parsed.parts()
        val migrated = mutableListOf<PromptPart>()
        for (part in PromptPart.all) {
            val body = found[part.id]?.trim() ?: continue
            val ok = runCatching { validate(body, part) }.isSuccess
            if (!ok) continue
            if (runCatching { bundledText(context, part) }.getOrNull() == body) continue

            saveCustomPrompt(context, body, part)
            migrated.add(part)
        }

        val archive = File(legacy.parentFile, "$LEGACY_FILE.migrated")
        archive.delete()
        legacy.renameTo(archive)
        return Migration(migrated, archive)
    }

    private fun assemble(context: Context, host: PromptPart, clause: PromptPart): String {
        val body = text(context, host)
        val placeholder = host.placeholder ?: return body
        return body.replace(placeholder, text(context, clause))
    }

    /** A crash while saving a prompt must leave the previous, valid contract in force. */
    private fun writeAtomically(destination: File, text: String) {
        val parent = destination.parentFile
            ?: throw IllegalArgumentException("a prompt part needs a parent directory")
        if (!parent.exists() && !parent.mkdirs()) {
            throw java.io.IOException("the prompt directory could not be created")
        }
        val temporary = File(
            parent,
            ".${destination.name}.${android.os.Process.myPid()}.${UUID.randomUUID()}.tmp",
        )
        try {
            FileOutputStream(temporary).use { output ->
                output.write(text.toByteArray(StandardCharsets.UTF_8))
                output.flush()
                output.fd.sync()
            }
            try {
                Files.move(
                    temporary.toPath(), destination.toPath(),
                    StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(
                    temporary.toPath(), destination.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
        } finally {
            temporary.delete()
        }
    }
}

/**
 * Reads the single-file `PROMPT.md` format that `prompt/` replaced.
 *
 * Kept for one job only: splitting a user's edited copy into part files the first time they run a
 * version that expects the directory. Nothing in the app sends a prompt through this type, and it
 * should be deleted a release after the split ships.
 *
 * The marker search here is anchored to whole lines, which the shipped loader never was. That is
 * the bug the split was made to end — a file that documented its own markers had them matched
 * inside the documentation, because the search took the first substring anywhere in the text.
 * Anyone whose custom prompt was a copy of the shipped one has that sentence in it, so migrating
 * with the original rule would carry the bug into their new part files.
 */
class LegacyPromptFile(template: String) {
    private val lines = template.replace("\r\n", "\n").split("\n")

    val isLegacyFormat: Boolean get() = block("SYSTEM") != null

    /**
     * Every part this file can supply, keyed by [PromptPart.id].
     *
     * Parts the file does not contain are simply absent — an old prompt written before the summary
     * stage existed has no summary block, and the caller falls back to the shipped one rather than
     * failing, which is the whole reason per-part overrides exist.
     */
    fun parts(): Map<String, String> = buildMap {
        block("SYSTEM")?.let { put(PromptPart.SYSTEM.id, it) }
        block("REWRITE")?.let { put(PromptPart.REWRITE.id, it) }
        block("SUMMARY")?.let { put(PromptPart.SUMMARY.id, it) }
        Fidelity.entries.forEach { fidelity ->
            clause(fidelity.id)?.let { put(PromptPart.of(fidelity).id, it) }
        }
        RewriteStyle.entries.filter { it.isRewrite }.forEach { style ->
            clause("style: ${style.id}")?.let { put(PromptPart.of(style).id, it) }
        }
        SummaryStyle.entries.forEach { style ->
            clause("summary: ${style.id}")?.let { put(PromptPart.of(style).id, it) }
        }
    }

    /** Body between markers that each sit alone on their own line. */
    private fun block(name: String): String? {
        var begin = -1
        var end = -1
        lines.forEachIndexed { index, line ->
            when (line.trim()) {
                "<!-- BEGIN $name -->" -> begin = index
                "<!-- END $name -->" -> if (begin >= 0 && end < 0) end = index
            }
        }
        if (begin < 0 || end <= begin) return null
        return lines.subList(begin + 1, end).joinToString("\n").trim().ifEmpty { null }
    }

    /** The first fenced block under a `### name` heading line. */
    private fun clause(name: String): String? {
        val heading = "### $name"
        val start = lines.indexOfFirst { line ->
            val trimmed = line.trim()
            // Tolerates the shipped file's `### light  *(default)*` without matching a longer
            // heading that merely starts the same way.
            trimmed.startsWith(heading) &&
                trimmed.removePrefix(heading).trim().firstOrNull()?.isLetter() != true
        }
        if (start < 0) return null

        val fences = (start until lines.size).filter { lines[it].trim() == "```" }
        if (fences.size < 2) return null
        return lines.subList(fences[0] + 1, fences[1]).joinToString("\n").trim().ifEmpty { null }
    }
}
