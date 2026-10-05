import Foundation
import simd

enum GeoMath {
    static let earthRadiusKm = 6371.0
    /// Light in fibre travels at ≈ c / 1.468 ≈ 204,000 km/s.
    static let fibreKmPerMs = 204.0

    static func distanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadiusKm * atan2(sqrt(a), sqrt(1 - a))
    }

    static func distanceKm(_ a: GeoInfo, _ b: GeoInfo) -> Double {
        distanceKm(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
    }

    /// Theoretical best round-trip over a great-circle fibre path.
    static func minRTTms(distanceKm d: Double) -> Double { 2 * d / fibreKmPerMs }

    /// Unit-sphere position (y up, lon 0 facing +z).
    static func unitVector(lat: Double, lon: Double) -> SIMD3<Float> {
        let la = Float(lat * .pi / 180), lo = Float(lon * .pi / 180)
        return SIMD3(cos(la) * sin(lo), sin(la), cos(la) * cos(lo))
    }
}
