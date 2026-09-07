# Homebrew cask for DoNotType.
#
# This repository *is* the tap. `Casks/` is one of the three directories Homebrew looks in, so the
# file installed from is the file reviewed in this pull request — there is no second copy to fall
# out of date, and no submission step to forget:
#
#     brew tap bojieli/donottype https://github.com/bojieli/DoNotType
#     brew install --cask donottype
#
# The URL is required because a tap is normally found by the name `homebrew-<x>`, and this repo is
# named for the product rather than for Homebrew. That is the whole cost of keeping one copy.
#
# Not submitted to homebrew-cask itself yet: registry onboarding should follow a notarized release
# with some public history. Until then this is the supported way to install.
#
# The version and checksum below are written by `scripts/update-packaging.sh <version>`, which the
# release workflow runs for itself when a release is published — nobody hand-copies a sha256, and a
# cask with a stale hash fails at install time complaining about a corrupt download, which is a bad
# way to learn that a field was forgotten.
cask "donottype" do
  version "0.6.2"
  sha256 "56a017fe48be8e459156050c3dce8f5fbed38524e9be90aa9c025aefe2862493"

  # No `verified:` — Homebrew deprecated it, and it was always redundant here: the default check
  # is that the download host matches `homepage`, which it does.
  url "https://github.com/bojieli/DoNotType/releases/download/v#{version}/DoNotType-macOS.zip"
  name "DoNotType"
  desc "Voice input that transcribes what you said instead of rewriting it"
  homepage "https://github.com/bojieli/DoNotType/"

  # Matches LSMinimumSystemVersion in Resources/Info.plist and .macOS(.v14) in Package.swift.
  # Without it Homebrew installs happily onto an older system and the app refuses to launch, which
  # is a worse way to learn the requirement than being told before the download.
  depends_on macos: ">= :sonoma"

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
