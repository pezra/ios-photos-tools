import Foundation

public struct Coordinate: Sendable, Hashable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance in metres.
    public func distance(to other: Coordinate) -> Double {
        let r = 6_371_000.0
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, a.squareRoot()))
    }
}

/// What trip detection needs to know about a photo.
public struct TripPhoto: Sendable, Hashable {
    public let id: String
    public let date: Date
    public let coordinate: Coordinate?

    public init(id: String, date: Date, coordinate: Coordinate?) {
        self.id = id
        self.date = date
        self.coordinate = coordinate
    }
}

/// One place visited during a trip, such as a viewpoint, a museum or a town square.
public struct Site: Sendable, Hashable {
    /// Capture order.
    public let photoIDs: [String]
    public let center: Coordinate
    public let start: Date
    public let end: Date
}

public struct DetectedTrip: Sendable, Hashable {
    public let start: Date
    public let end: Date
    /// Capture order.
    public let sites: [Site]
    /// False while the trip may still be going on.
    public let isFinished: Bool

    public var photoIDs: [String] { sites.flatMap(\.photoIDs) }
}

/// Finds trips away from the places where most photos are taken, and splits each into sites.
public enum TripDetector {
    public struct Options: Sendable {
        /// Size of the grid cells used to find usual places, in degrees (0.1° is about 11 km
        /// north to south).
        public var cellSize = 0.1
        /// A cell is a usual place (home, work, family…) once it has photos on this many days…
        public var usualMinDays = 8
        /// …spread over at least this many calendar months, so a long stay somewhere doesn't
        /// turn that place into home.
        public var usualMinMonths = 3
        /// A gap in photos longer than this ends a trip.
        public var maxGap: TimeInterval = 2 * 24 * 60 * 60
        /// Fewer geotagged photos than this isn't a trip, just a stray snap.
        public var minPhotos = 12
        /// Photos further than this from a site's centre start a new site.
        public var siteRadius: Double = 750
        /// A gap in photos longer than this starts a new site.
        public var siteGap: TimeInterval = 90 * 60
        /// Photos without a location join the site of the nearest geotagged photo taken within this long.
        public var untaggedWindow: TimeInterval = 10 * 60

        public init() {}
    }

    struct Cell: Hashable {
        let lat: Int
        let lon: Int
    }

    /// Trips in capture order. Pass every photo in the library.
    public static func trips(_ photos: [TripPhoto], now: Date, calendar: Calendar = .current,
                             options: Options = Options()) -> [DetectedTrip] {
        let usual = usualPlaces(photos, calendar: calendar, options: options)
        func isUsual(_ c: Coordinate) -> Bool {
            let home = cell(c, options: options)
            for dLat in -1...1 {
                for dLon in -1...1 where usual.contains(Cell(lat: home.lat + dLat, lon: home.lon + dLon)) {
                    return true
                }
            }
            return false
        }

        let sorted = photos.sorted { $0.date < $1.date }
        let tagged = sorted.filter { $0.coordinate != nil }
        let untagged = sorted.filter { $0.coordinate == nil }

        var runs: [(photos: [TripPhoto], endedAtUsualPlace: Bool)] = []
        var current: [TripPhoto] = []
        func close(endedAtUsualPlace: Bool) {
            if !current.isEmpty { runs.append((current, endedAtUsualPlace)) }
            current = []
        }
        for photo in tagged {
            if isUsual(photo.coordinate!) {
                close(endedAtUsualPlace: true)
                continue
            }
            if let last = current.last, photo.date.timeIntervalSince(last.date) > options.maxGap {
                close(endedAtUsualPlace: false)
            }
            current.append(photo)
        }
        close(endedAtUsualPlace: false)

        return runs
            .filter { $0.photos.count >= options.minPhotos }
            .map { run in
                let start = run.photos.first!.date, end = run.photos.last!.date
                let finished = run.endedAtUsualPlace || now.timeIntervalSince(end) > options.maxGap
                let extras = untagged.filter { $0.date >= start && $0.date <= end }
                return DetectedTrip(start: start, end: end,
                                    sites: sites(run.photos, untagged: extras, options: options),
                                    isFinished: finished)
            }
    }

    /// Grid cells with photos on enough days spread over enough months to be somewhere the
    /// photographer lives rather than visits.
    static func usualPlaces(_ photos: [TripPhoto], calendar: Calendar, options: Options) -> Set<Cell> {
        var days: [Cell: Set<Int>] = [:]
        var months: [Cell: Set<Int>] = [:]
        for photo in photos {
            guard let coordinate = photo.coordinate else { continue }
            let c = cell(coordinate, options: options)
            let parts = calendar.dateComponents([.year, .month, .day], from: photo.date)
            let month = (parts.year ?? 0) * 12 + (parts.month ?? 0)
            days[c, default: []].insert(month * 31 + (parts.day ?? 0))
            months[c, default: []].insert(month)
        }
        return Set(days.keys.filter {
            days[$0]!.count >= options.usualMinDays && months[$0]!.count >= options.usualMinMonths
        })
    }

    static func cell(_ c: Coordinate, options: Options) -> Cell {
        Cell(lat: Int((c.latitude / options.cellSize).rounded(.down)),
             lon: Int((c.longitude / options.cellSize).rounded(.down)))
    }

    /// Splits a trip's photos (capture order) into sites. A return visit to a site joins the
    /// earlier visit, so the hotel's street doesn't get picks every day.
    static func sites(_ tagged: [TripPhoto], untagged: [TripPhoto], options: Options) -> [Site] {
        struct Builder {
            var photos: [TripPhoto]
            var latSum: Double
            var lonSum: Double
            var center: Coordinate {
                Coordinate(latitude: latSum / Double(photos.count), longitude: lonSum / Double(photos.count))
            }

            init(_ photo: TripPhoto) {
                photos = [photo]
                latSum = photo.coordinate!.latitude
                lonSum = photo.coordinate!.longitude
            }

            mutating func add(_ photo: TripPhoto) {
                photos.append(photo)
                latSum += photo.coordinate!.latitude
                lonSum += photo.coordinate!.longitude
            }

            mutating func merge(_ other: Builder) {
                photos += other.photos
                latSum += other.latSum
                lonSum += other.lonSum
            }
        }

        var visits: [Builder] = []
        for photo in tagged {
            if let last = visits.last,
               photo.date.timeIntervalSince(last.photos.last!.date) <= options.siteGap,
               last.center.distance(to: photo.coordinate!) <= options.siteRadius {
                visits[visits.count - 1].add(photo)
            } else {
                visits.append(Builder(photo))
            }
        }

        var merged: [Builder] = []
        for visit in visits {
            if let i = merged.firstIndex(where: { $0.center.distance(to: visit.center) <= options.siteRadius }) {
                merged[i].merge(visit)
            } else {
                merged.append(visit)
            }
        }

        // Each geotagged photo's site, for placing photos without a location.
        var siteOf: [String: Int] = [:]
        for (i, site) in merged.enumerated() {
            for photo in site.photos { siteOf[photo.id] = i }
        }
        for photo in untagged {
            guard let nearest = nearestInTime(photo.date, in: tagged),
                  abs(nearest.date.timeIntervalSince(photo.date)) <= options.untaggedWindow,
                  let i = siteOf[nearest.id] else { continue }
            merged[i].photos.append(photo)
        }

        return merged.map { builder in
            let photos = builder.photos.sorted { $0.date < $1.date }
            return Site(photoIDs: photos.map(\.id), center: builder.center,
                        start: photos.first!.date, end: photos.last!.date)
        }
        .sorted { $0.start < $1.start }
    }

    /// `photos` must be in capture order.
    private static func nearestInTime(_ date: Date, in photos: [TripPhoto]) -> TripPhoto? {
        var low = 0, high = photos.count
        while low < high {
            let mid = (low + high) / 2
            if photos[mid].date < date { low = mid + 1 } else { high = mid }
        }
        let neighbours = [low - 1, low].filter { photos.indices.contains($0) }.map { photos[$0] }
        return neighbours.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}
