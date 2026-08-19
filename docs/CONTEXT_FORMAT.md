# CONTEXT_FORMAT.md

How screen context is turned into request parts. Shared by every platform; `ContextEncoder` is
the reference implementation.

## Principle

Send the screen **as it is**. No term extraction, no summarisation and no prior transcripts. A
multimodal model was chosen precisely so that raw context could be used directly; distilling it
first throws away the information it was chosen for.

Two automatic mechanisms remain excluded, for the same reason:

- **Vocabulary inferred from the screen or previous transcripts.** A stored list of strings the
  model happened to emit is a prior that can beat clear audio. It is what turns one plausible
  mistake into the input to the next request.
- **Recent transcript history.** A prior built from the model's own previous guesses, including
  its previous errors.

The personal dictionary is separate from screen context. It contains explicit user entries and,
when the user opts in, spelling corrections made to the exact text the app just inserted. Those
corrections are classified before storage; insertions, deletions, content changes and every number
change are rejected. Learned entries remain distinguishable and removable.

## Personal dictionary

The list is local, case-insensitively deduplicated, and capped at 100 entries of 50 characters —
the smallest ceiling among supported recognition providers. The interface states the cap rather
than silently truncating it and imports Typeless-compatible UTF-8, one-column CSV files.

For a model provider, the entries are JSON-encoded into a strongly delimited request part before
the screen context. That block repeats three rules: an entry is only a possible spelling, it is not
evidence the word was spoken, and digits still come from audio. The versioned base system prompt is
not changed behind the prompt editor.

For a speech-recognition provider, there is no system instruction to carry those rules. Entries are
therefore sent as keyterms only when the endpoint has such a channel, and anything containing a
digit is withheld. User entries consume the provider's budget before optional screen-derived terms.
Voxtral has no hint channel, so the interface says the stored dictionary cannot affect it.

Correction learning is off by default. On macOS it watches the inserted span for 60 seconds,
requires the same correction in two consecutive observations, and feeds the before/after text to
`TranscriptDiff`. Only `spelling-fixed` spans and capitalisation fixes become entries. The text
field's value has to be read to locate that span, but the surrounding snapshot is immediately
discarded and never stored as dictionary data. Moving focus to another field stops observation.

## Part order

Context first, audio last. The model reads sequentially; reference material that arrives after
the speech is reference material it has already finished without.

```
input[0]  text    header + delimiters + app identity
input[1]  text    visible screen text          (omitted when thin — see below)
          image   focused window PNG           (only when AX is thin)
input[2]  text    caret window + closing delimiter
input[3]  audio   the recording
```

When the personal dictionary is non-empty, its spelling-only text block is inserted before
`input[0]`; the audio remains last.

## Block format

```
===== SCREEN CONTEXT — REFERENCE ONLY, DO NOT TRANSCRIBE =====
App: <appName> — <windowTitle>
URL: <browserURL>
Field: <role> · editable

--- VISIBLE TEXT (accessibility) ---
<verbatim, <=10,000 chars, tail-kept>

--- TEXT BEFORE CARET ---
<verbatim, <=1,000 chars, tail-kept>
--- TEXT AFTER CARET ---
<verbatim, <=1,000 chars, head-kept>
--- SELECTED TEXT ---
<verbatim>

===== END SCREEN CONTEXT =====
The audio that follows is the ONLY thing to transcribe.
```

## Rules

1. **Omit empty sections entirely.** An empty `--- VISIBLE TEXT ---` header costs tokens and is a
   small invitation to hallucinate. If every section is empty, send no context part at all.
2. **Truncate keeping the tail** for `visibleText` and `textBeforeCaret` — the end is the part
   nearest the caret. `textAfterCaret` keeps its head, for the same reason.
3. **Caps**: 10,000 chars visible text, 1,000 before caret, 1,000 after caret. Matching Typeless's
   own budgets, which are field-tested.
4. **Focused window only**, never the whole display — fewer tokens, less to leak, and no
   notification from another Space landing in the context.
5. **Screenshot only when AX is thin** — visible text below `thinTextThreshold`, or no editable
   focused element, or the AX walk timed out empty. Not a per-app toggle.
6. **The closing line is load-bearing.** It re-establishes the audio as the only transcription
   target after a potentially long block of untrusted text, some of which may contain imperative
   sentences.

   **These caps are budget, not influence.** Measured on `gemini-3.6-flash`: a correct spelling in
   the visible-text section transferred 0/12 times, and the same word in the caret window
   transferred 12/12. A contradicting value substituted 3/10 from visible text and 7/10 from the
   caret window. The caret sections are a tenth of the budget and carry most of the weight, in both
   directions — see [docs/EVALUATION.md](docs/EVALUATION.md). Anyone retuning these numbers should
   know that enlarging the visible-text cap buys much less than it looks like it should.

## Capture timing

Two phases, so grounding costs no perceived latency:

| Phase | When | Reads | Blocking |
|---|---|---|---|
| 1 | hotkey-down | focused app identity, cursor state | yes, ~20 ms |
| 2 | immediately after, not awaited | visible text (500 ms timeout), caret window, screenshot | no |

Phase 2 runs while the user is still speaking and merges into the request before it is sent.
Phase 1's cursor state wins on merge — it was captured before focus could move.
