import Foundation

struct Message: Identifiable, Decodable {
    var id = UUID()
    let role: String
    let text: String
    let tools: [String]

    enum CodingKeys: String, CodingKey {
        case role, text, tools
    }
}

struct ConversationResponse: Decodable {
    let messages: [Message]
}

struct InfoResponse: Decodable {
    let project: String
    let session: String
    let hasSession: Bool

    enum CodingKeys: String, CodingKey {
        case project, session
        case hasSession = "has_session"
    }
}

struct InputPayload: Encodable {
    let text: String
    let enter: Bool
    let keys: [String]
}
