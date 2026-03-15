import Foundation

@MainActor
final class PhoneClient: ObservableObject {
    @Published var messages: [Message] = []
    @Published var hasSession: Bool = false
    @Published var project: String = ""
    @Published var isConnected: Bool = false
    @Published var sendError: String? = nil

    private var pollTask: Task<Void, Never>?

    var baseURL: String {
        UserDefaults.standard.string(forKey: "phoneServerURL") ?? "https://ztester123.fly.dev"
    }

    init() {
        startPolling()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_200_000_000)
            }
        }
    }

    func refresh() async {
        await fetchInfo()
        await fetchConversation()
    }

    private func fetchInfo() async {
        guard let url = URL(string: "\(baseURL)/api/info") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let info = try JSONDecoder().decode(InfoResponse.self, from: data)
            self.hasSession = info.hasSession
            self.project = info.project
            self.isConnected = true
        } catch {
            self.isConnected = false
        }
    }

    private func fetchConversation() async {
        guard let url = URL(string: "\(baseURL)/api/conversation") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ConversationResponse.self, from: data)
            self.messages = response.messages
        } catch {
            // Silently fail — info connectivity error is surfaced separately
        }
    }

    func send(text: String, enter: Bool = true, keys: [String] = []) async throws {
        guard let url = URL(string: "\(baseURL)/api/input") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(InputPayload(text: text, enter: enter, keys: keys))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Error \(http.statusCode)"
            throw NSError(domain: "WarpholPhone", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        // Immediate refresh so the sent message appears quickly
        await fetchConversation()
    }

    func sendKey(_ key: String) async {
        do {
            try await send(text: "", enter: false, keys: [key])
        } catch {
            sendError = error.localizedDescription
        }
    }
}
