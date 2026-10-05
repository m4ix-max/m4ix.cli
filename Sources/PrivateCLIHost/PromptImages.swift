import AppKit
import UniformTypeIdentifiers

/// An image waiting in the prompt bar. The file is a private copy with a
/// plain name, so the CLI reads the image as it was attached, even if the
/// original moves, and its path needs no quoting when pasted.
struct PromptImage: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let thumbnail: NSImage

    static func == (lhs: PromptImage, rhs: PromptImage) -> Bool { lhs.id == rhs.id }
}

enum PromptImageStore {
    private static func imageFiles(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls }
        // Finder and some image browsers still advertise the older file list.
        let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func canPasteImages(from pasteboard: NSPasteboard) -> Bool {
        let files = imageFiles(on: pasteboard)
        if !files.isEmpty {
            return files.contains { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        }
        return pasteboard.string(forType: .string) == nil && NSImage.canInit(with: pasteboard)
    }
    static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let owner = Bundle.main.bundleIdentifier ?? "PrivateCLIHost"
        return caches.appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent("prompt-images", isDirectory: true)
    }()

    /// Formats both CLIs attach as they are. Anything else, such as HEIC or
    /// TIFF, is converted to PNG first.
    private static let passThrough: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    static func add(fileAt source: URL, in directory: URL = directory) -> PromptImage? {
        let ext = source.pathExtension.lowercased()
        guard UTType(filenameExtension: ext)?.conforms(to: .image) == true else { return nil }
        guard passThrough.contains(ext) else {
            return NSImage(contentsOf: source).flatMap { add(image: $0, in: directory) }
        }
        guard let target = newFile(ext, in: directory),
              (try? FileManager.default.copyItem(at: source, to: target)) != nil,
              let thumbnail = NSImage(contentsOf: target) else { return nil }
        return PromptImage(url: target, thumbnail: thumbnail)
    }

    static func add(image: NSImage, in directory: URL = directory) -> PromptImage? {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
              let target = newFile("png", in: directory),
              (try? png.write(to: target)) != nil else { return nil }
        return PromptImage(url: target, thumbnail: image)
    }

    /// Images on a pasteboard: image files first, then image data. A paste
    /// that also carries plain text is text, because rich text copied from
    /// other apps often includes a picture of itself.
    static func images(from pasteboard: NSPasteboard, isPaste: Bool, in directory: URL = directory) -> [PromptImage] {
        let files = imageFiles(on: pasteboard)
        if !files.isEmpty {
            return files.compactMap { add(fileAt: $0, in: directory) }
        }
        if isPaste, pasteboard.string(forType: .string) != nil { return [] }
        guard NSImage.canInit(with: pasteboard), let image = NSImage(pasteboard: pasteboard) else { return [] }
        return add(image: image, in: directory).map { [$0] } ?? []
    }

    /// Loads images dropped from Finder, a browser, or another app.
    static func load(_ providers: [NSItemProvider], completion: @escaping ([PromptImage]) -> Void) {
        let group = DispatchGroup()
        var sources: [Int: Any] = [:]
        let lock = NSLock()
        for (index, provider) in providers.enumerated() {
            group.enter()
            let store: (Any?) -> Void = { value in
                if let value { lock.withLock { sources[index] = value } }
                group.leave()
            }
            if provider.canLoadObject(ofClass: NSURL.self) {
                _ = provider.loadObject(ofClass: NSURL.self) { url, _ in store((url as? URL)?.isFileURL == true ? url : nil) }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in store(image) }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let images = sources.keys.sorted().compactMap { index -> PromptImage? in
                switch sources[index] {
                case let url as URL: return add(fileAt: url)
                case let image as NSImage: return add(image: image)
                default: return nil
                }
            }
            completion(images)
        }
    }

    /// The CLIs read an image when its prompt is sent. A month leaves room
    /// for anything that reads it again, such as a resumed conversation.
    static func prune(olderThan age: TimeInterval = 30 * 24 * 3600, in directory: URL = directory) {
        let cutoff = Date().addingTimeInterval(-age)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func newFile(_ ext: String, in directory: URL) -> URL? {
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        return directory.appendingPathComponent("\(UUID().uuidString.lowercased()).\(ext)")
    }
}
