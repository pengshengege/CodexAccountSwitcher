import CryptoKit
import Foundation

public enum CodexAuthInspector {
    public static func inspect(_ data: Data) throws -> CodexIdentity {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SwitcherError.invalidAuthFile("不是 JSON 对象")
        }

        let authMode = (root["auth_mode"] as? String) ?? inferredAuthMode(from: root)
        let tokens = root["tokens"] as? [String: Any]
        let apiKey = root["OPENAI_API_KEY"] as? String

        guard tokens != nil || (apiKey?.isEmpty == false) else {
            throw SwitcherError.invalidAuthFile("缺少 tokens 或 API Key")
        }

        var payloads: [[String: Any]] = []
        if let tokens {
            for key in ["id_token", "access_token"] {
                if let token = tokens[key] as? String,
                   let payload = decodeJWTPayload(token) {
                    payloads.append(payload)
                }
            }
        }

        let email = firstString(for: ["email"], in: payloads)
        let plan = firstString(
            for: ["chatgpt_plan_type", "plan_type", "planType"],
            in: payloads
        )
        let accountID = (tokens?["account_id"] as? String)
            ?? firstString(
                for: ["chatgpt_account_id", "account_id", "accountId"],
                in: payloads
            )
            ?? firstTopLevelString(for: "sub", in: payloads)
        let expiryTimestamp = firstNumber(for: "exp", in: payloads)
        let expiry = expiryTimestamp.map { Date(timeIntervalSince1970: $0) }

        return CodexIdentity(
            email: email,
            accountIdentifier: accountID,
            planType: plan,
            authMode: authMode,
            tokenExpiry: expiry,
            fingerprint: fingerprint(data)
        )
    }

    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func suggestedDisplayName(for identity: CodexIdentity) -> String {
        if let email = identity.email,
           let prefix = email.split(separator: "@").first,
           !prefix.isEmpty {
            return String(prefix)
        }
        if identity.authMode.lowercased().contains("api") {
            return "API Key 账号"
        }
        return "Codex 账号"
    }

    private static func inferredAuthMode(from root: [String: Any]) -> String {
        if let apiKey = root["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return "api_key"
        }
        return "chatgpt"
    }

    private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard
            let data = Data(base64Encoded: base64),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return payload
    }

    private static func firstTopLevelString(
        for key: String,
        in objects: [[String: Any]]
    ) -> String? {
        for object in objects {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func firstString(
        for keys: Set<String>,
        in objects: [[String: Any]]
    ) -> String? {
        for object in objects {
            if let value = recursiveString(for: keys, in: object), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func recursiveString(
        for keys: Set<String>,
        in value: Any
    ) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let result = dictionary[key] as? String {
                    return result
                }
            }
            for nested in dictionary.values {
                if let result = recursiveString(for: keys, in: nested) {
                    return result
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let result = recursiveString(for: keys, in: nested) {
                    return result
                }
            }
        }
        return nil
    }

    private static func firstNumber(
        for key: String,
        in objects: [[String: Any]]
    ) -> TimeInterval? {
        for object in objects {
            if let value = object[key] as? NSNumber {
                return value.doubleValue
            }
        }
        return nil
    }
}
