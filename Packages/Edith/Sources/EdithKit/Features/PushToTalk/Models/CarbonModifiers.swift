import Carbon.HIToolbox
import CoreGraphics

public enum CarbonModifiers {
    public static func toCGEventFlags(_ carbon: Int) -> CGEventFlags {
        var flags: CGEventFlags = []
        if carbon & cmdKey != 0 { flags.insert(.maskCommand) }
        if carbon & shiftKey != 0 { flags.insert(.maskShift) }
        if carbon & optionKey != 0 { flags.insert(.maskAlternate) }
        if carbon & controlKey != 0 { flags.insert(.maskControl) }
        return flags
    }
}
