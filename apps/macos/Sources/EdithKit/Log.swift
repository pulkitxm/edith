import os

public enum Log {
    public static let usage = Logger(subsystem: "com.pulkit.edith", category: "usage")
    public static let lifecycle = Logger(subsystem: "com.pulkit.edith", category: "lifecycle")
}
