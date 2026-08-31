# Homebrew cask for DoNotType.
#
# Not submitted to homebrew-cask yet: registry onboarding should follow a notarized release with
# some public history. Until then this file lives here so it can be installed from a tap, and so the
# shape of the thing is reviewable rather than invented at submission time:
#
#     brew install --cask bojieli/tap/donottype
#
# `scripts/update-packaging.sh <version>` fills in the version and the checksum from a published
# release, so nobody hand-copies a sha256 — a cask with a stale hash fails at install time with a
# message about a corrupt download, which is a bad way to learn that a field was forgotten.
cask "donottype" do
  version "0.5.0"
  sha256 "85fa4adc43f1800623f6185a57433878e6a2d2c63af342bdc98d83cf7aaaf64b"

  url "https://github.com/bojieli/DoNotType/releases/download/v#{version}/DoNotType-macOS.zip",
      verified: "github.com/bojieli/DoNotType/"
  name "DoNotType"
  desc "Voice input that transcribes what you said instead of rewriting it"
  homepage "https://github.com/bojieli/DoNotType/"

  # Accessibility is revoked whenever the signature changes, so an update always needs re-granting.
  # Saying so here is cheaper than a support thread about dictation that silently stopped.
  caveats <<~CAVEATS
    DoNotType needs Accessibility and Microphone permission, and asks for both at first launch.

    macOS revokes Accessibility whenever an app's signature changes, so after an update you may
    need to re-grant it in System Settings › Privacy & Security › Accessibility.

    The `dnt` command line ships inside the bundle. To put it on your PATH:
      sudo ln -sf "/Applications/DoNotType.app/Contents/MacOS/dnt" /usr/local/bin/dnt
  CAVEATS

  app "DoNotType.app"

  # The app stores history, logs and any edited prompt here; `--zap` removes them, an ordinary
  # uninstall does not. Deleting somebody's transcripts should take asking for it.
  zap trash: [
    "~/Library/Application Support/DoNotType",
    "~/Library/Preferences/app.donottype.plist",
  ]
end
