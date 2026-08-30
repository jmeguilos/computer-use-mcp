import Foundation

/// One fail-closed rendering boundary for strings that originated outside the
/// host. It emits a bounded, single-line, visibly escaped representation so
/// controls, bidi overrides, separators, quotes, and backslashes cannot alter
/// the structure or apparent attribution of a native approval prompt.
public enum NativeUISanitizer {
    public static func escaped(
        _ value: String,
        maximumInputUTF16: Int,
        maximumOutputUTF16: Int
    ) -> String {
        let inputLimit = max(0, maximumInputUTF16)
        let outputLimit = max(0, maximumOutputUTF16)
        guard inputLimit > 0, outputLimit > 0 else { return "" }

        var output = ""
        output.reserveCapacity(min(outputLimit, value.utf16.count))
        var consumedInput = 0
        var truncated = false

        for scalar in value.unicodeScalars {
            let inputWidth = String(scalar).utf16.count
            guard consumedInput + inputWidth <= inputLimit else {
                truncated = true
                break
            }
            consumedInput += inputWidth
            let rendered = render(scalar)
            guard output.utf16.count + rendered.utf16.count <= outputLimit else {
                truncated = true
                break
            }
            output += rendered
        }
        if consumedInput < value.utf16.count { truncated = true }
        if truncated, output.utf16.count + 1 <= outputLimit { output += "…" }
        return output
    }

    public static func escaped(
        _ value: String,
        maximumUTF16: Int
    ) -> String {
        let inputLimit = max(0, maximumUTF16)
        let multiplied = inputLimit.multipliedReportingOverflow(by: 6)
        let expandedLimit = multiplied.overflow ? 4_096 : multiplied.partialValue
        return escaped(
            value,
            maximumInputUTF16: inputLimit,
            maximumOutputUTF16: min(4_096, max(inputLimit, expandedLimit))
        )
    }

    /// Bounds a string composed exclusively from already-escaped fragments and
    /// host-owned punctuation. Callers must not pass raw external text here.
    public static func boundedLiteral(_ value: String, maximumUTF16: Int) -> String {
        let limit = max(0, maximumUTF16)
        guard limit > 0, value.utf16.count > limit else { return limit == 0 ? "" : value }
        var output = ""
        for scalar in value.unicodeScalars {
            let rendered = String(scalar)
            guard output.utf16.count + rendered.utf16.count + 1 <= limit else { break }
            output += rendered
        }
        output += "…"
        return output
    }

    private static func render(_ scalar: Unicode.Scalar) -> String {
        switch scalar.value {
        case 0x22: return "\\\""
        case 0x27: return "\\'"
        case 0x5C: return "\\\\"
        case 0x0A: return "\\n"
        case 0x0D: return "\\r"
        case 0x09: return "\\t"
        case 0x2018...0x201F, 0x00AB, 0x00BB, 0x2039, 0x203A:
            return unicodeEscape(scalar)
        default:
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return unicodeEscape(scalar)
            default:
                return String(scalar)
            }
        }
    }

    private static func unicodeEscape(_ scalar: Unicode.Scalar) -> String {
        "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
    }
}
