import SwiftUI

public enum Motion {
    public static let glide = Animation.smooth(duration: 0.35)
    public static let snap = Animation.snappy(duration: 0.25)
    public static let settle = Animation.smooth(duration: 0.5)

    public static func animation(_ base: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : base
    }
}
