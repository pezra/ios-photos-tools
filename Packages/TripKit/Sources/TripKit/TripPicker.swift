import Foundation

/// What picking needs to know about a photo, from on-device analysis and the library.
public struct PickCandidate: Sendable {
    public let id: String
    /// -1 (poor) to 1 (great).
    public let aesthetics: Float
    /// Screenshots, receipts, documents and the like.
    public let isUtility: Bool
    public let faceCount: Int
    /// Fraction of the frame covered by the largest face, 0–1.
    public let faceArea: Float
    /// Fraction of the frame covered by the largest person, 0–1.
    public let personArea: Float
    /// Capture quality (0–1) of the worst face, or nil if there are no faces.
    public let faceQuality: Float?
    public let sharpness: Double
    public let isFavorite: Bool
    public let isEdited: Bool
    /// Unit-length feature print, for telling apart shots that look alike.
    public let featurePrint: [Float]

    public init(id: String, aesthetics: Float, isUtility: Bool, faceCount: Int, faceArea: Float,
                personArea: Float, faceQuality: Float?, sharpness: Double, isFavorite: Bool,
                isEdited: Bool, featurePrint: [Float]) {
        self.id = id
        self.aesthetics = aesthetics
        self.isUtility = isUtility
        self.faceCount = faceCount
        self.faceArea = faceArea
        self.personArea = personArea
        self.faceQuality = faceQuality
        self.sharpness = sharpness
        self.isFavorite = isFavorite
        self.isEdited = isEdited
        self.featurePrint = featurePrint
    }
}

/// Chooses the photos from each site that go into a trip album: ideally one of the people there
/// and one of the place itself.
public enum TripPicker {
    public enum Kind: Sendable {
        /// Someone is the subject: a portrait, or a person posing in front of something.
        case people
        /// The place itself, with nobody prominent in it.
        case scene
        case other
    }

    public struct Options: Sendable {
        /// Photos scoring below this are never picked unless they're favourites.
        public var minAesthetics: Float = -0.3
        /// A site with only a shot or two gets a pick only if it's at least this good.
        public var smallSiteMinAesthetics: Float = 0
        /// Extra picks must be at least this far (feature-print distance, 0–2) from the others.
        public var minDistance: Float = 0.6

        public init() {}
    }

    public static func kind(_ c: PickCandidate) -> Kind {
        if c.faceCount > 0 && (c.faceArea >= 0.01 || c.personArea >= 0.08) { return .people }
        if c.faceArea < 0.002 && c.personArea < 0.03 { return .scene }
        return .other
    }

    /// How many photos a site gets, given how many different shots were taken there.
    public static func pickCount(distinctShots: Int) -> Int {
        switch distinctShots {
        case 0: 0
        case ..<4: 1
        case ..<12: 2
        default: 3
        }
    }

    /// The IDs to put in the album for one site. Pass one candidate per distinct shot, with
    /// retakes already collapsed to the best of each.
    public static func picks(_ shots: [PickCandidate], options: Options = Options()) -> [String] {
        let eligible = shots.filter { !$0.isUtility && ($0.isFavorite || $0.aesthetics >= options.minAesthetics) }
        let count = pickCount(distinctShots: eligible.count)
        guard count > 0 else { return [] }

        let sharpest = eligible.map(\.sharpness).max() ?? 0
        func score(_ c: PickCandidate) -> Double {
            var score = Double(c.aesthetics)
            // Relative within the site: absolute sharpness depends too much on content.
            if sharpest > 0 { score += 0.3 * (c.sharpness / sharpest) }
            if kind(c) == .people { score += 0.5 * Double(c.faceQuality ?? 0) }
            if c.isEdited { score += 0.2 }
            return score
        }
        // Favourites first, then by score.
        let ranked = eligible.map { (candidate: $0, score: score($0)) }
            .sorted { lhs, rhs in
                if lhs.candidate.isFavorite != rhs.candidate.isFavorite { return lhs.candidate.isFavorite }
                return lhs.score > rhs.score
            }
            .map(\.candidate)

        if count == 1 {
            let best = ranked[0]
            let worthIt = eligible.count >= 3 || best.isFavorite || best.aesthetics >= options.smallSiteMinAesthetics
            return worthIt ? [best.id] : []
        }

        var picks: [PickCandidate] = []
        if let person = ranked.first(where: { kind($0) == .people }) { picks.append(person) }
        if let scene = ranked.first(where: { kind($0) == .scene }) { picks.append(scene) }
        for candidate in ranked where picks.count < count {
            guard !picks.contains(where: { $0.id == candidate.id }) else { continue }
            if picks.allSatisfy({ distance($0.featurePrint, candidate.featurePrint) >= options.minDistance }) {
                picks.append(candidate)
            }
        }
        return picks.map(\.id)
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        var sum: Float = 0
        for i in a.indices {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }
}
