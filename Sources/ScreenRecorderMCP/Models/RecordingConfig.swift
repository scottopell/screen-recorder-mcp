import Foundation
import AVFoundation

// MARK: - Recording Mode

enum RecordingMode: String, Codable, Sendable {
    case screen
    case window
    case app
    case region
}

// MARK: - Video Codec

enum VideoCodec: String, Codable, Sendable {
    case h264
    case h265
    case prores

    var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .h265: return .hevc
        case .prores: return .proRes422
        }
    }
}

// MARK: - Output Format

enum OutputFormat: String, Codable, Sendable {
    case mov
    case mp4

    var fileType: AVFileType {
        switch self {
        case .mov: return .mov
        case .mp4: return .mp4
        }
    }

    var fileExtension: String {
        rawValue
    }
}

// MARK: - Quality Preset

enum QualityPreset: String, Codable, Sendable {
    case low
    case medium
    case high
    case lossless

    var bitrateFactor: Double {
        switch self {
        case .low: return 0.3
        case .medium: return 0.6
        case .high: return 1.0
        case .lossless: return 2.0
        }
    }
}

// MARK: - Audio Configuration

struct AudioConfig: Sendable {
    let captureSystemAudio: Bool
    let captureMicrophone: Bool
    let appAudioOnly: Bool

    init(captureSystemAudio: Bool = false, captureMicrophone: Bool = false, appAudioOnly: Bool = false) {
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophone = captureMicrophone
        self.appAudioOnly = appAudioOnly
    }

    static let none = AudioConfig()
}

// MARK: - Region Configuration

struct RegionConfig: Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - Recording Configuration

struct RecordingConfig: Sendable {
    let mode: RecordingMode
    let displayID: UInt32?
    let windowID: UInt32?
    let appBundleID: String?
    let region: RegionConfig?

    let outputDirectory: URL
    let filename: String?
    let format: OutputFormat
    let codec: VideoCodec
    let quality: QualityPreset
    let fps: Int

    let captureCursor: Bool
    let captureClicks: Bool
    let audio: AudioConfig

    let maxDuration: TimeInterval?
    let sessionName: String?

    init(
        mode: RecordingMode,
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        appBundleID: String? = nil,
        region: RegionConfig? = nil,
        outputDirectory: URL? = nil,
        filename: String? = nil,
        format: OutputFormat = .mov,
        codec: VideoCodec = .h264,
        quality: QualityPreset = .high,
        fps: Int = 30,
        captureCursor: Bool = true,
        captureClicks: Bool = false,
        audio: AudioConfig = .none,
        maxDuration: TimeInterval? = nil,
        sessionName: String? = nil
    ) {
        self.mode = mode
        self.displayID = displayID
        self.windowID = windowID
        self.appBundleID = appBundleID
        self.region = region
        self.outputDirectory = outputDirectory ?? RecordingConfig.defaultOutputDirectory
        self.filename = filename
        self.format = format
        self.codec = codec
        self.quality = quality
        self.fps = max(1, min(120, fps))
        self.captureCursor = captureCursor
        self.captureClicks = captureClicks
        self.audio = audio
        self.maxDuration = maxDuration
        self.sessionName = sessionName
    }

    static var defaultOutputDirectory: URL {
        // Use .screen-recordings in current working directory (like Playwright)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return cwd.appendingPathComponent(".screen-recordings", isDirectory: true)
    }

    static var defaultFramesDirectory: URL {
        return defaultOutputDirectory.appendingPathComponent("frames", isDirectory: true)
    }

    func generateOutputPath() -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")

        let baseName = filename ?? "recording_\(timestamp)"
        let fullFilename = baseName.hasSuffix(".\(format.fileExtension)")
            ? baseName
            : "\(baseName).\(format.fileExtension)"

        return outputDirectory.appendingPathComponent(fullFilename)
    }
}
