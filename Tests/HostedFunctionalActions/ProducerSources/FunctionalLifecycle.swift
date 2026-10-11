import CryptoKit
import Darwin
import Foundation
import Security

final class FunctionalPinnedPath {
    let url: URL
    private let descriptor: Int32
    private let original: stat

    init(_ url: URL, directory: Bool, privateMode: Bool = false, maximum: Int = 268_435_456) throws {
        guard url.path.hasPrefix("/"), url.path == url.standardizedFileURL.path,
            url.path == url.resolvingSymlinksInPath().path, !url.path.contains("//")
        else { throw FunctionalFailure.invalid("canonical path") }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
        guard descriptor >= 0 else { throw FunctionalFailure.invalid("open path") }
        var state = stat()
        guard fstat(descriptor, &state) == 0, state.st_uid == getuid(),
            state.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
            state.st_mode & 0o022 == 0,
            !privateMode || state.st_mode & 0o7777 == (directory ? 0o700 : 0o600),
            directory || (state.st_nlink == 1 && state.st_size >= 0 && state.st_size <= maximum)
        else { close(descriptor); throw FunctionalFailure.invalid("path ownership") }
        self.url = url
        self.descriptor = descriptor
        original = state
    }

    deinit { close(descriptor) }

    func requireCurrent() throws {
        var current = stat()
        var opened = stat()
        guard url.path == url.resolvingSymlinksInPath().path,
            lstat(url.path, &current) == 0, fstat(descriptor, &opened) == 0,
            same(original, current), same(original, opened)
        else { throw FunctionalFailure.invalid("path replaced") }
    }

    func read() throws -> Data {
        try requireCurrent()
        var bytes = Data(count: Int(original.st_size))
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == bytes.count else { throw FunctionalFailure.invalid("file read") }
        try requireCurrent()
        return bytes
    }

    private func same(_ a: stat, _ b: stat) -> Bool {
        guard a.st_dev == b.st_dev, a.st_ino == b.st_ino,
            a.st_uid == b.st_uid, a.st_mode == b.st_mode else { return false }
        return a.st_mode & S_IFMT == S_IFDIR || (a.st_nlink == b.st_nlink
            && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
            && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec)
    }
}

struct FunctionalBirth: Codable, Equatable {
    let pid: Int32
    let birthSeconds: UInt64
    let birthMicroseconds: UInt32
    let uid: UInt32
    let executable: String
    let executableSHA256: String

    static func observe(_ pid: Int32) throws -> Self {
        guard pid > 1 else { throw FunctionalFailure.invalid("process pid") }
        var first = proc_bsdinfo()
        var last = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &first, size) == size,
            first.pbi_uid == getuid(), first.pbi_ruid == getuid(), first.pbi_status != SZOMB,
            first.pbi_start_tvusec < 1_000_000,
            proc_pidpath(pid, &path, UInt32(path.count)) > 0,
            let end = path.firstIndex(of: 0)
        else { throw FunctionalFailure.invalid("process observation") }
        let executable = String(decoding: path[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let bytes = try FunctionalPinnedPath(URL(fileURLWithPath: executable), directory: false).read()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &last, size) == size,
            first.pbi_uid == last.pbi_uid, first.pbi_ruid == last.pbi_ruid,
            first.pbi_start_tvsec == last.pbi_start_tvsec,
            first.pbi_start_tvusec == last.pbi_start_tvusec, last.pbi_status != SZOMB
        else { throw FunctionalFailure.invalid("process changed") }
        return Self(pid: pid, birthSeconds: first.pbi_start_tvsec,
            birthMicroseconds: UInt32(first.pbi_start_tvusec), uid: first.pbi_uid,
            executable: executable, executableSHA256: FunctionalBytes.digest(bytes))
    }

    func requireCurrent() throws {
        guard try Self.observe(pid) == self else { throw FunctionalFailure.invalid("stale birth") }
    }

    func requireAbsent() throws {
        var state = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &state, size)
        guard result == 0 && errno == ESRCH || result == size && (
            state.pbi_start_tvsec != birthSeconds || state.pbi_start_tvusec != birthMicroseconds)
        else { throw FunctionalFailure.invalid("birth still present or unverifiable") }
    }

    var object: [String: Any] {
        ["pid": pid, "birthSeconds": birthSeconds, "birthMicroseconds": birthMicroseconds,
            "uid": uid, "executable": executable, "executableSHA256": executableSHA256]
    }

    var contractObject: [String: Any] {
        object.filter { $0.key != "executable" }
    }
}

struct FunctionalSigner {
    let identifier: String
    let certificateSHA256: Data
    let requirement: String

    func verify(_ url: URL, birth: FunctionalBirth? = nil) throws {
        guard certificateSHA256.count == 32, !requirement.isEmpty else { throw FunctionalFailure.invalid("signer pin") }
        var code: SecStaticCode?
        var required: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess,
            SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), required) == errSecSuccess
        else { throw FunctionalFailure.invalid("static signature") }
        try checkCertificate(code)
        if let birth {
            try birth.requireCurrent()
            var guest: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: birth.pid] as CFDictionary, [], &guest) == errSecSuccess,
                let guest, SecCodeCheckValidity(guest, [], required) == errSecSuccess
            else { throw FunctionalFailure.invalid("live signature") }
            var guestStatic: SecStaticCode?
            guard SecCodeCopyStaticCode(guest, [], &guestStatic) == errSecSuccess, let guestStatic
            else { throw FunctionalFailure.invalid("live static code") }
            try checkCertificate(guestStatic)
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(guestStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                let values = information as? [String: Any],
                let executable = values[kSecCodeInfoMainExecutable as String] as? URL,
                executable.path == birth.executable,
                url.path == birth.executable || url.appendingPathComponent("Contents/MacOS/Edith").path == birth.executable
            else { throw FunctionalFailure.invalid("live executable path") }
            try birth.requireCurrent()
        }
    }

    private func checkCertificate(_ code: SecStaticCode) throws {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
            let values = information as? [String: Any],
            values[kSecCodeInfoIdentifier as String] as? String == identifier,
            let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first,
            Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)) == certificateSHA256
        else { throw FunctionalFailure.invalid("certificate pin") }
    }
}

