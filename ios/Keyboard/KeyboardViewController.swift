import DoNotTypeCore
import UIKit

/// The keyboard.
///
/// It inserts; it does not record. `AVAudioSession.setActive` fails inside a keyboard extension
/// with `AVAudioSessionErrorCodeCannotStartRecording` — the microphone is simply not available to
/// this process, regardless of Full Access. So the containing app produces transcripts and this
/// reads them out of the App Group.
///
/// Full Access *is* required, for the shared container. Without it the list is empty and the
/// keyboard says so rather than appearing broken.
final class KeyboardViewController: UIInputViewController {

    private let store = TranscriptStore()
    private let dictionaryStore = DictionaryStore()
    private let correctionStore = CorrectionObservationStore()
    private var entries: [TranscriptStore.Entry] = []
    private var correctionTask: Task<Void, Never>?
    private var lastLearnedTerms: [String] = []

    private lazy var tableView = UITableView(frame: .zero, style: .plain)
    private lazy var statusLabel = UILabel()
    private lazy var nextKeyboardButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()

        // The app posts a Darwin notification when it stores a transcript, so switching back to
        // the keyboard shows it without a manual refresh.
        // Hopped to the main actor explicitly. The notification arrives on a Darwin callback with
        // no isolation of its own, and `reload` touches UIKit — Swift 6.2 infers the hop, 6.0 does
        // not, and relying on inference for a UI update from a C callback is the wrong bet either
        // way.
        TranscriptStore.observeUpdates {
            Task { @MainActor [weak self] in self?.reload() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
        observePendingCorrection()
    }

    override func viewWillDisappear(_ animated: Bool) {
        correctionTask?.cancel()
        correctionTask = nil
        super.viewWillDisappear(animated)
    }

    // MARK: - Interface

    private func buildInterface() {
        view.backgroundColor = .secondarySystemBackground

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.accessibilityIdentifier = "kb-status"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isUserInteractionEnabled = true
        statusLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(statusTapped)))

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "transcript")
        tableView.accessibilityIdentifier = "kb-transcripts"
        tableView.translatesAutoresizingMaskIntoConstraints = false

        nextKeyboardButton.setTitle("🌐", for: .normal)
        nextKeyboardButton.accessibilityIdentifier = "kb-next"
        nextKeyboardButton.accessibilityLabel = "Next keyboard"
        nextKeyboardButton.titleLabel?.font = .systemFont(ofSize: 22)
        nextKeyboardButton.addTarget(
            self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        nextKeyboardButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(statusLabel)
        view.addSubview(tableView)
        view.addSubview(nextKeyboardButton)

        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 260),

            statusLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: nextKeyboardButton.topAnchor, constant: -4),

            nextKeyboardButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            nextKeyboardButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            nextKeyboardButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func reload() {
        entries = store.load()

        // Asked of the system rather than inferred from the container being nil. Both produce an
        // empty list, and they are different problems: one is a switch the user can turn on, the
        // other is an app-group misconfiguration in a build, which no amount of tapping fixes. A
        // keyboard extension cannot open Settings, so the exact path is the whole of the guidance.
        if !hasFullAccess {
            statusLabel.text =
                "Turn on Full Access in Settings › General › Keyboard › Keyboards › DoNotType so "
                + "this keyboard can read your transcripts."
        } else if TranscriptStore.containerURL == nil {
            statusLabel.text =
                "Full Access is on, but the shared container is missing — this build is "
                + "misconfigured. Please report it."
        } else if entries.isEmpty {
            statusLabel.text = "Open DoNotType and dictate — transcripts appear here to insert."
        } else {
            statusLabel.text = "Tap to insert"
        }
        tableView.reloadData()
    }

    @objc private func statusTapped() {
        guard !lastLearnedTerms.isEmpty else { return }
        if let snapshot = try? dictionaryStore.forgetLearned(lastLearnedTerms) {
            statusLabel.text = "Removed learned spelling · \(snapshot.all.count) dictionary entries"
        }
        lastLearnedTerms = []
    }

    private func correctionAnchor(for inserted: String) -> CorrectionObservationStore.Pending? {
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        // Both are nil in a secure field. Empty strings in an ordinary blank field are safe.
        guard before != nil || after != nil else { return nil }
        return .init(
            documentID: textDocumentProxy.documentIdentifier,
            prefix: String((before ?? "").suffix(32)),
            suffix: String((after ?? "").prefix(32)),
            inserted: inserted)
    }

    /// Polls while this keyboard is visible; the persisted anchor resumes after switching back.
    private func observePendingCorrection() {
        correctionTask?.cancel()
        guard dictionaryStore.load().learnsFromEdits,
            let pending = correctionStore.load(),
            pending.documentID == textDocumentProxy.documentIdentifier
        else { return }

        correctionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var prior: String?
            var stableReads = 0
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled,
                    pending.documentID == textDocumentProxy.documentIdentifier
                else { return }
                guard let edited = observedInsertion(pending) else { return }
                if edited == pending.inserted {
                    prior = nil
                    stableReads = 0
                    continue
                }
                if edited == prior { stableReads += 1 }
                else { prior = edited; stableReads = 1 }
                guard stableReads >= 2 else { continue }

                let candidates = PersonalDictionary.learnedCandidates(
                    from: pending.inserted, corrected: edited)
                if let (_, added) = try? dictionaryStore.learn(candidates), !added.isEmpty {
                    lastLearnedTerms = added
                    statusLabel.text = "Learned \(added.joined(separator: ", ")) — tap to undo"
                }
                correctionStore.clear()
                return
            }
        }
    }

    private func observedInsertion(_ pending: CorrectionObservationStore.Pending) -> String? {
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        guard before != nil || after != nil else { return nil }
        let combined = (before ?? "") + (after ?? "")

        let start: String.Index
        if pending.prefix.isEmpty { start = combined.startIndex }
        else {
            guard let anchor = combined.range(of: pending.prefix, options: .backwards) else {
                return nil
            }
            start = anchor.upperBound
        }

        let end: String.Index
        if pending.suffix.isEmpty { end = combined.endIndex }
        else {
            guard let anchor = combined.range(of: pending.suffix, range: start..<combined.endIndex)
            else { return nil }
            end = anchor.lowerBound
        }
        guard start <= end else { return nil }
        return String(combined[start..<end])
    }
}

extension KeyboardViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "transcript", for: indexPath)
        let entry = entries[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = entry.text
        content.textProperties.numberOfLines = 2
        content.secondaryText = entry.inserted ? "inserted" : nil
        content.secondaryTextProperties.color = .tertiaryLabel
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = entries[indexPath.row]

        let correction = dictionaryStore.load().learnsFromEdits
            ? correctionAnchor(for: entry.text) : nil
        textDocumentProxy.insertText(entry.text)
        if let correction {
            correctionStore.save(correction)
            observePendingCorrection()
        } else {
            correctionStore.clear()
        }
        store.markInserted(entry.id)
        reload()
    }
}
