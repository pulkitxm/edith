import Darwin
import Foundation
import MachO

public enum ExtensionNativeImages {
    struct Image: Equatable {
        let installName: String
        let uuid: UUID
    }

    public static func conflicts(bundles: [URL], loadedWithin owner: URL) -> [String] {
        guard let scope = canonical(owner.path) else { return [] }
        let candidates = bundles.flatMap(images(in:))
        guard !candidates.isEmpty else { return [] }
        let names = Set(candidates.map(\.installName))
        let loaded = loadedImages().filter { names.contains($0.image.installName) }.filter {
            canonical($0.path)?.hasPrefix(scope + "/") == true
        }.map(\.image)
        let conflicting = candidates.filter { candidate in
            loaded.contains {
                $0.installName == candidate.installName && $0.uuid != candidate.uuid
            }
        }.map(\.installName)
        return Set(conflicting).sorted()
    }

    static func images(in bundle: URL) -> [Image] {
        let directory = bundle.appendingPathComponent("Contents/Frameworks")
        let items =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { item in
            switch item.pathExtension {
            case "dylib": return image(at: item)
            case "framework":
                return image(
                    at: item.appendingPathComponent(item.deletingPathExtension().lastPathComponent))
            default: return nil
            }
        }
    }

    static func loadedImages() -> [(path: String, image: Image)] {
        (0..<_dyld_image_count()).compactMap { index in
            guard let header = _dyld_get_image_header(index),
                let name = _dyld_get_image_name(index),
                header.pointee.magic == MH_MAGIC_64
            else { return nil }
            let size = MemoryLayout<mach_header_64>.size + Int(header.pointee.sizeofcmds)
            let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(header), count: size)
            return parse(bytes).map { (String(cString: name), $0) }
        }
    }

    static func image(at url: URL) -> Image? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let start = sliceOffset(handle),
            (try? handle.seek(toOffset: start)) != nil,
            let header = try? handle.read(upToCount: MemoryLayout<mach_header_64>.size),
            header.count == MemoryLayout<mach_header_64>.size
        else { return nil }
        let commands = header.withUnsafeBytes {
            Int($0.loadUnaligned(as: mach_header_64.self).sizeofcmds)
        }
        guard commands > 0, commands <= 16_777_216,
            let rest = try? handle.read(upToCount: commands), rest.count == commands
        else { return nil }
        return (header + rest).withUnsafeBytes(parse)
    }

    private static func sliceOffset(_ handle: FileHandle) -> UInt64? {
        guard let magic = try? handle.read(upToCount: 8), magic.count == 8 else { return nil }
        let value = magic.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if value == MH_MAGIC_64 { return 0 }
        guard value == FAT_CIGAM else { return nil }
        let count = magic.withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        }
        let entry = MemoryLayout<fat_arch>.size
        guard count > 0, count <= 64,
            let table = try? handle.read(upToCount: Int(count) * entry),
            table.count == Int(count) * entry
        else { return nil }
        return table.withUnsafeBytes { bytes in
            (0..<Int(count)).lazy.map {
                bytes.loadUnaligned(fromByteOffset: $0 * entry, as: fat_arch.self)
            }
            .first { cpu_type_t(bigEndian: $0.cputype) == CPU_TYPE_ARM64 }
            .map { UInt64(UInt32(bigEndian: $0.offset)) }
        }
    }

    static func parse(_ bytes: UnsafeRawBufferPointer) -> Image? {
        guard bytes.count >= MemoryLayout<mach_header_64>.size else { return nil }
        let header = bytes.loadUnaligned(as: mach_header_64.self)
        guard header.magic == MH_MAGIC_64, header.filetype == UInt32(MH_DYLIB) else { return nil }
        var offset = MemoryLayout<mach_header_64>.size
        let end = min(bytes.count, offset + Int(header.sizeofcmds))
        var installName: String?
        var uuid: UUID?
        for _ in 0..<header.ncmds {
            guard offset + MemoryLayout<load_command>.size <= end else { break }
            let command = bytes.loadUnaligned(fromByteOffset: offset, as: load_command.self)
            let size = Int(command.cmdsize)
            guard size >= MemoryLayout<load_command>.size, offset + size <= end else { break }
            if command.cmd == UInt32(LC_ID_DYLIB), size >= MemoryLayout<dylib_command>.size {
                let dylib = bytes.loadUnaligned(fromByteOffset: offset, as: dylib_command.self)
                let start = offset + Int(dylib.dylib.name.offset)
                if start < offset + size {
                    installName = String(
                        decoding: bytes[start..<(offset + size)].prefix { $0 != 0 }, as: UTF8.self)
                }
            } else if command.cmd == UInt32(LC_UUID), size >= MemoryLayout<uuid_command>.size {
                uuid = UUID(
                    uuid: bytes.loadUnaligned(fromByteOffset: offset, as: uuid_command.self).uuid)
            }
            offset += size
        }
        guard let installName, !installName.isEmpty, let uuid else { return nil }
        return Image(installName: installName, uuid: uuid)
    }

    private static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

extension ExtensionPackageStore {
    public func loadedImageConflicts(
        _ package: ExtensionPackage,
        roles: [ExtensionBundleRuntime.Role] = [.helper, .agent, .app]
    ) -> [String] {
        ExtensionNativeImages.conflicts(
            bundles: roles.map { roleBundle(for: package, role: $0) },
            loadedWithin: root.appendingPathComponent(package.id))
    }
}
