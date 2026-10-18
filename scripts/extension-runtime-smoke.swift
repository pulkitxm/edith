import AppKit
import Darwin
import Foundation
import Security

enum SmokeError: Error { case invalidRuntime }

let arguments = CommandLine.arguments
guard arguments.count == 4 else { throw SmokeError.invalidRuntime }
let app = URL(fileURLWithPath: arguments[1])
let package = URL(fileURLWithPath: arguments[2])
let expectedABI = arguments[3]
let frameworks = app.appendingPathComponent("Contents/Frameworks")
let shared = frameworks.appendingPathComponent("EdithShared.framework/Versions/A/EdithShared")
guard dlopen(shared.path, RTLD_NOW | RTLD_GLOBAL) != nil else {
    if let failure = dlerror() { fputs(String(cString: failure), stderr) }
    throw SmokeError.invalidRuntime
}
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let bundleURL = package.appendingPathComponent("helper.bundle")
var code: SecStaticCode?
guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess,
    let code,
    SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        == errSecSuccess,
    let bundle = Bundle(url: bundleURL), let executable = bundle.executableURL,
    let image = dlopen(executable.path, RTLD_NOW | RTLD_LOCAL),
    let entry = dlsym(image, "edith_extension_create")
else { throw SmokeError.invalidRuntime }
typealias Factory = @convention(c) () -> UnsafeMutableRawPointer?
guard let pointer = unsafeBitCast(entry, to: Factory.self)() else {
    throw SmokeError.invalidRuntime
}
let runtime = Unmanaged<NSObject>.fromOpaque(pointer).takeRetainedValue()
func execute(_ operation: String) throws -> NSDictionary {
    guard
        let value = runtime.perform(
            NSSelectorFromString("execute:"), with: ["operation": operation] as NSDictionary
        )?.takeUnretainedValue() as? NSDictionary
    else { throw SmokeError.invalidRuntime }
    return value
}
let description = try execute("describe")
guard description["hostABI"] as? String == expectedABI else { throw SmokeError.invalidRuntime }
for _ in 0..<2 {
    guard try execute("start")["ok"] as? Bool == true,
        try execute("status")["running"] as? Bool == true,
        try execute("synchronize")["ok"] as? Bool == true,
        try execute("stop")["ok"] as? Bool == true,
        try execute("status")["running"] as? Bool == false
    else { throw SmokeError.invalidRuntime }
}
let output: [String: Any] = [
    "id": description["id"] ?? "", "start": "passed", "stop": "passed", "restart": "passed",
]
print(
    String(
        decoding: try JSONSerialization.data(withJSONObject: output, options: .sortedKeys),
        as: UTF8.self))
