import Foundation

/// A value as a link's query carries it: only the unreserved characters go bare. `URLComponents` leaves `&` and `+`
/// alone in a query item's value, and a mail app or GitHub's issue form reads them as the next field and a space.
public enum QueryValue {
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// `value` percent-encoded, or `nil` when it cannot be.
    public static func encoded(_ value: some StringProtocol) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }
}
