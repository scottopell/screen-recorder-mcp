import Foundation

// MARK: - MCP Server

actor MCPServer {
    private let tools: [String: MCPTool]
    private var initialized = false

    private let serverInfo = MCPServerInfo(
        name: "screen-recorder-mcp",
        version: "0.1.0"
    )

    private let protocolVersion = "2024-11-05"

    init(tools: [MCPTool]) {
        var toolDict: [String: MCPTool] = [:]
        for tool in tools {
            toolDict[tool.definition.name] = tool
        }
        self.tools = toolDict
    }

    func handleRequest(_ request: JSONRPCRequest) async -> JSONRPCResponse? {
        switch request.method {
        case "initialize":
            return await handleInitialize(request)

        case "initialized":
            // This is a notification, no response needed
            return nil

        case "tools/list":
            return handleToolsList(request)

        case "tools/call":
            return await handleToolCall(request)

        case "ping":
            return JSONRPCResponse(id: request.id, result: .object([:]))

        default:
            return JSONRPCResponse(
                id: request.id,
                error: JSONRPCError.methodNotFound
            )
        }
    }

    private func handleInitialize(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        initialized = true

        let result = InitializeResult(
            protocolVersion: protocolVersion,
            capabilities: .default,
            serverInfo: serverInfo
        )

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(result),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return JSONRPCResponse(id: request.id, error: .internalError)
        }

        return JSONRPCResponse(id: request.id, result: json)
    }

    private func handleToolsList(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let toolDefinitions = tools.values.map { $0.definition }
        let result = ToolsListResult(tools: Array(toolDefinitions))

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(result),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return JSONRPCResponse(id: request.id, error: .internalError)
        }

        return JSONRPCResponse(id: request.id, result: json)
    }

    private func handleToolCall(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard let params = request.params?.objectValue,
              let name = params["name"]?.stringValue else {
            return JSONRPCResponse(
                id: request.id,
                error: JSONRPCError(code: -32602, message: "Missing tool name")
            )
        }

        guard let tool = tools[name] else {
            return JSONRPCResponse(
                id: request.id,
                error: JSONRPCError(code: -32602, message: "Unknown tool: \(name)")
            )
        }

        let arguments = params["arguments"] ?? .object([:])

        do {
            let result = try await tool.execute(arguments: arguments)

            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(result),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return JSONRPCResponse(id: request.id, error: .internalError)
            }

            return JSONRPCResponse(id: request.id, result: json)
        } catch {
            let errorResult = MCPToolResult.error("Tool execution failed: \(error.localizedDescription)")

            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(errorResult),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return JSONRPCResponse(id: request.id, error: .internalError)
            }

            return JSONRPCResponse(id: request.id, result: json)
        }
    }
}

// MARK: - MCP Tool Protocol

protocol MCPTool: Sendable {
    var definition: MCPToolDefinition { get }
    func execute(arguments: JSONValue) async throws -> MCPToolResult
}

// MARK: - Stdio Transport

@MainActor
class MCPStdioTransport {
    private let server: MCPServer
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(server: MCPServer) {
        self.server = server
        encoder.outputFormatting = []  // Compact JSON for transport
    }

    func run() async {
        // Read from stdin line by line
        while let line = readLine() {
            guard !line.isEmpty else { continue }

            await processMessage(line)
        }
    }

    private func processMessage(_ message: String) async {
        guard let data = message.data(using: .utf8) else {
            log("Failed to convert message to data")
            return
        }

        do {
            let request = try decoder.decode(JSONRPCRequest.self, from: data)

            if let response = await server.handleRequest(request) {
                sendResponse(response)
            }
        } catch {
            log("Failed to parse request: \(error)")
            let errorResponse = JSONRPCResponse(
                id: nil,
                error: .parseError
            )
            sendResponse(errorResponse)
        }
    }

    private func sendResponse(_ response: JSONRPCResponse) {
        do {
            let data = try encoder.encode(response)
            if let string = String(data: data, encoding: .utf8) {
                print(string)
                fflush(stdout)
            }
        } catch {
            log("Failed to encode response: \(error)")
        }
    }

    private func log(_ message: String) {
        // Log to stderr so it doesn't interfere with MCP communication
        FileHandle.standardError.write(Data("[screen-recorder-mcp] \(message)\n".utf8))
    }
}
