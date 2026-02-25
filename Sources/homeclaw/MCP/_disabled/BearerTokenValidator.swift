import Foundation

/// Validates bearer tokens from incoming HTTP requests.
enum BearerTokenValidator {
    /// Extracts and validates a bearer token from an Authorization header value.
    /// Returns true if the token matches the stored keychain token.
    static func validate(authorizationHeader: String?) -> Bool {
        guard let header = authorizationHeader,
              header.hasPrefix("Bearer ")
        else {
            return false
        }

        let token = String(header.dropFirst("Bearer ".count))
        guard !token.isEmpty else { return false }

        do {
            guard let storedToken = try KeychainManager.readToken() else {
                AppLogger.auth.warning("No bearer token configured — rejecting request")
                return false
            }
            return token == storedToken
        } catch {
            AppLogger.auth.error("Token validation error: \(error.localizedDescription)")
            return false
        }
    }
}
