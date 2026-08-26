import Foundation

/// A single notification's title and body, decided independently of
/// `UNUserNotificationCenter` so the merge decision below is testable
/// without posting anything. See issue #556.
public struct NotificationContent: Equatable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}
