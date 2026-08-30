import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
    public var intValue: Int? {
        guard case .number(let value) = self, value.isFinite, value.rounded() == value else { return nil }
        return Int(exactly: value)
    }
}

public struct WireRequest: Codable, Equatable, Sendable {
    public let protocolVersion: ProtocolVersion
    public let id: String
    public let method: String
    public let connectionID: UUID?
    public let connectionToken: String?
    public let auth: WireAuthentication?
    public let client: PeerIdentity?
    public let capabilities: Set<HostCapability>?
    public let nonce: String?
    public let deadlineUnixMs: Int64?
    public let params: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case id, method
        case connectionID = "connectionId"
        case connectionToken, auth, client, capabilities, nonce, deadlineUnixMs, params
    }

    public init(
        protocolVersion: ProtocolVersion = .current,
        id: String,
        method: String,
        connectionID: UUID? = nil,
        connectionToken: String? = nil,
        auth: WireAuthentication? = nil,
        client: PeerIdentity? = nil,
        capabilities: Set<HostCapability>? = nil,
        nonce: String? = nil,
        deadlineUnixMs: Int64? = nil,
        params: JSONValue? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.method = method
        self.connectionID = connectionID
        self.connectionToken = connectionToken
        self.auth = auth
        self.client = client
        self.capabilities = capabilities
        self.nonce = nonce
        self.deadlineUnixMs = deadlineUnixMs
        self.params = params
    }
}

public struct WireAuthentication: Codable, Equatable, Sendable {
    public let token: String
    public init(token: String) { self.token = token }
}

public struct WireError: Codable, Equatable, Error, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let details: JSONValue?

    public init(code: String, message: String, retryable: Bool = false, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}

public struct WireResponse: Codable, Equatable, Sendable {
    public let protocolVersion: ProtocolVersion
    public let id: String
    public let ok: Bool
    public let result: JSONValue?
    public let error: WireError?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case id, ok, result, error
    }

    public static func success(id: String, result: JSONValue = .object([:])) -> WireResponse {
        WireResponse(protocolVersion: .current, id: id, ok: true, result: result, error: nil)
    }

    public static func failure(id: String, error: WireError) -> WireResponse {
        WireResponse(protocolVersion: .current, id: id, ok: false, result: nil, error: error)
    }
}

public enum WireCodec {
    public static let maximumLineBytes = 8 * 1_024 * 1_024

    public static func decodeRequest(_ data: Data) throws -> WireRequest {
        guard !data.isEmpty, data.count <= maximumLineBytes else { throw WireCodecError.frameTooLarge }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WireCodecError.malformedFrame
        }
        let allowed = Set([
            "protocol", "id", "method", "connectionId", "connectionToken", "auth",
            "client", "capabilities", "nonce", "deadlineUnixMs", "params",
        ])
        guard Set(object.keys).isSubset(of: allowed) else { throw WireCodecError.unknownField }
        if let protocolObject = object["protocol"] as? [String: Any],
           !Set(protocolObject.keys).isSubset(of: ["major", "minor"]) {
            throw WireCodecError.unknownField
        }
        if let auth = object["auth"] as? [String: Any], !Set(auth.keys).isSubset(of: ["token"]) {
            throw WireCodecError.unknownField
        }
        if let client = object["client"] as? [String: Any],
           !Set(client.keys).isSubset(of: [
               "name", "pid", "uid", "instanceId", "harnessProcessID",
               "harnessBundleIdentifier", "harnessSigningIdentity",
               "harnessProcessStartTimeUnixMs", "harnessIdentityVerified",
           ]) {
            throw WireCodecError.unknownField
        }
        return try JSONDecoder().decode(WireRequest.self, from: data)
    }

    public static func encodeResponse(_ response: WireResponse) throws -> Data {
        let data = try JSONEncoder.wire.encode(response)
        guard data.count <= maximumLineBytes else { throw WireCodecError.frameTooLarge }
        return data + Data([0x0A])
    }

    public static func decodeResponse(_ data: Data) throws -> WireResponse {
        guard !data.isEmpty, data.count <= maximumLineBytes else { throw WireCodecError.frameTooLarge }
        return try JSONDecoder().decode(WireResponse.self, from: data)
    }

    public static func encodeRequest(_ request: WireRequest) throws -> Data {
        let data = try JSONEncoder.wire.encode(request)
        guard data.count <= maximumLineBytes else { throw WireCodecError.frameTooLarge }
        return data + Data([0x0A])
    }
}

public enum WireDeadlinePolicy {
    public static func maximumMilliseconds(for method: String) -> Int {
        method == "requestAccess" ? 300_000 : 30_000
    }

    public static func defaultMilliseconds(for method: String) -> Int {
        if method == "requestAccess" { return 120_000 }
        if method == "cancel" { return 5_000 }
        return 10_000
    }
}

public enum WireCodecError: String, Error, Equatable, Sendable {
    case frameTooLarge
    case malformedFrame
    case connectionClosed
    case unknownField
}

extension JSONEncoder {
    static var wire: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension Encodable {
    func jsonValue() throws -> JSONValue {
        let data = try JSONEncoder.wire.encode(self)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

public extension JSONValue {
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder.wire.encode(self)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
