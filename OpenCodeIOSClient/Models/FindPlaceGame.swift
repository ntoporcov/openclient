import CoreLocation
import Foundation

#if canImport(WeatherKit)
import WeatherKit
#endif

struct FindPlaceGameCity: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let country: String
    let latitude: Double
    let longitude: Double

    var id: String { "\(name), \(country)" }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

struct FindPlaceGameSession: Codable, Hashable, Sendable {
    let sessionID: String
    let city: FindPlaceGameCity
    var didReveal: Bool = false
}

struct FindPlaceWeatherSummary: Sendable {
    let text: String
    let errorDescription: String?
}

enum FindPlaceGame {
    static let setupMarker = "[[OPENCLIENT_FIND_PLACE_SETUP]]"
    static let winMarker = "[[OPENCLIENT_FIND_PLACE_CORRECT]]"

    static func randomCity() -> FindPlaceGameCity {
        cities.randomElement() ?? cities[0]
    }

    static func starterPrompt(city: FindPlaceGameCity, weather: FindPlaceWeatherSummary) -> String {
        let weatherDiagnostic = weather.errorDescription.map { "WeatherKit diagnostic: \($0)" } ?? "WeatherKit diagnostic: success"

        return """
        \(setupMarker)
        <!-- \(weatherDiagnostic) -->

        We are playing a private OpenClient game called Find the Place.

        Secret city: \(city.name), \(city.country)
        Coordinates: \(city.latitude), \(city.longitude)
        Current clue: \(weather.text)

        Rules you must follow exactly:
        - Do not reveal the secret city or country until the user guesses it.
        - Start by briefly explaining that you are thinking of a city and that the user should guess it from weather/location clues.
        - You may give the weather clue and broad non-identifying hints.
        - Until the user guesses correctly, answer direct guesses with only "Yes" or "No" plus at most one short clue sentence.
        - Accept minor typos, missing accents, and close spellings as correct.
        - When the user guesses correctly, reply with exactly this marker and no other text: \(winMarker)
        """
    }

    static let cities: [FindPlaceGameCity] = [
        FindPlaceGameCity(name: "New York", country: "United States", latitude: 40.7128, longitude: -74.0060),
        FindPlaceGameCity(name: "Los Angeles", country: "United States", latitude: 34.0522, longitude: -118.2437),
        FindPlaceGameCity(name: "Chicago", country: "United States", latitude: 41.8781, longitude: -87.6298),
        FindPlaceGameCity(name: "Miami", country: "United States", latitude: 25.7617, longitude: -80.1918),
        FindPlaceGameCity(name: "San Francisco", country: "United States", latitude: 37.7749, longitude: -122.4194),
        FindPlaceGameCity(name: "Las Vegas", country: "United States", latitude: 36.1699, longitude: -115.1398),
        FindPlaceGameCity(name: "London", country: "United Kingdom", latitude: 51.5072, longitude: -0.1276),
        FindPlaceGameCity(name: "Paris", country: "France", latitude: 48.8566, longitude: 2.3522),
        FindPlaceGameCity(name: "Rome", country: "Italy", latitude: 41.9028, longitude: 12.4964),
        FindPlaceGameCity(name: "Barcelona", country: "Spain", latitude: 41.3874, longitude: 2.1686),
        FindPlaceGameCity(name: "Madrid", country: "Spain", latitude: 40.4168, longitude: -3.7038),
        FindPlaceGameCity(name: "Amsterdam", country: "Netherlands", latitude: 52.3676, longitude: 4.9041),
        FindPlaceGameCity(name: "Berlin", country: "Germany", latitude: 52.5200, longitude: 13.4050),
        FindPlaceGameCity(name: "Athens", country: "Greece", latitude: 37.9838, longitude: 23.7275),
        FindPlaceGameCity(name: "Istanbul", country: "Turkey", latitude: 41.0082, longitude: 28.9784),
        FindPlaceGameCity(name: "Dubai", country: "United Arab Emirates", latitude: 25.2048, longitude: 55.2708),
        FindPlaceGameCity(name: "Cairo", country: "Egypt", latitude: 30.0444, longitude: 31.2357),
        FindPlaceGameCity(name: "Cape Town", country: "South Africa", latitude: -33.9249, longitude: 18.4241),
        FindPlaceGameCity(name: "Tokyo", country: "Japan", latitude: 35.6762, longitude: 139.6503),
        FindPlaceGameCity(name: "Kyoto", country: "Japan", latitude: 35.0116, longitude: 135.7681),
        FindPlaceGameCity(name: "Seoul", country: "South Korea", latitude: 37.5665, longitude: 126.9780),
        FindPlaceGameCity(name: "Beijing", country: "China", latitude: 39.9042, longitude: 116.4074),
        FindPlaceGameCity(name: "Shanghai", country: "China", latitude: 31.2304, longitude: 121.4737),
        FindPlaceGameCity(name: "Hong Kong", country: "China", latitude: 22.3193, longitude: 114.1694),
        FindPlaceGameCity(name: "Singapore", country: "Singapore", latitude: 1.3521, longitude: 103.8198),
        FindPlaceGameCity(name: "Bangkok", country: "Thailand", latitude: 13.7563, longitude: 100.5018),
        FindPlaceGameCity(name: "Sydney", country: "Australia", latitude: -33.8688, longitude: 151.2093),
        FindPlaceGameCity(name: "Melbourne", country: "Australia", latitude: -37.8136, longitude: 144.9631),
        FindPlaceGameCity(name: "Auckland", country: "New Zealand", latitude: -36.8509, longitude: 174.7645),
        FindPlaceGameCity(name: "Toronto", country: "Canada", latitude: 43.6532, longitude: -79.3832),
        FindPlaceGameCity(name: "Vancouver", country: "Canada", latitude: 49.2827, longitude: -123.1207),
        FindPlaceGameCity(name: "Mexico City", country: "Mexico", latitude: 19.4326, longitude: -99.1332),
        FindPlaceGameCity(name: "Rio de Janeiro", country: "Brazil", latitude: -22.9068, longitude: -43.1729),
        FindPlaceGameCity(name: "Buenos Aires", country: "Argentina", latitude: -34.6037, longitude: -58.3816),
        FindPlaceGameCity(name: "Lima", country: "Peru", latitude: -12.0464, longitude: -77.0428),
        FindPlaceGameCity(name: "Machu Picchu", country: "Peru", latitude: -13.1631, longitude: -72.5450),
        FindPlaceGameCity(name: "Honolulu", country: "United States", latitude: 21.3099, longitude: -157.8581),
        FindPlaceGameCity(name: "Reykjavik", country: "Iceland", latitude: 64.1466, longitude: -21.9426),
        FindPlaceGameCity(name: "Venice", country: "Italy", latitude: 45.4408, longitude: 12.3155),
        FindPlaceGameCity(name: "Marrakesh", country: "Morocco", latitude: 31.6295, longitude: -7.9811)
    ]
}

enum FindPlaceWeatherProvider {
    static func summary(for city: FindPlaceGameCity) async -> FindPlaceWeatherSummary {
#if canImport(WeatherKit)
        if #available(iOS 16.0, *) {
            do {
                let weather = try await WeatherService.shared.weather(for: CLLocation(latitude: city.latitude, longitude: city.longitude))
                let current = weather.currentWeather
                let celsius = current.temperature.converted(to: .celsius).value
                let fahrenheit = current.temperature.converted(to: .fahrenheit).value
                let windKPH = current.wind.speed.converted(to: .kilometersPerHour).value
                let humidity = Int((current.humidity * 100).rounded())
                let text = String(
                    format: "%.0f°C / %.0f°F, %@, humidity %d%%, wind %.0f km/h",
                    celsius,
                    fahrenheit,
                    String(describing: current.condition),
                    humidity,
                    windKPH
                )
                return FindPlaceWeatherSummary(text: text, errorDescription: nil)
            } catch {
                return fallbackSummary(for: city, error: error)
            }
        }
#endif
        return fallbackSummary(for: city, error: nil)
    }

    private static func fallbackSummary(for city: FindPlaceGameCity, error: Error?) -> FindPlaceWeatherSummary {
        let hemisphere = city.latitude >= 0 ? "Northern Hemisphere" : "Southern Hemisphere"
        let zone: String
        switch abs(city.latitude) {
        case 0..<23.5:
            zone = "tropical latitude"
        case 23.5..<45:
            zone = "temperate/subtropical latitude"
        default:
            zone = "cooler high-latitude region"
        }
        let description = error.map { String(describing: $0) }
        return FindPlaceWeatherSummary(text: "Location clue: \(zone) in the \(hemisphere).", errorDescription: description)
    }
}
