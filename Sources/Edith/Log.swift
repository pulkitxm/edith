import os

enum Log {
    static let usage = Logger(subsystem: "com.pulkit.edith", category: "usage")
    static let lifecycle = Logger(subsystem: "com.pulkit.edith", category: "lifecycle")
}
