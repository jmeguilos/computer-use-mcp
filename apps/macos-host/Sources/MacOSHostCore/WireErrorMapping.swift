import Foundation

public enum WireErrorMapping {
    public static func map(_ error: Error) -> WireError {
        if let wire = error as? WireError { return normalize(wire) }
        if error is CancellationError { return WireError(code: "CANCELLED", message: "The operation was cancelled", retryable: true) }
        if let value = error as? CaptureError {
            switch value {
            case .permissionDenied: return WireError(code: "PERMISSION_REQUIRED", message: "Screen Recording permission is required")
            case .windowNotFound, .targetIdentityChanged:
                return WireError(code: "WINDOW_CLOSED", message: "The granted window is unavailable or was recreated")
            case .displayNotFound: return WireError(code: "WINDOW_NOT_GRANTED", message: "The granted display is unavailable")
            case .protectedTarget: return WireError(code: "ACCESS_DENIED", message: "The target is protected")
            case .captureTimedOut: return WireError(code: "ACTION_TIMEOUT", message: "Screen capture timed out", retryable: true)
            default: return WireError(code: "SCREEN_CAPTURE_FAILED", message: "Screen capture failed", retryable: true)
            }
        }
        if let value = error as? AccessibilityError {
            switch value {
            case .permissionDenied: return WireError(code: "PERMISSION_REQUIRED", message: "Accessibility permission is required")
            case .focusMismatch: return WireError(code: "FOCUS_FAILED", message: "The exact granted window could not be focused")
            case .windowNotFound, .windowMappingAmbiguous: return WireError(code: "WINDOW_CLOSED", message: "The exact granted window could not be resolved")
            case .staleRevision, .sessionNotFound: return WireError(code: "STALE_FRAME", message: "Refresh target state before retrying", retryable: true)
            case .elementNotFound, .textNotFound, .textAmbiguous: return WireError(code: "ELEMENT_NOT_FOUND", message: "The current-frame element was not found", retryable: true)
            case .secureElement: return WireError(code: "ACCESS_DENIED", message: "Secure text elements cannot be read or selected")
            default: return WireError(code: "ELEMENT_NOT_ACTIONABLE", message: "The element does not support that action")
            }
        }
        if let value = error as? InputDriverError {
            switch value {
            case .permissionDenied: return WireError(code: "PERMISSION_REQUIRED", message: "Input posting permission is required")
            case .canceled: return WireError(code: "CANCELLED", message: "The operation was cancelled", retryable: true)
            case .deadlineExceeded:
                return WireError(code: "ACTION_TIMEOUT", message: "The action deadline elapsed")
            case .privateDriverDisabled, .unsupportedOSVersion, .implementationUnavailable:
                return WireError(code: "UNSUPPORTED", message: "The requested input driver is unavailable")
            default: return WireError(code: "ELEMENT_NOT_ACTIONABLE", message: "Synthetic input could not be posted")
            }
        }
        if let value = error as? InteractionSafetyError {
            switch value {
            case .focusCaptureFailed, .focusActivationFailed, .focusRestoreFailed:
                return WireError(code: "FOCUS_FAILED", message: "Safe foreground focus could not be established and restored")
            default: return WireError(code: "ACCESS_DENIED", message: "The clipboard changed before it could be restored")
            }
        }
        if let value = error as? SyntheticDestinationGuardError {
            switch value {
            case .selfControlBlocked: return WireError(code: "ACCESS_DENIED", message: "Controlling the requesting harness is blocked")
            case .protectedSurface: return WireError(code: "ACCESS_DENIED", message: "A protected surface would receive the input")
            case .exactWindowRequired: return WireError(code: "FOCUS_FAILED", message: "This action requires an exact window target")
            case .identityChanged: return WireError(code: "WINDOW_CLOSED", message: "The granted window process changed")
            case .pointOutsideTarget:
                return WireError(code: "ELEMENT_NOT_ACTIONABLE", message: "The action point is outside the granted window")
            case .exactWindowUnavailable, .unrelatedOccluder:
                return WireError(code: "FOCUS_FAILED", message: "The exact granted window is hidden or occluded", retryable: true)
            }
        }
        if let value = error as? FrameResourceError {
            switch value {
            case .staleFrame, .frameNotFound: return WireError(code: "STALE_FRAME", message: "Refresh target state before retrying", retryable: true)
            case .intentRequired: return WireError(code: "ACCESS_DENIED", message: "A concise action intent is required")
            default: return WireError(code: "ACCESS_DENIED", message: "Frame authority does not match this grant")
            }
        }
        if let value = error as? ScreenshotTransformError {
            switch value {
            case .pointOutsideOutput, .pointOutsideSource:
                return WireError(code: "ELEMENT_NOT_ACTIONABLE", message: "The action coordinate is outside the current frame")
            case .invalidDimensions:
                return WireError(code: "SCREEN_CAPTURE_FAILED", message: "The screenshot coordinate transform is invalid")
            }
        }
        if let value = error as? GrantStoreError {
            switch value {
            case .grantNotFound, .grantConnectionMismatch, .grantExpired:
                return WireError(code: "WINDOW_NOT_GRANTED", message: "The target grant is unavailable")
            case .targetLocked: return WireError(code: "BUSY", message: "The target is controlled by another connection", retryable: true)
            default: return WireError(code: "ACCESS_DENIED", message: "The grant does not authorize this operation")
            }
        }
        if let value = error as? ConnectionValidationError {
            switch value {
            case .incompatibleProtocol: return WireError(code: "PROTOCOL_MISMATCH", message: "Native protocol versions are incompatible")
            case .unsupportedCapability, .capabilityDenied: return WireError(code: "ACCESS_DENIED", message: "The connection lacks a negotiated capability")
            default: return WireError(code: "AUTH_FAILED", message: "Native connection authentication failed")
            }
        }
        if error is DecodingError || error is WireCodecError {
            return WireError(code: "BRIDGE_PROTOCOL_ERROR", message: "The native request did not match the protocol")
        }
        return WireError(code: "INTERNAL_ERROR", message: "The native operation failed unexpectedly")
    }

    private static func normalize(_ error: WireError) -> WireError {
        if error.code == "approval_required" { return error }
        let code: String
        switch error.code.uppercased() {
        case "PERMISSION_REQUIRED", "APP_CONTROL_DISABLED", "ACCESS_DENIED", "APP_NOT_RUNNING", "WINDOW_NOT_GRANTED",
             "WINDOW_CLOSED", "STALE_FRAME", "ELEMENT_NOT_FOUND", "ELEMENT_NOT_ACTIONABLE",
             "FOCUS_FAILED", "SCREEN_CAPTURE_FAILED", "ACTION_TIMEOUT", "CANCELLED",
             "APPROVAL_EXPIRED", "APPROVAL_USED", "APPROVAL_MISMATCH", "BUSY", "UNSUPPORTED",
             "BRIDGE_UNAVAILABLE", "BRIDGE_PROTOCOL_ERROR", "INTERNAL_ERROR", "AUTH_FAILED",
             "PROTOCOL_MISMATCH":
            code = error.code.uppercased()
        case "DEADLINE_EXCEEDED", "INVALID_DEADLINE": code = "ACTION_TIMEOUT"
        case "APPROVAL_INVALID": code = "APPROVAL_MISMATCH"
        case "APPROVAL_NOT_FOUND": code = "APPROVAL_EXPIRED"
        case "ACTION_BLOCKED", "CONNECTION_REVOKED": code = "ACCESS_DENIED"
        case "WINDOW_NOT_FOUND": code = "WINDOW_CLOSED"
        case "DISPLAY_NOT_FOUND": code = "WINDOW_NOT_GRANTED"
        case "INVALID_ACTION": code = "ELEMENT_NOT_ACTIONABLE"
        case "METHOD_NOT_FOUND": code = "UNSUPPORTED"
        default: code = "BRIDGE_PROTOCOL_ERROR"
        }
        return WireError(code: code, message: error.message, retryable: error.retryable, details: error.details)
    }
}
