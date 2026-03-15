import SwiftUI

struct SettingsView: View {
    @ObservedObject var client: PhoneClient
    @Environment(\.dismiss) private var dismiss

    @State private var url: String = UserDefaults.standard.string(forKey: "phoneServerURL") ?? "https://ztester123.fly.dev"

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 9, height: 9)
                            .shadow(color: statusColor.opacity(0.8), radius: 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusLabel)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(statusColor)
                            if !client.project.isEmpty {
                                Text(client.project)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Status")
                }

                Section {
                    TextField("https://yourapp.fly.dev", text: $url)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("Server URL")
                } footer: {
                    Text("The Fly.io (or local) URL where the warphole phone server is running.")
                }

                Section {
                    Button("Save & Reconnect") {
                        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        UserDefaults.standard.set(clean.isEmpty ? nil : clean, forKey: "phoneServerURL")
                        client.startPolling()
                        dismiss()
                    }
                    .foregroundColor(.blue)
                }
            }
            .navigationTitle("Warphole")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var statusLabel: String {
        if !client.isConnected { return "Offline" }
        return client.hasSession ? "Live session" : "Waiting for session"
    }

    private var statusColor: Color {
        if !client.isConnected { return .red }
        return client.hasSession ? Color(red: 0.25, green: 0.9, blue: 0.5) : .orange
    }
}
