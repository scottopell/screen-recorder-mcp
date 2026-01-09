import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

// MARK: - Output Writer

actor OutputWriter {
    private let assetWriter: AVAssetWriter
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var isStarted = false
    private var sessionStartTime: CMTime?
    private var lastVideoTime: CMTime = .zero

    private let session: RecordingSession
    private let config: RecordingConfig

    init(session: RecordingSession, config: RecordingConfig) throws {
        self.session = session
        self.config = config

        // Create asset writer
        self.assetWriter = try AVAssetWriter(outputURL: session.outputPath, fileType: config.format.fileType)

        // Video input will be configured on first frame (to get actual dimensions)
    }

    // MARK: - Video Handling

    func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Setup video input on first frame
        if videoInput == nil {
            setupVideoInput(from: sampleBuffer)
        }

        guard let videoInput = videoInput,
              let pixelBufferAdaptor = pixelBufferAdaptor else { return }

        // Start writing session
        if !isStarted {
            assetWriter.startWriting()
            assetWriter.startSession(atSourceTime: presentationTime)
            sessionStartTime = presentationTime
            isStarted = true
        }

        // Get pixel buffer from sample buffer
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Append if input is ready
        if videoInput.isReadyForMoreMediaData {
            let success = pixelBufferAdaptor.append(imageBuffer, withPresentationTime: presentationTime)
            if success {
                lastVideoTime = presentationTime
            }
        }
    }

    private func setupVideoInput(from sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        // Calculate bitrate based on quality and resolution
        let baseBitrate = Double(width * height) * 0.1  // ~0.1 bits per pixel base
        let bitrate = baseBitrate * config.quality.bitrateFactor

        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitrate),
            AVVideoExpectedSourceFrameRateKey: config.fps
        ]

        // Add codec-specific settings
        switch config.codec {
        case .h264:
            compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .h265:
            compressionProperties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel
        case .prores:
            break  // ProRes doesn't need profile settings
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: config.codec.avCodecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        // Transform for proper orientation
        input.transform = .identity

        // Create pixel buffer adaptor
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        if assetWriter.canAdd(input) {
            assetWriter.add(input)
            self.videoInput = input
            self.pixelBufferAdaptor = adaptor
        }
    }

    // MARK: - Audio Handling

    func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              isStarted,
              let audioInput = audioInput,
              audioInput.isReadyForMoreMediaData else { return }

        audioInput.append(sampleBuffer)
    }

    func setupAudioInput() {
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true

        if assetWriter.canAdd(input) {
            assetWriter.add(input)
            self.audioInput = input
        }
    }

    // MARK: - Finalization

    func finalize() async {
        guard isStarted else { return }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await withCheckedContinuation { continuation in
            assetWriter.finishWriting {
                continuation.resume()
            }
        }
    }

    func cancel() async {
        guard isStarted else { return }

        assetWriter.cancelWriting()
    }

    // MARK: - Metadata

    var outputMetadata: RecordingMetadata? {
        guard let videoInput = videoInput else { return nil }

        let duration = CMTimeGetSeconds(lastVideoTime) - CMTimeGetSeconds(sessionStartTime ?? .zero)

        return RecordingMetadata(
            width: 0,  // Would need to store this
            height: 0,
            duration: duration,
            fps: Double(config.fps),
            codec: config.codec.rawValue,
            hasAudio: audioInput != nil
        )
    }
}

// MARK: - Recording Metadata

struct RecordingMetadata: Sendable {
    let width: Int
    let height: Int
    let duration: TimeInterval
    let fps: Double
    let codec: String
    let hasAudio: Bool

    func toJSON() -> JSONValue {
        .object([
            "width": .int(width),
            "height": .int(height),
            "duration": .double(duration),
            "fps": .double(fps),
            "codec": .string(codec),
            "has_audio": .bool(hasAudio)
        ])
    }
}
