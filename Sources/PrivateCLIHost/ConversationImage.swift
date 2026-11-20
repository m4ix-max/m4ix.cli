import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A small preview derived from the provider's own transcript. Keeping only
/// the thumbnail avoids retaining full-size pictures in every chat snapshot.
struct ConversationImage: Identifiable, Equatable, Sendable {
    let id: String
    let thumbnail: Data?

    init(id: String, block: [String: Any]) {
        self.id = id
        let data: Data?
        if let source = block["source"] as? [String: Any],
           source["type"] as? String == "base64", let encoded = source["data"] as? String {
            data = Data(base64Encoded: encoded)
        } else if let url = block["image_url"] as? String,
                  url.hasPrefix("data:image/"), let comma = url.firstIndex(of: ","),
                  url[..<comma].hasSuffix(";base64") {
            data = Data(base64Encoded: String(url[url.index(after: comma)...]))
        } else {
            data = nil
        }
        thumbnail = data.flatMap(Self.makeThumbnail)
    }

    /// Called by the transcript reader, off the main thread. ImageIO
    /// downsamples before decoding and applies the picture's orientation.
    private static func makeThumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480
              ] as CFDictionary) else { return nil }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return result as Data
    }
}
