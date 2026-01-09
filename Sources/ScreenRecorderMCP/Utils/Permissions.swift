import Foundation
import ScreenCaptureKit
import AVFoundation

// MARK: - Permission Status

enum PermissionStatus: String, Codable {
    case granted
    case denied
    case notDetermined
    case restricted
}

struct PermissionState: Sendable {
    let screenRecording: PermissionStatus
    let microphone: PermissionStatus
}

// MARK: - Permission Checker

actor PermissionChecker {
    static let shared = PermissionChecker()

    private init() {}

    func checkAllPermissions() async -> PermissionState {
        async let screenPerm = checkScreenRecordingPermission()
        async let micPerm = checkMicrophonePermission()

        return await PermissionState(
            screenRecording: screenPerm,
            microphone: micPerm
        )
    }

    func checkScreenRecordingPermission() async -> PermissionStatus {
        // ScreenCaptureKit will throw if permission not granted
        // We can check by attempting to get shareable content
        do {
            _ = try await SCShareableContent.current
            return .granted
        } catch {
            // If we get an error, it's likely permission denied
            // Unfortunately ScreenCaptureKit doesn't give us a way to distinguish
            // "not determined" from "denied" without trying
            return .denied
        }
    }

    func checkMicrophonePermission() async -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        @unknown default:
            return .notDetermined
        }
    }

    func requestScreenRecordingPermission() async -> Bool {
        // Trigger the permission prompt by trying to access content
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            return false
        }
    }

    func requestMicrophonePermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated func getPermissionInstructions() -> String {
        """
        To grant screen recording permission:
        1. Open System Preferences/Settings
        2. Go to Privacy & Security > Screen Recording
        3. Enable the toggle for this application
        4. You may need to restart the application

        To grant microphone permission:
        1. Open System Preferences/Settings
        2. Go to Privacy & Security > Microphone
        3. Enable the toggle for this application
        """
    }
}
