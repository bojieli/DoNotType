# Settings transfer format

This document specifies the settings transfer format shared by all DoNotType GUI clients: format
version 1 as UTF-8 JSON, transferred either as text/file or directly in a QR code.

## Format version 1

Every DoNotType GUI client imports and exports format version 1 as UTF-8 JSON. The same compact
JSON bytes are placed directly in a QR code; there is no separate URL or vendor-specific wrapper.

```json
{
  "format": "app.donottype.settings",
  "version": 1,
  "selectedProvider": "google",
  "providers": {
    "google": {
      "model": "gemini-3.5-flash",
      "apiKey": "secret"
    }
  },
  "fidelity": "light",
  "fallback": null,
  "retention": "forever",
  "keepAudio": false,
  "dictionary": {
    "manual": [],
    "learned": [],
    "learnsFromEdits": false
  }
}
```

## Provider IDs

Recognized provider IDs are `google`, `openrouter`, `local`, `deepgram`, `xai`, and `mistral`.
Importers also accept the legacy `gemini` spelling for `google`. A provider object may also
contain `textModel` and `endpoint`. Unknown provider and platform-block entries are ignored
unless one is selected as the primary or fallback.

## Platform blocks

The optional `desktop`, `iOS`, `android`, and `windows` objects carry settings without a
meaningful equivalent everywhere else. A client applies the common fields and its own platform
block.

## Secret handling

API keys are intentionally included so an imported profile works. The document and QR code are
therefore plaintext secrets and must be handled like passwords. Import screens stage and display
the JSON before applying it.

## Size limits

Documents larger than 1 MiB are rejected. A profile too large for one QR code remains
transferable as JSON text or a file.
