import XCTest
@testable import TripKit

final class TripDetectorTests: XCTestCase {
    private let home = Coordinate(latitude: 39.7392, longitude: -104.9903) // Denver
    private let lisbon = Coordinate(latitude: 38.6916, longitude: -9.2160) // Belém
    private let sintra = Coordinate(latitude: 38.7876, longitude: -9.3906)
    private let day: TimeInterval = 24 * 60 * 60
    private let base = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private var nextID = 0
    private func photo(_ coordinate: Coordinate?, _ date: Date) -> TripPhoto {
        nextID += 1
        return TripPhoto(id: "p\(nextID)", date: date, coordinate: coordinate)
    }

    /// A couple of photos at home every few days over several months.
    private func homeLife(days: ClosedRange<Int>) -> [TripPhoto] {
        stride(from: days.lowerBound, through: days.upperBound, by: 3).flatMap { d in
            [photo(home, base + Double(d) * day + 3600), photo(home, base + Double(d) * day + 7200)]
        }
    }

    /// `count` photos a minute apart starting at `start`, wobbling a few metres around `place`.
    private func burst(_ place: Coordinate, at start: Date, count: Int) -> [TripPhoto] {
        (0..<count).map { i in
            let wobble = Double(i % 3) * 0.0001
            return photo(Coordinate(latitude: place.latitude + wobble, longitude: place.longitude),
                         start + Double(i) * 60)
        }
    }

    func testTripBetweenStaysAtHome() {
        let tripStart = base + 100 * day
        var photos = homeLife(days: 0...99) + homeLife(days: 104...150)
        photos += burst(lisbon, at: tripStart, count: 10)
        photos += burst(sintra, at: tripStart + day, count: 8)
        photos += burst(lisbon, at: tripStart + 2 * day, count: 5)

        let trips = TripDetector.trips(photos, now: base + 200 * day, calendar: calendar)

        XCTAssertEqual(trips.count, 1)
        let trip = trips[0]
        XCTAssertTrue(trip.isFinished)
        XCTAssertEqual(trip.photoIDs.count, 23)
        // The return to Belém joins the first visit.
        XCTAssertEqual(trip.sites.count, 2)
        XCTAssertEqual(trip.sites[0].photoIDs.count, 15)
        XCTAssertEqual(trip.sites[1].photoIDs.count, 8)
    }

    func testTripStillGoingIsNotFinished() {
        let tripStart = base + 100 * day
        let photos = homeLife(days: 0...99) + burst(lisbon, at: tripStart, count: 15)

        let trips = TripDetector.trips(photos, now: tripStart + day, calendar: calendar)

        XCTAssertEqual(trips.count, 1)
        XCTAssertFalse(trips[0].isFinished)
        XCTAssertTrue(TripDetector.trips(photos, now: tripStart + 5 * day, calendar: calendar)[0].isFinished)
    }

    func testFewPhotosAwayIsNotATrip() {
        let photos = homeLife(days: 0...99) + burst(lisbon, at: base + 50 * day, count: 5)
        XCTAssertTrue(TripDetector.trips(photos, now: base + 200 * day, calendar: calendar).isEmpty)
    }

    func testLongGapSplitsTrips() {
        var photos = homeLife(days: 0...99)
        photos += burst(lisbon, at: base + 100 * day, count: 15)
        photos += burst(lisbon, at: base + 110 * day, count: 15)

        XCTAssertEqual(TripDetector.trips(photos, now: base + 200 * day, calendar: calendar).count, 2)
    }

    func testNearbyNeighbourhoodCountsAsHome() {
        // About 8 km from home, likely in a neighbouring grid cell.
        let nearby = Coordinate(latitude: home.latitude + 0.07, longitude: home.longitude)
        let photos = homeLife(days: 0...99) + burst(nearby, at: base + 50 * day, count: 20)
        XCTAssertTrue(TripDetector.trips(photos, now: base + 200 * day, calendar: calendar).isEmpty)
    }

    func testLongStayElsewhereDoesNotBecomeHome() {
        // Three weeks away, photos every day, but within a single month.
        var photos = homeLife(days: 0...99)
        for d in 0..<21 {
            photos += burst(lisbon, at: base + Double(100 + d) * day, count: 2)
        }
        photos += homeLife(days: 125...150)

        let trips = TripDetector.trips(photos, now: base + 200 * day, calendar: calendar)
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips[0].photoIDs.count, 42)
    }

    func testUntaggedPhotosJoinNearbySite() {
        let tripStart = base + 100 * day
        var photos = homeLife(days: 0...99) + burst(lisbon, at: tripStart, count: 15)
        let camera = photo(nil, tripStart + 5 * 60)
        let stray = photo(nil, tripStart + 6 * 3600)
        photos += [camera, stray] + burst(sintra, at: tripStart + 12 * 3600, count: 2)

        let trip = TripDetector.trips(photos, now: base + 200 * day, calendar: calendar)[0]
        XCTAssertTrue(trip.sites[0].photoIDs.contains(camera.id))
        XCTAssertFalse(trip.photoIDs.contains(stray.id))
    }

    func testMovingOnStartsNewSite() {
        let tripStart = base + 100 * day
        let farther = Coordinate(latitude: lisbon.latitude + 0.02, longitude: lisbon.longitude) // ~2 km
        let photos = homeLife(days: 0...99)
            + burst(lisbon, at: tripStart, count: 8)
            + burst(farther, at: tripStart + 1800, count: 8)

        let trip = TripDetector.trips(photos, now: base + 200 * day, calendar: calendar)[0]
        XCTAssertEqual(trip.sites.count, 2)
    }
}

