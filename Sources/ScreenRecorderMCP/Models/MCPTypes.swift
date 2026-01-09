import Foundation

// MARK: - MCP Protocol Types

struct MCPToolDefinition: Codable {
    let name: String
    let description: String
    let inputSchema: JSONValue

    init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

struct MCPToolResult: Codable {
    let content: [MCPContent]
    let isError: Bool?

    init(content: [MCPContent], isError: Bool? = nil) {
        self.content = content
        self.isError = isError
    }

    static func text(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [.text(text)])
    }

    static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(content: [.text(message)], isError: true)
    }

    static func json(_ value: JSONValue) -> MCPToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value),
           let string = String(data: data, encoding: .utf8) {
            return MCPToolResult(content: [.text(string)])
        }
        return MCPToolResult(content: [.text("Error encoding JSON")])
    }
}

enum MCPContent: Codable {
    case text(String)
    case image(data: String, mimeType: String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case data
        case mimeType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image":
            let data = try container.decode(String.self, forKey: .data)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            self = .image(data: data, mimeType: mimeType)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown content type: \(type)")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        }
    }
}

// MARK: - Server Info

struct MCPServerInfo: Codable {
    let name: String
    let version: String
}

struct MCPCapabilities: Codable {
    let tools: ToolsCapability?

    struct ToolsCapability: Codable {
        // Empty for now, but allows for future expansion
    }

    static let `default` = MCPCapabilities(tools: ToolsCapability())
}

// MARK: - Initialize Request/Response

struct InitializeParams: Codable {
    let protocolVersion: String
    let capabilities: ClientCapabilities
    let clientInfo: ClientInfo

    struct ClientCapabilities: Codable {
        // Client capabilities - we don't need to inspect these for now
    }

    struct ClientInfo: Codable {
        let name: String
        let version: String?
    }
}

struct InitializeResult: Codable {
    let protocolVersion: String
    let capabilities: MCPCapabilities
    let serverInfo: MCPServerInfo
}

// MARK: - Tool List Request/Response

struct ToolsListResult: Codable {
    let tools: [MCPToolDefinition]
}

// MARK: - Tool Call Request/Response

struct ToolCallParams: Codable {
    let name: String
    let arguments: JSONValue?
}
