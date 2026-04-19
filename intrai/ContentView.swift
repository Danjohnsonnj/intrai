//
//  ContentView.swift
//  intrai
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatSession.createdAt, order: .reverse) private var sessions: [ChatSession]

    @StateObject private var intelligenceService = IntelligenceService()
    @State private var intentStore = PendingIntentStore.shared
    @State private var selectedSessionID: UUID?
    @State private var renameSessionID: UUID?
    @State private var renameDraftTitle = ""
    @State private var showingMemorySettings = false

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
            if let selectedSession {
                ChatDetailView(session: selectedSession, intelligenceService: intelligenceService)
            } else {
                ContentUnavailableView("Select a chat", systemImage: "bubble.left.and.bubble.right")
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
            handlePendingIntent()
        }
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
}

private struct MemorySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var systemPromptDraft = ""
    @State private var factsDraft = ""
    @State private var didLoad = false

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
                    Text("Changes apply to newly created chat sessions. Existing sessions keep their current snapshot unless you refresh them from the Snapshot panel.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                        let memory = UserMemory.fetch(from: modelContext)
                        memory.update(facts: factsDraft, systemPrompt: systemPromptDraft)
                        try? modelContext.save()
                        dismiss()
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
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            ChatSession.self,
            ChatMessage.self,
            UserMemory.self,
        ], inMemory: true)
}
