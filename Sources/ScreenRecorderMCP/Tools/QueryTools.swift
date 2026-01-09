import Foundation
import AVFoundation

// MARK: - List Recordings Tool

struct ListRecordingsTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "list_recordings",
        description: "List completed recordings in the output directory",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "directory": .object([
                    "type": "string",
                    "description": "Directory to search (default: ~/Movies/ScreenRecordings/)"
                ]),
                "limit": .object([
                    "type": "integer",
                    "default": 20,
                    "description": "Maximum number of recordings to return"
                ]),
                "sort_by": .object([
                    "type": "string",
                    "enum": .array(["date", "size", "duration"]),
                    "default": "date",
                    "description": "Sort order"
                ])
            ]),
            "required": .array([])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        let directoryPath = arguments["directory"]?.stringValue
            .map { ($0 as NSString).expandingTildeInPath }
            ?? RecordingConfig.defaultOutputDirectory.path

        let limit = arguments["limit"]?.intValue ?? 20
        let sortBy = arguments["sort_by"]?.stringValue ?? "date"

        let directoryURL = URL(fileURLWithPath: directoryPath)

        // Check if directory exists
        guard FileManager.default.fileExists(atPath: directoryPath) else {
            return .json(.object([
                "recordings": .array([]),
                "count": .int(0),
                "message": .string("Directory does not exist: \(directoryPath)")
            ]))
        }

        // Get video files
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return .error("Failed to enumerate directory: \(directoryPath)")
        }

        var recordings: [(url: URL, size: Int64, date: Date, duration: Double)] = []

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ["mov", "mp4", "m4v"].contains(ext) else { continue }

            // Get file attributes
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]),
                  let fileSize = resourceValues.fileSize,
                  let creationDate = resourceValues.creationDate else { continue }

            // Get video duration
            let asset = AVAsset(url: fileURL)
            let duration = CMTimeGetSeconds(asset.duration)

            recordings.append((
                url: fileURL,
                size: Int64(fileSize),
                date: creationDate,
                duration: duration.isNaN ? 0 : duration
            ))
        }

        // Sort
        switch sortBy {
        case "size":
            recordings.sort { $0.size > $1.size }
        case "duration":
            recordings.sort { $0.duration > $1.duration }
        default:  // "date"
            recordings.sort { $0.date > $1.date }
        }

        // Limit results
        let limitedRecordings = Array(recordings.prefix(limit))

        // Format results
        let results: [JSONValue] = limitedRecordings.map { recording in
            .object([
                "path": .string(recording.url.path),
                "filename": .string(recording.url.lastPathComponent),
                "file_size": .int(Int(recording.size)),
                "created_at": .string(ISO8601DateFormatter().string(from: recording.date)),
                "duration": .double(recording.duration)
            ])
        }

        return .json(.object([
            "recordings": .array(results),
            "count": .int(results.count),
            "directory": .string(directoryPath)
        ]))
    }
}

// MARK: - Get Recording Info Tool

struct GetRecordingInfoTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "get_recording_info",
        description: "Get detailed metadata about a recording",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "recording_path": .object([
                    "type": "string",
                    "description": "Path to the recording file"
                ])
            ]),
            "required": .array(["recording_path"])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        guard let pathString = arguments["recording_path"]?.stringValue else {
            return .error("Missing required parameter: recording_path")
        }

        let path = (pathString as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)

        // Check file exists
        guard FileManager.default.fileExists(atPath: path) else {
            return .error("File not found: \(path)")
        }

        // Get file attributes
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .error("Failed to get file attributes: \(path)")
        }

        let fileSize = attrs[.size] as? Int64 ?? 0
        let creationDate = attrs[.creationDate] as? Date ?? Date()

        // Get video metadata
        let asset = AVAsset(url: url)

        // Get duration
        let duration = CMTimeGetSeconds(asset.duration)

        // Get video track info
        var width = 0
        var height = 0
        var fps: Double = 0
        var codec = "unknown"

        let videoTracks = asset.tracks(withMediaType: .video)
        if let videoTrack = videoTracks.first {
            let size = videoTrack.naturalSize
            width = Int(size.width)
            height = Int(size.height)
            fps = Double(videoTrack.nominalFrameRate)

            // Get codec from format descriptions
            if let formatDescriptions = videoTrack.formatDescriptions as? [CMFormatDescription],
               let formatDesc = formatDescriptions.first {
                let codecType = CMFormatDescriptionGetMediaSubType(formatDesc)
                codec = codecType.fourCharCodeString
            }
        }

        // Check for audio
        let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty
        let audioTrackCount = asset.tracks(withMediaType: .audio).count

        // Calculate bitrate
        let bitrate = duration > 0 ? Double(fileSize * 8) / duration : 0

        return .json(.object([
            "path": .string(path),
            "filename": .string(url.lastPathComponent),
            "duration": .double(duration.isNaN ? 0 : duration),
            "width": .int(width),
            "height": .int(height),
            "fps": .double(fps.isNaN ? 0 : fps),
            "codec": .string(codec),
            "bitrate": .int(Int(bitrate)),
            "file_size": .int(Int(fileSize)),
            "created_at": .string(ISO8601DateFormatter().string(from: creationDate)),
            "has_audio": .bool(hasAudio),
            "audio_tracks": .int(audioTrackCount)
        ]))
    }
}

// MARK: - Helper Extension

extension FourCharCode {
    var fourCharCodeString: String {
        let bytes = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
