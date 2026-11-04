import CoreLocation
import MapKit
import TripKit

/// Reverse geocodes site centres, remembering the answers so each place is looked up once per
/// launch. Apple throttles apps that look up too many places in a short time.
@MainActor
final class PlaceNames {
    static let shared = PlaceNames()

    struct Place: Sendable {
        /// The point of interest or street, e.g. "Belém Tower".
        let name: String?
        /// e.g. "Lisbon".
        let city: String?
    }

    private var cache: [String: Place] = [:]

    func place(at coordinate: Coordinate) async -> Place? {
        // About 100 m, so nearby sites share a lookup.
        let key = String(format: "%.3f,%.3f", coordinate.latitude, coordinate.longitude)
        if let cached = cache[key] { return cached }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return nil }
        let representations = item.addressRepresentations
        let place = Place(name: item.name, city: representations?.cityName ?? representations?.regionName)
        cache[key] = place
        return place
    }
}
