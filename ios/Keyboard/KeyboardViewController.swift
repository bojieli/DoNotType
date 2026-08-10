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
    private var entries: [TranscriptStore.Entry] = []

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
    }

    // MARK: - Interface

    private func buildInterface() {
        view.backgroundColor = .secondarySystemBackground

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "transcript")
        tableView.translatesAutoresizingMaskIntoConstraints = false

        nextKeyboardButton.setTitle("🌐", for: .normal)
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

        if TranscriptStore.containerURL == nil {
            statusLabel.text =
                "Turn on Full Access in Settings › General › Keyboard › DoNotType so this keyboard "
                + "can read your transcripts."
        } else if entries.isEmpty {
            statusLabel.text = "Open DoNotType and dictate — transcripts appear here to insert."
        } else {
            statusLabel.text = "Tap to insert"
        }
        tableView.reloadData()
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

        textDocumentProxy.insertText(entry.text)
        store.markInserted(entry.id)
        reload()
    }
}
