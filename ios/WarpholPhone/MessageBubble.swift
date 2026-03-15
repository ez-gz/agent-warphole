import SwiftUI

struct MessageBubble: View {
    let message: Message

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isUser ? Color(red: 0.2, green: 0.45, blue: 0.95) : Color(white: 0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(
                        maxWidth: UIScreen.main.bounds.width * 0.78,
                        alignment: isUser ? .trailing : .leading
                    )
                    .textSelection(.enabled)
            }

            if !message.tools.isEmpty {
                ToolCallChips(tools: message.tools)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.vertical, 2)
    }
}

struct ToolCallChips: View {
    let tools: [String]
    private let maxVisible = 3

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.38))

            ForEach(Array(tools.prefix(maxVisible).enumerated()), id: \.offset) { _, tool in
                Text(shortName(tool))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(white: 0.38))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(white: 0.1))
                    .clipShape(Capsule())
            }

            if tools.count > maxVisible {
                Text("+\(tools.count - maxVisible)")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.3))
            }
        }
        .padding(.leading, 4)
    }

    private func shortName(_ name: String) -> String {
        // Strip common prefixes like "mcp__" or long namespaces
        let parts = name.split(separator: "_").map(String.init)
        return parts.last ?? name
    }
}
