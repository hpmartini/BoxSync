import BoxSyncCore
import FileProvider
import UniformTypeIdentifiers

/// What macOS sees of one indexed Box item.
final class BoxItem: NSObject, NSFileProviderItem {
    let it: IndexedItem
    let inTrash: Bool

    init(_ it: IndexedItem, inTrash: Bool = false) { self.it = it; self.inTrash = inTrash }

    // The index uses the system's own identifier strings for root and trash, so the mapping is the identity.
    static func fp(_ id: String) -> NSFileProviderItemIdentifier { NSFileProviderItemIdentifier(id) }
    static func id(_ fp: NSFileProviderItemIdentifier) -> String { fp.rawValue }

    var itemIdentifier: NSFileProviderItemIdentifier { Self.fp(it.id) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { it.id == ItemIndex.rootID ? .rootContainer : Self.fp(it.parent) }
    var filename: String { it.id == ItemIndex.rootID ? "BoxSync" : it.name }

    var contentType: UTType {
        if it.isDirectory { return .folder }
        let ext = (it.name as NSString).pathExtension
        return ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
    }

    var documentSize: NSNumber? { it.isDirectory ? nil : NSNumber(value: it.size) }
    var contentModificationDate: Date? { Date(timeIntervalSince1970: TimeInterval(it.mtime)) }
    var creationDate: Date? { contentModificationDate }

    /// Content version `size:mtime` (read back by `contentStamp`); metadata version adds the location.
    var itemVersion: NSFileProviderItemVersion {
        let content = "\(it.size):\(it.mtime)"
        return NSFileProviderItemVersion(contentVersion: Data(content.utf8),
                                         metadataVersion: Data("\(content):\(it.parent)/\(it.name)".utf8))
    }

    /// Size and mtime from a content version written by `itemVersion`.
    static func contentStamp(_ v: NSFileProviderItemVersion) -> (size: UInt64, mtime: Int64)? {
        let parts = String(decoding: v.contentVersion, as: UTF8.self).split(separator: ":")
        guard parts.count == 2, let s = UInt64(parts[0]), let m = Int64(parts[1]) else { return nil }
        return (s, m)
    }

    var capabilities: NSFileProviderItemCapabilities {
        if it.id == ItemIndex.rootID { return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems] }
        if inTrash { return [.allowsReading, .allowsContentEnumerating, .allowsReparenting, .allowsDeleting] }
        var c: NSFileProviderItemCapabilities = [.allowsReading, .allowsRenaming, .allowsReparenting, .allowsTrashing, .allowsDeleting]
        if it.isDirectory { c.formUnion([.allowsContentEnumerating, .allowsAddingSubItems]) } else { c.insert(.allowsWriting) }
        return c
    }
}
