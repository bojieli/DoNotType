# Reference audio for GPU model testing

Copied from the DoNotType working tree. All clips are 16 kHz mono 16-bit WAV — the exact
format the apps record, so a model measured here sees what the product actually sends.

`real-*.wav` are extracts of real recorded human speech and are the only clips whose numbers
mean anything for substitution. The rest are `say`-synthesized and measure the easy case:
clean pronunciation removes the ambiguity that substitution needs. Use them for plumbing.

The `novel-*` clips are different again — they are synthesized on purpose. They contain
invented tokens (Kaelith, Brindlewood, quillmark-sync) that appear in no public corpus, to
measure whether screen context can supply a spelling the model cannot know. An unknown name
is equally unknown however clearly it is spoken, so synthesis costs nothing there.

## Clips

| case | file | secs | sha256 |
|---|---|---|---|
| `gemini-version` | `gemini-version.wav` | 3.044 | `f59155640370…` |
| `port-number` | `port-number.wav` | 2.341 | `8d16563b2b46…` |
| `person-name` | `person-name.wav` | 2.403 | `7e2db622b503…` |
| `jargon-spelling` | `jargon-spelling.wav` | 2.708 | `28907de63b18…` |
| `git-command` | `git-command.wav` | 2.895 | `18a9c97ae505…` |
| `real-version-number` | `real-talk-gemini15.wav` | 22.000 | `f3f7675222c6…` |
| `real-mandarin` | `real-mandarin.wav` | 22.000 | `4aca3bc15b67…` |
| `real-codeswitch` | `real-codeswitch.wav` | 20.000 | `817acab2574d…` |
| `real-acronym` | `real-acronym.wav` | 20.000 | `73aa2f1a826f…` |
| `real-acronym-chain` | `real-acronym-chain.wav` | 20.000 | `fcd89387fc11…` |
| `real-jargon` | `real-jargon.wav` | 20.000 | `4d024fcf7394…` |
| `real-brand` | `real-brand.wav` | 20.000 | `639f55c192e0…` |
| `benefit-novel-name` | `novel-name.wav` | 2.620 | `f1aba3279d1a…` |
| `benefit-novel-codename` | `novel-codename.wav` | 2.845 | `6190253bf677…` |
| `benefit-novel-repo` | `novel-repo.wav` | 2.703 | `3838c821face…` |
| `benefit-caret-channel` | `novel-name.wav` | 2.620 | `f1aba3279d1a…` |

## Ground truth

### `gemini-version` — `gemini-version.wav`

- **Exact transcript**: We should switch to Gemini 3.5 Flash for this.
- Why: The founding case. Screen says 'Gemini 3 Flash' five times; the speaker said 3.5. A version number is content, not spelling.

### `port-number` — `port-number.wav`

- **Exact transcript**: Run the dev server on port 8081.
- Why: Terminal buffer is full of 8080. The speaker said 8081 — one digit off, which is exactly when a prior overrides clear audio.

### `person-name` — `person-name.wav`

- **Exact transcript**: Can you send the draft to Priya before Friday?
- Why: The visible thread is entirely about Marcus. The speaker named someone else. Names are content.

### `jargon-spelling` — `jargon-spelling.wav`

- **Exact transcript**: We load the native library through koffi at startup.
- Why: The positive control: speaker says something that sounds like 'coffee', the screen spells the library 'koffi', and grounding should make this a spelling fix. Passes 3/3 on native Gemini. Fails 0/3 through OpenRouter, which regressed a correct 'koffi' baseline to 'Coffee' — this case is the one that exposed the provider difference, so keep it even when it is green.

### `git-command` — `git-command.wav`

- **Exact transcript**: Let's just do git commit --amend and move on.
- Why: Scrollback shows a longer form of the same command. Tests insertion: the extra flags are on screen but were never spoken.

### `real-version-number` — `real-talk-gemini15.wav`

- **Must contain**: 1.5
- **Must NOT contain**: 2.5
- Why: Real recorded speech, not synthesized — the case that actually catches the bug. The speaker says 'Gemini 1.5' mid-sentence and unstressed while the screen insists on 2.5. This is the only case in the suite that has ever reproduced substitution: measured 11/19 on gemini-3.6-flash against a 21% no-context baseline. Do not delete it to make the suite green. Asserted by fragment rather than exact match because a 22-second clip differs run to run on wording the suite is not measuring.

### `real-mandarin` — `real-mandarin.wav`

- **Must NOT contain**: storyline branching engine, user response
- Why: Real Mandarin speech. Exercises two paths nothing else covers: the CJK branch of the token estimator, and rule 6 — transcribe in the language spoken, never translate. The English screen context is a translation temptation, and an English transcript would mean the model obeyed the screen over the speaker.

### `real-codeswitch` — `real-codeswitch.wav`

- **Must contain**: retrieval pipeline, 4240
- **Must NOT contain**: 4250, 4200
- Why: Real code-switched speech: Mandarin with English technical terms embedded ('retrieval pipeline', 'index'). Probes two rules at once. Rule 6 — transcribe in the language spoken, never translate — is tested by an English screen context that makes translating the obvious 'helpful' move. Rule 4 is tested by a number one digit off what is on screen. Code-switching is where a model is most tempted to normalise, because neither language is unambiguously the target.

### `real-acronym` — `real-acronym.wav`

- **Must contain**: gradient
- **Must NOT contain**: GRPO
- Why: Real speech in which the speaker says 'DAPO' — a real RL algorithm — while the screen is full of GRPO, an equally real and similar-sounding one. Acronyms are the hardest near-miss: they are short, unstressed, phonetically close, and the model has strong priors about which ones exist. This is the case a dictionary-based tool fails worst, because both are plausible vocabulary entries.

### `real-acronym-chain` — `real-acronym-chain.wav`

- **Must contain**: VAD, ASR
- **Must NOT contain**: TTS, NLU
- Why: Real English speech naming three acronyms in one breath — VAD, ASR, and the expansion 'voice activity detection'. The screen is full of TTS and NLU, two equally real speech-pipeline acronyms that belong in exactly this sentence. Harder than a single acronym because the model must hold several unfamiliar tokens while a plausible alternative vocabulary sits in front of it, and because the spoken expansion gives it a second chance to 'correct' the abbreviation.

### `real-jargon` — `real-jargon.wav`

- **Must contain**: Scrum, work item
- **Must NOT contain**: Kanban, Jira
- Why: Real English speech saying 'Scrum dashboard' and 'work item' while the screen insists on Kanban and Jira. Methodology names are a near-miss class of their own: they are interchangeable in most sentences, so nothing about the surrounding words signals which one was actually said. A model inclined to make the transcript 'consistent with the screen' has every excuse here.

### `real-brand` — `real-brand.wav`

- **Must contain**: Google, Bing
- **Must NOT contain**: Baidu, DuckDuckGo
- Why: Real Mandarin speech comparing two search engines by name — 'Google 的搜索结果就比 Bing 的好'. Both brands are spoken, and the screen is one-sided about which one is the subject. The failure to catch is collapse: dropping the comparison to whichever brand the screen repeats. Also exercises rule 6, since the screen is entirely English while the speech is not.

### `benefit-novel-name` — `novel-name.wav`

- **Must contain**: Kaelith
- Why: A BENEFIT case that FAILS under the default encoding, kept for what it shows. 'Kaelith' comes back as 'Keyleth' -- a name the model already knows -- with the correct spelling in the visible text three times. The first explanation recorded here was that the model's own vocabulary is immovable; that was measured and is wrong. Moving the identical text into the caret window takes it from 0/12 to 12/12. The visible-text section is comparatively inert: it holds ten times the budget and carries far less weight, in both the helpful and the harmful direction. This case therefore measures the weak channel on purpose -- it is the one real apps mostly have.

### `benefit-novel-codename` — `novel-codename.wav`

- **Must contain**: Thessaly, Brindlewood
- Why: Two invented internal codenames in one utterance. 'Thessaly' is a real place name and so a weaker test on its own; 'Brindlewood' is the load-bearing one, since a transcriber without context has no reason to prefer it over 'brindle wood' or 'Brindalwood'. Both spellings are on screen.

### `benefit-novel-repo` — `novel-repo.wav`

- **Must contain**: quillmark-sync
- **Must NOT contain**: quill mark
- Why: A repository name, where the failure is a word boundary rather than a phoneme: 'quillmark-sync' is one token on screen and sounds like two. Without context a transcriber writes 'quill mark sync'. Also checks that the spoken 'dash' becomes a hyphen, which the screen shows but the audio only names.

### `benefit-caret-channel` — `novel-name.wav`

- **Must contain**: Kaelith
- **Must NOT contain**: Keyleth
- Why: The same audio and the same novel name as case 13, with the correct spelling moved into the caret window instead of the visible text. Case 13 fails 0/12 and this passes 12/12, and that pair is the sharpest measurement in the project: the caret sections hold a tenth of the visible-text budget and dominate it. Kept as a case, not just a note, because the finding lives in the encoder's section ordering and caps — anything that shrinks or drops the caret window would silently destroy grounding's only demonstrated benefit, and case 13 alone would not notice, since it already fails.

## How the cases are meant to be run

Every case runs **twice — with the screen context from its JSON, and without it**. The
difference between those two transcripts is by construction something grounding caused, and
that difference is the measurement. A single grounded run tells you almost nothing: the
no-context baseline on the reference clip is already wrong about 20% of the time, so a
grounded failure is only evidence if the baseline got it right.

Classification used by `dnt-eval`:

- **improved** — baseline wrong, grounded right. This is the feature working.
- **regressed** — baseline right, grounded wrong. This must be zero.
- **neutral** — both right, or both wrong.

Digits are compared exactly. That is what catches the failure this project exists for: a
version number on screen overwriting the one that was spoken.

## One measured caveat worth carrying over

Context does not arrive through one channel. The same correct spelling transferred 0/12
times from the visible-text section and 12/12 from the caret window; the same contradicting
value substituted 3/10 from visible text and 7/10 from the caret window. Any model
comparison should say which channel it put the context in, or the numbers are not
comparable.
