//
//  ChatDetailView.swift
//  intrai
//

import SwiftUI
import SwiftData
import MarkdownUI
#if canImport(UIKit)
import UIKit
#endif

struct ChatDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    let session: ChatSession
    @ObservedObject var intelligenceService: IntelligenceService
    var onSelectSession: ((UUID) -> Void)? = nil

    @State private var draftMessage = ""
    @State private var showingSnapshotSheet = false
    @FocusState private var isInputFocused: Bool
    @State private var showingRenameAlert = false
    @State private var renameDraft = ""
    @State private var wasInputFocused = false
    @State private var showingTrimConfirmation = false
    // Cached sort — re-evaluated only when the message count changes, not on every
    // keystroke render. Eliminates the O(n log n) sort on each frame during typing.
    // sortedMessages holds @Model reference-type objects: in-place mutations during
    // streaming (e.g. assistantMessage.text updates) propagate via SwiftData's @Observable
    // without requiring a count-triggered array refresh.
    @State private var sortedMessages: [ChatMessage] = []
    @State private var generationElapsedSeconds: Int = 0
    @State private var generationStartedAt: Date? = nil
    // Task-based timer: created when generation starts, cancelled when it ends.
    // Avoids the one-second run-loop wake cost while the user is not generating.
    @State private var elapsedTimerTask: Task<Void, Never>? = nil

    private var isGenerating: Bool {
        intelligenceService.isGenerating(for: session)
    }

    private var isWaitingForFirstFragment: Bool {
        isGenerating && sortedMessages.last?.validatedRole != .assistant
    }

    private var contextProgress: Double {
        intelligenceService.contextProgress(for: session)
    }

    private var progressBarColor: Color {
        // Thresholds align with AIContextBuilder risk tiers (yellow 0.40,
        // orange 0.55, red 0.70) — red fires before the hang zone so users
        // have warning while they still have room to keep chatting.
        if contextProgress >= 0.70 { return .red.opacity(0.8) }
        if contextProgress >= 0.55 { return .orange.opacity(0.7) }
        if contextProgress >= 0.40 { return .yellow.opacity(0.75) }
        return colorScheme == .dark ? .white.opacity(0.3) : .green.opacity(0.6)
    }

    private var progressTrackColor: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.08)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(sortedMessages, id: \.id) { message in
                            ChatMessageBubble(message: message) {
                                copyMessageAsMarkdown(message)
                            }
                            .id(message.id)
                        }

                        if isGenerating {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(isWaitingForFirstFragment
                                     ? "Thinking... \(generationElapsedSeconds)s"
                                     : "Generating...")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Button("Cancel") {
                                    cancelCurrentGeneration()
                                }
                                .font(.footnote)
                            }
                            .padding(.vertical, 4)
                            .id("generatingIndicator")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: sortedMessages.count) { _, _ in
                    if let last = sortedMessages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isGenerating) { _, generating in
                    if generating {
                        withAnimation {
                            proxy.scrollTo("generatingIndicator", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isInputFocused) { _, focused in
                    if focused, let last = sortedMessages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            ContextProgressBar(
                progress: contextProgress,
                barColor: progressBarColor,
                trackColor: progressTrackColor
            )
            .padding(.horizontal, 150)
            .padding(.top, 12)
            .padding(.bottom, contextProgress >= 0.70 ? 0 : 2)

            if contextProgress >= 0.70 {
                Text("Context almost full — responses may stall. Trim or start a new chat.")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)
            }

            if let errorText = intelligenceService.errorMessage(for: session) {
                let retryBlocked = intelligenceService.retryBlockedReason(for: session)
                let isContextBlocked = intelligenceService.isContextFullBlocked(for: session)

                if isContextBlocked {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)

                        HStack(spacing: 12) {
                            Button(role: .destructive) {
                                showingTrimConfirmation = true
                            } label: {
                                Label("Trim oldest", systemImage: "scissors")
                                    .font(.footnote)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                startNewChatFromBlocked()
                            } label: {
                                Label("Start new chat", systemImage: "square.and.pencil")
                                    .font(.footnote)
                            }
                            .buttonStyle(.bordered)

                            Spacer()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                } else {
                    HStack {
                        Text(retryBlocked ?? errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .lineLimit(2)

                        Spacer()

                        Button("Retry") {
                            Task {
                                await intelligenceService.retry(in: session, modelContext: modelContext)
                            }
                        }
                        .disabled(isGenerating || retryBlocked != nil)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
            }

            HStack(spacing: 8) {
                TextField("Message", text: $draftMessage, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($isInputFocused)

                Button {
                    sendCurrentDraft()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating || draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                    .onLongPressGesture {
                        wasInputFocused = isInputFocused
                        renameDraft = session.title
                        showingRenameAlert = true
                    }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingSnapshotSheet = true
                    } label: {
                        Label("Snapshot", systemImage: "doc.text.magnifyingglass")
                    }

                    Button {
                        exportMarkdown()
                    } label: {
                        Label("Copy as Markdown", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Label("Chat Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingSnapshotSheet) {
            SessionSnapshotView(session: session)
        }
        .alert("Rename Chat", isPresented: $showingRenameAlert) {
            TextField("Title", text: $renameDraft)
            Button("Save") {
                let cleaned = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    session.title = cleaned
                    try? modelContext.save()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Choose a new title for this chat.")
        }
        .confirmationDialog(
            "Trim oldest messages?",
            isPresented: $showingTrimConfirmation,
            titleVisibility: .visible
        ) {
            Button("Trim and retry", role: .destructive) {
                trimAndRetry()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The oldest exchanges will be permanently removed until the chat fits. This cannot be undone.")
        }
        .onChange(of: showingRenameAlert) { _, showing in
            if !showing && wasInputFocused {
                isInputFocused = true
            }
        }
        .onAppear {
            sortedMessages = session.orderedMessages
            intelligenceService.evaluateContextProgress(for: session)
        }
        .onChange(of: session.messages.count) { _, _ in
            sortedMessages = session.orderedMessages
        }
        .onChange(of: isGenerating) { _, generating in
            if generating {
                generationStartedAt = Date()
                generationElapsedSeconds = 0
                elapsedTimerTask?.cancel()
                elapsedTimerTask = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard let start = generationStartedAt else { break }
                        generationElapsedSeconds = Int(Date().timeIntervalSince(start))
                    }
                }
            } else {
                generationStartedAt = nil
                elapsedTimerTask?.cancel()
                elapsedTimerTask = nil
            }
        }
        .onDisappear {
            elapsedTimerTask?.cancel()
            cancelCurrentGeneration()
        }
    }

    private func sendCurrentDraft() {
        let prompt = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        // Resign focus first to end any active dictation session, then clear.
        // The deferred clear handles the race where dictation writes a final
        // transcription commit to the binding after the synchronous clear.
        isInputFocused = false
        draftMessage = ""
        DispatchQueue.main.async {
            self.draftMessage = ""
        }

        intelligenceService.cancelGeneration(in: session)
        Task {
            await intelligenceService.send(prompt, in: session, modelContext: modelContext)
        }
    }

    private func cancelCurrentGeneration() {
        intelligenceService.cancelGeneration(in: session)
    }

    private func exportMarkdown() {
        // ChatExport.markdown is pure string concatenation — no I/O.
        // UIPasteboard must be written on the main thread; this call site is already
        // main-actor-bound (invoked from a SwiftUI toolbar action).
        UIPasteboard.general.string = ChatExport.markdown(for: session)
    }

    private func copyMessageAsMarkdown(_ message: ChatMessage) {
        UIPasteboard.general.string = ChatExport.markdown(for: message)
    }

    private func trimAndRetry() {
        Task {
            await intelligenceService.trimOldestExchangesAndRetry(in: session, modelContext: modelContext)
        }
    }

    private func startNewChatFromBlocked() {
        if let newSession = intelligenceService.startNewChatFromBlockedPrompt(in: session, modelContext: modelContext) {
            onSelectSession?(newSession.id)
        }
    }
}

private struct ContextProgressBar: View {
    let progress: Double
    let barColor: Color
    let trackColor: Color

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(trackColor)

                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: geometry.size.width * clampedProgress)

                RoundedRectangle(cornerRadius: 2)
                    .stroke(barColor, lineWidth: 0.8)
            }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context usage")
        .accessibilityValue("\(Int(clampedProgress * 100)) percent")
    }
}

private struct SessionSnapshotView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let session: ChatSession

    @State private var refreshReason = ""
    @State private var showingRefreshConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Snapshot Metadata") {
                    LabeledContent("Version", value: "\(session.snapshotVersion)")
                    LabeledContent("Created", value: session.createdAt.formatted(date: .abbreviated, time: .shortened))

                    if let refreshedAt = session.lastSnapshotRefreshAt {
                        LabeledContent("Last Refresh", value: refreshedAt.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        LabeledContent("Last Refresh", value: "Never")
                    }

                    if let reason = session.snapshotRefreshReason, !reason.isEmpty {
                        Text("Reason: \(reason)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Prompt Snapshot") {
                    Text(session.systemPromptSnapshot)
                        .font(.footnote)
                        .textSelection(.enabled)
                }

                Section("Refresh Snapshot") {
                    Text("Refreshing replaces this chat's snapshot with the latest global system prompt and memory facts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("Refresh reason", text: $refreshReason)

                    Button("Refresh from Global Memory") {
                        showingRefreshConfirmation = true
                    }
                    .disabled(refreshReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Session Snapshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Refresh this chat snapshot?",
                isPresented: $showingRefreshConfirmation,
                titleVisibility: .visible
            ) {
                Button("Refresh", role: .destructive) {
                    let memory = UserMemory.fetch(from: modelContext)
                    let newSnapshot = SnapshotBuilder.compose(from: memory)
                    session.refreshSnapshot(newSnapshot, reason: refreshReason)
                    try? modelContext.save()
                    refreshReason = ""
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Existing chat history remains unchanged. Only future responses in this chat use the updated snapshot.")
            }
        }
    }
}

private struct ChatMessageBubble: View {
    let message: ChatMessage
    let onCopyAsMarkdown: () -> Void

    var body: some View {
        let isUser = message.validatedRole == .user

        HStack {
            if isUser {
                Spacer(minLength: 20)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(isUser ? "User" : "Assistant")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if isUser {
                    Text(message.text)
                } else {
                    Markdown(message.text)
                        .markdownTheme(
                            .gitHub
                                .text {
                                    ForegroundColor(.primary)
                                    BackgroundColor(nil)
                                }
                                .code {
                                    FontFamilyVariant(.monospaced)
                                    FontSize(.em(0.85))
                                    ForegroundColor(.primary)
                                    BackgroundColor(.secondary.opacity(0.15))
                                }
                        )
                }

                Text(message.timestamp, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(isUser ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contextMenu {
                Button {
                    onCopyAsMarkdown()
                } label: {
                    Label("Copy as Markdown", systemImage: "doc.on.clipboard")
                }
            }

            if !isUser {
                Spacer(minLength: 20)
            }
        }
    }
}
