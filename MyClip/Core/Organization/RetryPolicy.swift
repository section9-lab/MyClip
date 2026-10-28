import Foundation

/// Decides whether a failed organization batch is retried on its own or waits for the user.
public enum RetryPolicy {
    public enum Verdict: Sendable, Equatable { case transient, permanent }

    /// Attempts a batch gets before the queue pauses, counting the first run. With the backoff below a batch keeps
    /// retrying for about two hours, long enough to ride out a flaky network or an overloaded provider.
    public static let maxAttempts = 6

    static let backoff: [TimeInterval] = [60, 300, 900, 1800, 3600]

    /// Wait before automatically re-running a batch. The queue's own 5 minute interval still applies on top.
    public static func delay(afterAttempt attempt: Int) -> TimeInterval {
        backoff[min(max(attempt, 1), backoff.count) - 1]
    }

    public static func canRetry(afterAttempt attempt: Int) -> Bool { attempt < maxAttempts }

    public static func classify(_ error: any Error) -> Verdict {
        if error is CancellationError { return .permanent }
        if let acp = error as? ACPError {
            switch acp {
            case .timeout, .disconnected, .protocolError: return .transient
            case .unsupportedImages: return .permanent
            case .remote(let code, let message): return classifyRemote(code: code, message: message)
            }
        }
        if let library = error as? LibraryError {
            switch library {
            case .agentStopped, .rolledBack: return .transient
            default: return .permanent
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: return .transient
            default: return .permanent
            }
        }
        return classify(message: error.localizedDescription)
    }

    private static func classifyRemote(code: Int, message: String) -> Verdict {
        if [401, 403, 404].contains(code) { return .permanent }
        if [408, 425, 429, 500, 502, 503, 504, 529].contains(code) { return .transient }
        // JSON-RPC internal errors are recoverable unless they describe an account/configuration problem.
        if code == -32603, !permanentMarkers.contains(where: message.lowercased().contains) { return .transient }
        return classify(message: message)
    }

    private static let permanentMarkers = [
        "model_not_found", "no available channel", "unauthorized", "authentication", "invalid api key", "invalid_api_key",
        "not logged in", "login", "billing", "insufficient", "quota exceeded", "permission denied", "forbidden", "refusal"
    ]
    private static let transientMarkers = [
        "timeout", "timed out", "connection refused", "connection reset", "econnreset", "econnrefused", "socket hang up",
        "overloaded", "rate limit", "rate_limit", "too many requests", "temporarily", "try again", "service unavailable",
        "bad gateway", "gateway timeout", "internal server error", "network", "429", "500", "502", "503", "504", "529",
        "certificate verification", "certificate verify", "unable to verify", "cert_has_expired", "cert_not_yet_valid",
        "self signed certificate", "self-signed certificate", "self_signed_cert", "unable_to_verify_leaf_signature", "unable_to_get_issuer_cert",
        "tls handshake", "fetch failed", "响应超时", "连接已关闭", "通信错误", "整理被中断"
    ]

    /// Also used for durable failures written by an older app version. Retrying never changes TLS verification.
    public static func classify(message: String) -> Verdict {
        let text = message.lowercased()
        if permanentMarkers.contains(where: text.contains) { return .permanent }
        if transientMarkers.contains(where: text.contains) { return .transient }
        return .permanent
    }
}
