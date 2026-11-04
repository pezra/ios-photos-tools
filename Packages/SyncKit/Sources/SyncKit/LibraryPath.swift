import CryptoKit
import Foundation

/// Paths relative to the root of the picture library, e.g. `2007/023 (2).JPG`. A path is what
/// identifies a picture: the same file name appears in many folders.
public enum LibraryPath {
    /// The form used to compare paths. The drive is case-insensitive and it and S3 can differ in
    /// Unicode normalization, so two spellings of one path must compare equal.
    public static func normalized(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// A short hash of the path, which identifies an imported photo in the Photos library.
    public static func tag(for path: String) -> String {
        let digest = SHA256.hash(data: Data(normalized(path).utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static let tagMarker = ".ptk-"
    private static let maxFilenameBytes = 255

    /// The file name for the low-res copy of `path`, e.g. `IMG_1234.ptk-9f3a2c1b7d04.HEIC`.
    ///
    /// The name is the one record of an import that lives with the photo itself, so imports can be
    /// recognized with no database, drive or network.
    public static func taggedFilename(for path: String, fileExtension: String) -> String {
        let name = (path as NSString).lastPathComponent
        var stem = (name as NSString).deletingPathExtension
        let suffix = "\(tagMarker)\(tag(for: path)).\(fileExtension)"
        while stem.utf8.count + suffix.utf8.count > maxFilenameBytes { stem.removeLast() }
        return stem + suffix
    }

    /// The tag in a file name made by `taggedFilename`, if it has one.
    public static func tag(inFilename filename: String) -> String? {
        guard let marker = filename.range(of: tagMarker, options: .backwards) else { return nil }
        let rest = filename[marker.upperBound...]
        let tag = rest.prefix { $0 != "." }
        guard tag.count == 12, tag.allSatisfy(\.isHexDigit), rest.dropFirst(tag.count).first == "." else { return nil }
        return String(tag)
    }

    /// Whether `path` is real library content, rather than a hidden file (`._*` AppleDouble files,
    /// `.partial` uploads, the `.photos-tools` folder) or an object in the layout the app used to
    /// write to the bucket.
    public static func isLibraryContent(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard !parts.isEmpty, !parts.contains(where: { $0.hasPrefix(".") }) else { return false }
        return !isOldLayout(parts)
    }

    /// `<year>/<month>/<asset-uuid>/<file>`
    private static func isOldLayout(_ parts: [Substring]) -> Bool {
        guard parts.count == 4 else { return false }
        return parts[0].count == 4 && parts[0].allSatisfy(\.isNumber)
            && parts[1].count == 2 && parts[1].allSatisfy(\.isNumber)
            && UUID(uuidString: String(parts[2])) != nil
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "bmp", "tif", "tiff", "nef"]

    /// Whether `path` is a picture to copy to the phone. Videos stay in storage.
    public static func isImportable(_ path: String) -> Bool {
        isLibraryContent(path) && imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    public static func isUndated(_ path: String) -> Bool {
        path.split(separator: "/").first?.lowercased() == "undated"
    }
}

/// When an imported picture should appear in the timeline.
public enum ImportDate {
    /// Parses an EXIF date such as `2003:05:18 14:02:11`, with its offset (`-07:00`) if known.
    /// Cameras often leave the date as zeros or blanks, which give nil.
    public static func parse(exif value: String, offset: String? = nil) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        if let offset, !offset.isEmpty {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from: value + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }

    /// For pictures with no date of their own: the start of the folder's year, or a fixed date for
    /// `undated/`, so they don't all land on the day they were imported.
    public static func fallback(for path: String) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let folder = path.split(separator: "/").first.map(String.init) ?? ""
        var year = 2000
        if folder.count == 4, let parsed = Int(folder), (1900...2100).contains(parsed) { year = parsed }
        return calendar.date(from: DateComponents(year: year, month: 1, day: 1, hour: 12)) ?? Date(timeIntervalSince1970: 946_728_000)
    }
}
