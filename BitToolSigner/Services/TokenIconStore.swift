import UIKit

/// Bundled token artwork. Every icon the app ships lives in one file, keyed by
/// the first 16 hex digits of its SHA-256; tokens that share artwork (the same
/// token on several chains) share one image. A single file is deliberate: 1,971
/// loose PNGs would each round up to a filesystem block on the device.
///
/// Nothing here touches the network — an unknown id simply has no icon.
enum TokenIconStore {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    /// icon id -> [offset, length] into the pack.
    private static let index: [String: [Int]] = {
        guard let url = Bundle.main.url(forResource: "TokenIcons.index", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [Int]].self, from: data) else { return [:] }
        return decoded
    }()

    /// Mapped, not read: only the pages an icon actually occupies are faulted in.
    private static let pack: Data? = {
        guard let url = Bundle.main.url(forResource: "TokenIcons", withExtension: "pack") else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }()

    static var count: Int { index.count }

    static func image(_ icon: String?) -> UIImage? {
        guard let icon, !icon.isEmpty else { return nil }
        let key = NSString(string: icon)
        if let cached = cache.object(forKey: key) { return cached }
        guard let range = index[icon], range.count == 2, let pack,
              range[0] >= 0, range[1] > 0, range[0] + range[1] <= pack.count else { return nil }
        let bytes = pack.subdata(in: range[0] ..< (range[0] + range[1]))
        // Points, not pixels: the artwork is at most 128 px and is always drawn
        // into a smaller frame, so it is downscaled rather than stretched.
        guard let image = UIImage(data: bytes) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
