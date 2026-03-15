import SwiftUI

struct ContentView: View {
    @StateObject private var client = PhoneClient()
    @StateObject private var dictation = DictationEngine()

    @State private var inputText = ""
    @State private var isSending = false
    @State private var showSettings = false
    @State private var errorBanner: String? = nil
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar

                Divider()
                    .background(Color(white: 0.12))

                ZStack {
                    if client.messages.isEmpty {
                        emptyState
                    } else {
                        chatView
                    }
                }
                .frame(maxHeight: .infinity)

                // Space for the floating input bar
                Color.clear.frame(height: inputBarHeight)
            }

            // Floating input bar
            VStack(spacing: 0) {
                Divider().background(Color(white: 0.12))
                inputBar
            }
            .background(Color(red: 0.04, green: 0.04, blue: 0.06))

            // Error banner
            if let err = errorBanner {
                VStack {
                    Spacer()
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.85))
                        .clipShape(Capsule())
                        .padding(.bottom, inputBarHeight + 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView(client: client)
        }
        .onChange(of: dictation.transcript) { text in
            // Live transcription streams into the input field
            if dictation.isRecording || !text.isEmpty {
                inputText = text
            }
        }
        .onChange(of: dictation.isRecording) { recording in
            if !recording, !dictation.transcript.isEmpty {
                inputText = dictation.transcript
            }
        }
        .onChange(of: client.sendError) { err in
            guard let err else { return }
            showError(err)
            client.sendError = nil
        }
    }

    // MARK: - Layout constants

    private var inputBarHeight: CGFloat { 72 }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            statusDot

            VStack(alignment: .leading, spacing: 1) {
                Text(statusLabel)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(statusColor)

                if !client.project.isEmpty {
                    Text(client.project.split(separator: "/").last.map(String.init) ?? client.project)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(white: 0.4))
                        .lineLimit(1)
                }
            }

            Spacer()

            Button { showSettings = true } label: {
                Image(systemName: "gear")
                    .font(.system(size: 17))
                    .foregroundColor(Color(white: 0.45))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .shadow(color: statusColor.opacity(0.8), radius: 5)
    }

    private var statusLabel: String {
        if !client.isConnected { return "offline" }
        return client.hasSession ? "live" : "waiting"
    }

    private var statusColor: Color {
        if !client.isConnected { return .red }
        return client.hasSession ? Color(red: 0.25, green: 0.9, blue: 0.5) : .orange
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            if !client.isConnected {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 36))
                    .foregroundColor(Color(white: 0.2))
                Text("Can't reach server")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(Color(white: 0.3))
            } else if !client.hasSession {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 36))
                    .foregroundColor(Color(white: 0.2))
                Text("Waiting for session")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(Color(white: 0.3))
                Text("Run /warphole to start one")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.22))
            } else {
                ProgressView().tint(Color(white: 0.3))
            }
            Spacer()
        }
    }

    // MARK: - Chat

    private var chatView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(client.messages.enumerated()), id: \.offset) { idx, msg in
                        MessageBubble(message: msg)
                            .id(idx)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: client.messages.count) { _ in
                if let last = client.messages.indices.last {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 6) {
            // Quick-action keys row
            quickKeys

            HStack(spacing: 8) {
                // Text field
                TextField("Message…", text: $inputText, axis: .vertical)
                    .focused($inputFocused)
                    .font(.system(size: 15))
                    .foregroundColor(dictation.isRecording ? Color(red: 1, green: 0.35, blue: 0.35) : .white)
                    .tint(.blue)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(white: 0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .animation(.easeInOut(duration: 0.15), value: dictation.isRecording)

                // Mic button
                micButton

                // Send button
                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private var quickKeys: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                QuickKeyChip(label: "esc", icon: "escape") {
                    Task { await client.sendKey("Escape") }
                }
                QuickKeyChip(label: "ctrl+c", icon: "stop.circle") {
                    Task { await client.sendKey("C-c") }
                }
                QuickKeyChip(label: "↑", icon: nil) {
                    Task { await client.sendKey("Up") }
                }
                QuickKeyChip(label: "↓", icon: nil) {
                    Task { await client.sendKey("Down") }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var micButton: some View {
        Button {
            inputFocused = false
            dictation.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(dictation.isRecording
                          ? Color.red.opacity(0.85)
                          : Color(white: 0.14))
                    .frame(width: 40, height: 40)
                    .animation(.easeInOut(duration: 0.15), value: dictation.isRecording)

                Image(systemName: dictation.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(dictation.isRecording ? .white : Color(white: 0.55))
                    .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
            }
        }
        .disabled(dictation.permissionDenied)
        .opacity(dictation.permissionDenied ? 0.3 : 1)
    }

    private var sendButton: some View {
        Button {
            Task { await sendMessage() }
        } label: {
            ZStack {
                Circle()
                    .fill(canSend ? Color(red: 0.2, green: 0.45, blue: 0.95) : Color(white: 0.12))
                    .frame(width: 40, height: 40)
                    .animation(.easeInOut(duration: 0.15), value: canSend)

                if isSending {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.65)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(canSend ? .white : Color(white: 0.28))
                }
            }
        }
        .disabled(!canSend || isSending)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    // MARK: - Actions

    private func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if dictation.isRecording { dictation.stop() }
        isSending = true
        inputText = ""
        dictation.transcript = ""

        do {
            try await client.send(text: text)
        } catch {
            inputText = text   // restore on failure
            showError(error.localizedDescription)
        }

        isSending = false
    }

    private func showError(_ msg: String) {
        withAnimation { errorBanner = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { errorBanner = nil }
        }
    }
}

// MARK: - QuickKeyChip

struct QuickKeyChip: View {
    let label: String
    let icon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundColor(Color(white: 0.55))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color(white: 0.1))
            .clipShape(Capsule())
        }
    }
}
