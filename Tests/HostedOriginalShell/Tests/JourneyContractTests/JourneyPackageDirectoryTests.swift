import Foundation
import JourneyContract
import Testing

private func packageDirectory(_ version: String = "1.0.0") throws -> JourneyPackageDirectory {
    try JourneyPackageDirectory(
        id: "calendar", hostABI: "edith-host-2", architecture: "arm64", version: version)
}

private func syntheticRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("journey-package-" + UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
}

@Test func packagePresenceRequiresTheExactCapturedVersionDirectory() throws {
    let root = try syntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try packageDirectory()
    let second = try packageDirectory("1.1.0")
    #expect(try !first.isPresent(in: root))
    #expect(try !second.isPresent(in: root))
    for package in [first, second] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(package.relativePath),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        #expect(try package.isPresent(in: root))
    }
    try FileManager.default.removeItem(at: root.appendingPathComponent(first.relativePath))
    #expect(try !first.isPresent(in: root))
    #expect(try second.isPresent(in: root))
    try FileManager.default.removeItem(at: root.appendingPathComponent(second.relativePath))
    #expect(try !second.isPresent(in: root))
}

@Test func packageInspectionRejectsEverySymlinkedAncestorAndLeaf() throws {
    let package = try packageDirectory()
    let components = package.relativePath.split(separator: "/").map(String.init)
    for index in components.indices {
        let root = try syntheticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("retained-data")
        try FileManager.default.createDirectory(
            at: sentinel, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let data = sentinel.appendingPathComponent("sentinel.json")
        try Data("synthetic retained data".utf8).write(to: data)
        var ancestor = root
        for component in components.prefix(index) {
            ancestor.appendPathComponent(component)
            try FileManager.default.createDirectory(
                at: ancestor, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.createSymbolicLink(
            at: ancestor.appendingPathComponent(components[index]), withDestinationURL: sentinel)
        #expect(throws: JourneyContractError.invalidPaths) { try package.isPresent(in: root) }
        #expect(try Data(contentsOf: data) == Data("synthetic retained data".utf8))
    }
}

@Test func packageInspectionRejectsBrokenLinksFilesAndWritableAncestors() throws {
    for kind in ["broken-link", "file", "writable"] {
        let root = try syntheticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Extensions")
        if kind == "broken-link" {
            try FileManager.default.createSymbolicLink(
                at: path, withDestinationURL: root.appendingPathComponent("absent"))
        } else if kind == "file" {
            try Data("synthetic".utf8).write(to: path)
        } else {
            try FileManager.default.createDirectory(
                at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o777]
            )
        }
        #expect(throws: JourneyContractError.invalidPaths) {
            try packageDirectory().isPresent(in: root)
        }
    }
}

@Test func packageCaptureRejectsUnreviewedIdentitiesAndTraversal() throws {
    for values in [
        ["../calendar", "edith-host-2", "arm64", "1.0.0"],
        ["calendar", "other", "arm64", "1.0.0"],
        ["calendar", "edith-host-2", "x86_64", "1.0.0"],
        ["calendar", "edith-host-2", "arm64", "../../data"],
        ["calendar", "edith-host-2", "arm64", "2.0.0"],
    ] {
        #expect(throws: JourneyContractError.invalidMetadata) {
            try JourneyPackageDirectory(
                id: values[0], hostABI: values[1], architecture: values[2], version: values[3])
        }
    }
}
