import Foundation

/// One file of a photo to back up.
public struct BackupFile: Sendable, Equatable {
    public var originalFilename: String
    /// A rendered edit, which is named after the original (they're all called `FullSizeRender`).
    public var isEdit: Bool

    public init(originalFilename: String, isEdit: Bool) {
        self.originalFilename = originalFilename
        self.isEdit = isEdit
    }
}

/// Decides where a photo's files go: `<year>/<name>`, in the layout of the picture library.
public enum BackupNaming {
    public static func folder(year: Int?) -> String {
        year.map { String(format: "%04d", $0) } ?? LibraryPath.undatedFolder
    }

    /// The paths of a photo's files, in order. `suffix` 0 is the plain name; higher ones give
    /// `IMG_1234 (1).HEIC`, used when the plain name is taken. A photo's files share one suffix so
    /// that a Live Photo's picture and video stay paired.
    public static func paths(for files: [BackupFile], folder: String, suffix: Int) -> [String] {
        let tail = suffix == 0 ? "" : " (\(suffix))"
        let firstOriginal = files.first { !$0.isEdit }.map { stem(of: sanitized($0.originalFilename)) }
        var used = Set<String>()
        return files.map { file in
            let name = sanitized(file.originalFilename)
            let fileExtension = (name as NSString).pathExtension
            let base = file.isEdit ? "\(firstOriginal ?? stem(of: name))\(tail)-edited" : "\(stem(of: name))\(tail)"
            var candidate = joined(base, fileExtension)
            var count = 2
            while !used.insert(LibraryPath.normalized(candidate)).inserted {
                candidate = joined("\(base)-\(count)", fileExtension)
                count += 1
            }
            return "\(folder)/\(candidate)"
        }
    }

    /// Finds the paths for a photo without ever overwriting a different picture.
    ///
    /// - `isOccupied`: whether something is already at a path.
    /// - `isIdentical`: whether the file at a path has the same contents as the file at that index,
    ///   in which case this photo has already been backed up there and the path is adopted. Checking
    ///   every suffix is what lets a backup find its earlier copies after the app is reinstalled.
    ///
    /// Originals decide the suffix. A photo whose originals are already there keeps that suffix
    /// whatever is at its edit path, which `editPath` then deals with; otherwise an occupied edit
    /// path counts as a collision.
    public static func resolve(
        files: [BackupFile],
        folder: String,
        isOccupied: (String) -> Bool,
        isIdentical: (Int, String) async throws -> Bool
    ) async throws -> [String] {
        var suffix = 0
        while true {
            let paths = paths(for: files, folder: folder, suffix: suffix)
            var adopted = false
            var collided = false
            for (index, path) in paths.enumerated() where !files[index].isEdit && isOccupied(path) {
                if try await isIdentical(index, path) {
                    adopted = true
                } else {
                    collided = true
                    break
                }
            }
            if !collided && !adopted {
                collided = zip(files, paths).contains { $0.isEdit && isOccupied($1) }
            }
            if !collided { return paths }
            suffix += 1
        }
    }

    /// An edit's path, moved along if something that isn't this photo's is already there, such as an
    /// `IMG_1234-edited.jpg` from a photo export. Edits replace their own file, so this is what keeps
    /// them from replacing anything else.
    public static func editPath(_ path: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(path) else { return path }
        let base = (path as NSString).deletingPathExtension
        let fileExtension = (path as NSString).pathExtension
        var count = 2
        while true {
            let candidate = joined("\(base)-\(count)", fileExtension)
            if !isTaken(candidate) { return candidate }
            count += 1
        }
    }

    /// File names must be valid on exFAT as well as S3, and start with a visible character
    /// because hidden files aren't library content.
    private static func sanitized(_ filename: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var name = String(String.UnicodeScalarView(filename.unicodeScalars.map { forbidden.contains($0) ? "_" : $0 }))
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }
        return name.isEmpty ? "resource" : name
    }

    private static func stem(of name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    private static func joined(_ stem: String, _ fileExtension: String) -> String {
        fileExtension.isEmpty ? stem : "\(stem).\(fileExtension)"
    }
}
