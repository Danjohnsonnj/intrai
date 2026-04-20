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

    @State private var draftMessage = ""
    @State private var showingSnapshotSheet = false
    @FocusState private var isInputFocused: Bool
    @State private var showingRenameAlert = false
    @State private var renameDraft = ""
    @State private var wasInputFocused = false

    private var orderedMessages: [ChatMessage] {
        session.orderedMessages
    }

    private var isGenerating: Bool {
        intelligenceService.isGenerating(for: session)
    }

    private var contextProgress: Double {
        intelligenceService.contextProgress(for: session)
    }

    private var progressBarColor: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.08)
    }

    private var progressTrackColor: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.08)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(orderedMessages, id: \.id) { message in
                            ChatMessageBubble(message: message) {
                                copyMessageAsMarkdown(message)
                            }
                                .id(message.id)
                        }

                        if isGenerating {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Generating response...")
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
                .onChange(of: orderedMessages.count) { _, _ in
                    if let last = orderedMessages.last {
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
                    if focused, let last = orderedMessages.last {
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
            .padding(.bottom, 2)

            if let errorText = intelligenceService.errorMessage(for: session) {
                HStack {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .lineLimit(2)

                    Spacer()

                    Button("Retry") {
                        Task {
                            await intelligenceService.retry(in: session, modelContext: modelContext)
                        }
                    }
                    .disabled(isGenerating)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
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
        .onChange(of: showingRenameAlert) { _, showing in
            if !showing && wasInputFocused {
                isInputFocused = true
            }
        }
        .onAppear {
            intelligenceService.evaluateContextProgress(for: session)
        }
        .onDisappear {
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
        UIPasteboard.general.string = ChatExport.markdown(for: session)
    }

    private func copyMessageAsMarkdown(_ message: ChatMessage) {
        UIPasteboard.general.string = ChatExport.markdown(for: message)
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
