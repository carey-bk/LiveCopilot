import SwiftUI
import AppKit

/// Browse past sessions saved when you stop listening: a master list of sessions
/// on the left, the full speaker-labelled transcript on the right.
struct HistoryView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var sessions: SessionStore
    @State private var selectedID: SessionRecord.ID?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.sessions = coordinator.sessions
    }
    private func t(_ text: String) -> String { L10n.text(text, language: coordinator.settings.language) }

    private var selected: SessionRecord? {
        sessions.sessions.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            sessionList
            Divider()
            detail
        }
        .background { WindowBackgroundView(style: coordinator.settings.background) }
        .preferredColorScheme(coordinator.settings.background.usesLightAppearance ? .light : nil)
        .environment(\.locale, coordinator.settings.language.locale)
        .frame(minWidth: 620, minHeight: 420)
        .onAppear {
            if selectedID == nil { selectedID = sessions.sessions.first?.id }
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t("Sessions"))
                .font(.headline)
                .padding(12)
            if sessions.sessions.isEmpty {
                Text(t("No saved sessions yet.\nStop a listening session to save it here."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer()
            } else {
                List(selection: $selectedID) {
                    ForEach(sessions.sessions) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                                .font(.system(size: 13, weight: .medium))
                            Text("\(session.lineCount) \(t("lines")) · \(session.durationLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(session.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(width: 220)
    }

    @ViewBuilder
    private var detail: some View {
        if let session = selected {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title).font(.headline)
                        Text("\(session.lineCount) \(t("lines")) · \(session.durationLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.plainText, forType: .string)
                    } label: { Label(t("Copy"), systemImage: "doc.on.doc") }
                    Button(role: .destructive) {
                        let toDelete = session
                        selectedID = nil
                        sessions.delete(toDelete)
                        selectedID = sessions.sessions.first?.id
                    } label: { Label(t("Delete"), systemImage: "trash") }
                }
                .padding(12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(session.lines) { line in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(t(line.speaker.rawValue))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(line.speaker == .you ? .blue : .green)
                                    Text(line.clock)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                Text(line.content)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        } else {
            VStack {
                Spacer()
                Text(t("Select a session")).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}
