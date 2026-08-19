import CoreFoundation
import Foundation

public struct GatewayTokenUsage: Equatable, Sendable {
    public var routeID: UUID
    public var endpointID: UUID
    public var tokens: Int64

    public init(routeID: UUID, endpointID: UUID, tokens: Int64) {
        self.routeID = routeID
        self.endpointID = endpointID
        self.tokens = tokens
    }
}

struct GatewayTokenUsageParser {
    static let maximumBufferedJSONBytes = 4 * 1_024 * 1_024

    static func tokens(inJSON data: Data) -> Int64? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let usage = root["usage"] as? [String: Any] {
            return tokens(inUsage: usage)
        }
        if let response = root["response"] as? [String: Any],
           let usage = response["usage"] as? [String: Any] {
            return tokens(inUsage: usage)
        }
        return nil
    }

    static func tokens(inSSEEvent data: Data) -> Int64? {
        let payload = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Substring? in
                guard line.hasPrefix("data:") else { return nil }
                return line.dropFirst("data:".count).drop(while: { $0 == " " })
            }
            .joined(separator: "\n")
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        return tokens(inJSON: Data(payload.utf8))
    }

    private static func tokens(inUsage usage: [String: Any]) -> Int64? {
        if let total = integer(usage["total_tokens"]), total > 0 { return total }
        let prompt = integer(usage["prompt_tokens"]) ?? integer(usage["input_tokens"]) ?? 0
        let completion = integer(usage["completion_tokens"]) ?? integer(usage["output_tokens"]) ?? 0
        let (total, overflow) = prompt.addingReportingOverflow(completion)
        guard !overflow, total > 0 else { return nil }
        return total
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double.rounded(.towardZero) == double,
              double <= Double(Int64.max) else { return nil }
        return Int64(double)
    }
}
