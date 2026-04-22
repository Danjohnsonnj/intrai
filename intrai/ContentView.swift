//
//  ContentView.swift
//  intrai
//

import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \ChatSession.createdAt, order: .reverse) private var sessions: [ChatSession]

    @StateObject private var intelligenceService = IntelligenceService()
    @State private var intentStore = PendingIntentStore.shared
    @State private var selectedSessionID: UUID?
    @State private var renameSessionID: UUID?
    @State private var renameDraftTitle = ""
    @State private var showingMemorySettings = false
    @State private var abortRecoveryBannerVisible = false
    @State private var abortRecoveryBannerEntryID: UUID? = nil

    private let acknowledgedAbortKey = "intrai.acknowledgedAbortRecoveryEntryID"

    private var selectedSession: ChatSession? {
        guard let selectedSessionID else {
            return nil
        }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if abortRecoveryBannerVisible {
                    abortRecoveryBanner
                }
                if let selectedSession {
                    ChatDetailView(
                        session: selectedSession,
                        intelligenceService: intelligenceService,
                        onSelectSession: { newID in
                            selectedSessionID = newID
                        }
                    )
                } else {
                    ContentUnavailableView("Select a chat", systemImage: "bubble.left.and.bubble.right")
                }
            }
        }
        .alert("Rename Chat", isPresented: renameAlertBinding) {
            TextField("Title", text: $renameDraftTitle)
            Button("Save", action: commitRename)
            Button("Cancel", role: .cancel) {
                renameSessionID = nil
                renameDraftTitle = ""
            }
        } message: {
            Text("Choose a new title for this chat.")
        }
        .sheet(isPresented: $showingMemorySettings) {
            MemorySettingsView()
        }
        .onAppear {
            FreezeLogger.shared.start()
            FreezeLogger.shared.setScenePhase(scenePhaseString(scenePhase))
            handlePendingIntent()
            // Fire-and-forget: cache the live `SystemLanguageModel.default.contextSize`
            // so the pre-flight gate and risk banner scale with the model. Hotfix
            // 0.2.111 removed the `tokenCount(for:)` call that used to also run
            // here — it could wedge the same way `respond(to:)` can.
            Task.detached(priority: .utility) {
                await AIContextBuilder.loadRuntimeLimits()
            }
            checkForPostAbortRecoveryBanner()
        }
        .onChange(of: scenePhase) { _, phase in
            FreezeLogger.shared.setScenePhase(scenePhaseString(phase))
            if phase == .background {
                FreezeLogger.shared.flushToDisk()
            }
        }
#if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            FreezeLogger.shared.recordMemoryWarning()
        }
#endif
        .onChange(of: intentStore.pendingQuestion) {
            handlePendingIntent()
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedSessionID) {
            ForEach(sessions, id: \.id) { session in
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.headline)
                        .lineLimit(1)

                    Text(session.createdAt, format: .dateTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(session.id)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteSession(session)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        beginRename(session)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingMemorySettings = true
                } label: {
                    Label("Memory Settings", systemImage: "brain")
                }
            }
            ToolbarItem {
                Button {
                    addSession()
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Chats")
    }

    // MARK: - Helpers

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameSessionID != nil },
            set: { isPresented in
                if !isPresented {
                    renameSessionID = nil
                    renameDraftTitle = ""
                }
            }
        )
    }

    @discardableResult
    private func addSession() -> ChatSession {
        let memory = UserMemory.fetch(from: modelContext)
        let snapshot = SnapshotBuilder.compose(from: memory)
        let session = ChatSession(title: "New Chat", systemPromptSnapshot: snapshot)
        withAnimation {
            modelContext.insert(session)
            selectedSessionID = session.id
        }
        try? modelContext.save()
        return session
    }

    private func handlePendingIntent() {
        guard let question = intentStore.pendingQuestion else { return }
        intentStore.pendingQuestion = nil
        let session = addSession()
        Task {
            await intelligenceService.send(question, in: session, modelContext: modelContext)
        }
    }

    private func beginRename(_ session: ChatSession) {
        renameSessionID = session.id
        renameDraftTitle = session.title
    }

    private func commitRename() {
        guard let renameSessionID else {
            return
        }

        let cleanedTitle = renameDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty else {
            return
        }

        guard let session = sessions.first(where: { $0.id == renameSessionID }) else {
            self.renameSessionID = nil
            renameDraftTitle = ""
            return
        }

        session.title = cleanedTitle
        try? modelContext.save()

        self.renameSessionID = nil
        renameDraftTitle = ""
    }

    private func deleteSession(_ session: ChatSession) {
        withAnimation {
            if selectedSessionID == session.id {
                selectedSessionID = nil
            }
            modelContext.delete(session)
            try? modelContext.save()
        }
    }

    private func scenePhaseString(_ phase: ScenePhase) -> String {
        switch phase {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }

    // MARK: - Post-abort recovery banner

    @ViewBuilder
    private var abortRecoveryBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your last response was cancelled automatically because the model stopped responding. Your chat was preserved.")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                dismissAbortRecoveryBanner()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.yellow.opacity(0.15))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(.separator),
            alignment: .bottom
        )
    }

    /// Reads the disk log for the most recent `force_recovery_unreachable_mainactor`
    /// entry. If it's newer than whatever the user has already dismissed
    /// (tracked in UserDefaults by that entry's UUID), surface the banner.
    /// Runs on a detached task so we never block the launch path on disk IO.
    private func checkForPostAbortRecoveryBanner() {
        let acknowledgedID = UserDefaults.standard.string(forKey: acknowledgedAbortKey)
        Task.detached(priority: .utility) {
            guard let entry = DiskFreezeLogger.shared.latestAbortRecoveryEntry() else { return }
            let entryIDString = entry.id.uuidString
            if acknowledgedID == entryIDString { return }
            await MainActor.run {
                abortRecoveryBannerEntryID = entry.id
                abortRecoveryBannerVisible = true
                FreezeLogger.shared.log(
                    "abort_recovery_banner_shown",
                    level: .warning,
                    metadata: [
                        "abortEntryID": entryIDString,
                        "abortEntryTimestamp": ISO8601DateFormatter().string(from: entry.timestamp)
                    ]
                )
            }
        }
    }

    private func dismissAbortRecoveryBanner() {
        if let id = abortRecoveryBannerEntryID {
            UserDefaults.standard.set(id.uuidString, forKey: acknowledgedAbortKey)
        }
        abortRecoveryBannerVisible = false
    }
}

private struct MemorySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var systemPromptDraft = ""
    @State private var factsDraft = ""
    @State private var didLoad = false
    @State private var diagnosticsExportURL: URL?
    @State private var showingDiagnosticsShareSheet = false
    @State private var diagnosticsExportError: String?
    @State private var showingContextWarning = false

    private let diagnosticsBuildVersion = "0.2.111"

    private var combinedTokenEstimate: Int {
        let combined = systemPromptDraft + "\n" + factsDraft
        let chars = Double(combined.utf16.count)
        return Int(0.7 * (chars / 4.8) + 0.3 * (chars / 3.2))
    }

    private var tokenBudgetPercent: Int {
        Int(Double(combinedTokenEstimate) / 3_500.0 * 100)
    }

    private var tokenCountColor: Color {
        if tokenBudgetPercent >= 80 { return .red }
        if tokenBudgetPercent >= 60 { return .orange }
        return .secondary
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Global System Prompt") {
                    TextEditor(text: $systemPromptDraft)
                        .frame(minHeight: 120)
                }

                Section("User Memory") {
                    TextEditor(text: $factsDraft)
                        .frame(minHeight: 150)
                }

                Section {
                    Text("~\(combinedTokenEstimate) tokens (\(tokenBudgetPercent)% of context budget)")
                        .font(.footnote)
                        .foregroundStyle(tokenCountColor)
                    Text("Changes apply to newly created chat sessions. Existing sessions keep their current snapshot unless you refresh them from the Snapshot panel.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Diagnostics") {
                    Button("Export Freeze Diagnostics") {
                        exportDiagnostics()
                    }

                    Text("Diagnostics are available in Debug/TestFlight builds and export as JSON for offline analysis.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let diagnosticsExportError {
                        Text(diagnosticsExportError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Text("Diagnostics Build \(diagnosticsBuildVersion)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .navigationTitle("Memory Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        if tokenBudgetPercent > 60 {
                            showingContextWarning = true
                        } else {
                            saveMemory()
                        }
                    }
                }
            }
            .onAppear {
                guard !didLoad else {
                    return
                }
                didLoad = true
                let memory = UserMemory.fetch(from: modelContext)
                systemPromptDraft = memory.systemPrompt
                factsDraft = memory.facts
            }
            .sheet(isPresented: $showingDiagnosticsShareSheet) {
#if canImport(UIKit)
                if let diagnosticsExportURL {
                    ActivityShareView(activityItems: [diagnosticsExportURL])
                }
#endif
            }
            .alert("Large System Prompt", isPresented: $showingContextWarning) {
                Button("Save Anyway") { saveMemory() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your system prompt and memory use ~\(tokenBudgetPercent)% of the context budget, leaving less room for conversation. Consider trimming them.")
            }
        }
    }

    private func saveMemory() {
        let memory = UserMemory.fetch(from: modelContext)
        memory.update(facts: factsDraft, systemPrompt: systemPromptDraft)
        try? modelContext.save()
        dismiss()
    }

    private func exportDiagnostics() {
        Task {
            do {
                diagnosticsExportURL = try await FreezeLogger.shared.exportToTemporaryFile()
                diagnosticsExportError = nil
                showingDiagnosticsShareSheet = true
            } catch {
                diagnosticsExportError = "Could not export diagnostics: \(error.localizedDescription)"
            }
        }
    }
}

#if canImport(UIKit)
private struct ActivityShareView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // no-op
    }
}
#endif

#Preview {
    ContentView()
        .modelContainer(for: [
            ChatSession.self,
            ChatMessage.self,
            UserMemory.self,
        ], inMemory: true)
}
