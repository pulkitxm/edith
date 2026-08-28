import Darwin
import Foundation

let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .appendingPathComponent("../../../../../MacOS/Edith")
    .standardizedFileURL.path
let arguments = [executable] + CommandLine.arguments.dropFirst()
var pointers = arguments.map { strdup($0) } + [nil]

setenv("EDITH_APPLICATION_ROLE", "files", 1)
_ = pointers.withUnsafeMutableBufferPointer { pointer in
    executable.withCString { path in
        execv(path, pointer.baseAddress)
    }
}
exit(127)
