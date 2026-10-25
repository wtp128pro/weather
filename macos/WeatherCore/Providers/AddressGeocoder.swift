// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AddressGeocoder.swift - multi-source street address, landmark, postal code,
// coordinate, and city geocoder. Combines Apple CoreLocation/MapKit (CLGeocoder
// & MKLocalSearch), OpenStreetMap Photon & Nominatim, US Census Bureau TIGER/Line
// street-address geocoding, direct (lat, lon) coordinate parsing, and Open-Meteo
// city search into validated `WxPlace` instances with street-level coordinates.

import CoreLocation
import Foundation
import MapKit

/// A resolved street address, point of interest, postal code, coordinate, or city.
public struct WxAddressCandidate: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case streetAddress
        case pointOfInterest
        case postalCode
        case coordinates
        case city
    }

    public let id: String
    /// Primary street address, building, landmark, or city title (e.g. "1600 Pennsylvania Ave NW").
    public let primaryTitle: String
    /// Secondary locality/region/postal subtitle (e.g. "Washington, DC 20500, United States").
    public let subtitle: String
    /// Full formatted address excluding custom label (e.g. "1600 Pennsylvania Ave NW, Washington, DC 20500").
    public let fullAddress: String
    /// Underlying validated `WxPlace` ready to be added (or customized with a user label).
    public let place: WxPlace
    /// Classification of the geocoded result.
    public let kind: Kind

    public init(
        id: String? = nil,
        primaryTitle: String,
        subtitle: String,
        fullAddress: String,
        place: WxPlace,
        kind: Kind
    ) {
        self.id = id ?? "\(place.key)|\(primaryTitle)|\(subtitle)"
        self.primaryTitle = primaryTitle
        self.subtitle = subtitle
        self.fullAddress = fullAddress
        self.place = place
        self.kind = kind
    }

    /// Returns a `WxPlace` configured with the user's optional custom label (e.g. "Home", "Work", "Friend's place").
    public func makePlace(customName: String?) -> WxPlace {
        let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isCustom = kind != .city || !trimmed.isEmpty
        if !isCustom {
            return place
        }
        return (try? place.withCustomLocation(
            customName: trimmed.isEmpty ? nil : trimmed,
            streetAddress: fullAddress,
            isCustomLocation: true
        )) ?? place
    }
}

/// Multi-source address & location geocoder.
public enum WxAddressGeocoder {
    /// Preset location names for quick one-click labeling.
    public static let presetLocationNames: [(label: String, symbol: String)] = [
        ("Home", "house.fill"),
        ("Work", "briefcase.fill"),
        ("Friend's place", "person.2.fill"),
        ("Family", "heart.fill"),
        ("School", "graduationcap.fill"),
        ("Gym", "dumbbell.fill"),
        ("Vacation", "sun.max.fill"),
    ]

    /// Searches for street addresses, buildings/POIs, postal codes, coordinates, and cities matching `rawQuery`.
    public static func search(
        query rawQuery: String,
        cityFallback: (@Sendable (String) async throws -> [WxPlace])? = nil
    ) async -> [WxAddressCandidate] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.utf8.count >= 2 else { return [] }

        // 1. Check if the user typed raw coordinates like "25.7617, -80.1918".
        let coordCandidate = await parseDirectCoordinates(query)

        // 2. Run street-address & city geocoders in parallel.
        async let mapKitTask = searchMapKit(query: query)
        async let nominatimTask = searchNominatim(query: query)
        async let photonTask = searchPhoton(query: query)
        async let censusTask = searchUSCensus(query: query)
        async let citiesTask: [WxPlace] = {
            guard let cityFallback else { return [] }
            let clipped = String(query.prefix(64))
            return (try? await cityFallback(clipped)) ?? []
        }()

        let (mkResults, nomResults, photonResults, censusResults, cityPlaces) = await (
            mapKitTask, nominatimTask, photonTask, censusTask, citiesTask
        )

        // Collect known timezones by proximity so Nominatim/Photon/Census hits get an exact IANA timezone.
        let knownTimezones: [(lat: Double, lon: Double, tz: String)] = (
            mkResults.map { ($0.place.lat, $0.place.lon, $0.place.timezone) }
            + cityPlaces.map { ($0.lat, $0.lon, $0.timezone) }
        ).filter { !$0.tz.isEmpty }

        var combined: [WxAddressCandidate] = []
        if let coordCandidate {
            combined.append(coordCandidate)
        }

        // Prioritize US Census rooftop/parcel matches and MapKit street addresses when the query starts with a street number.
        let startsWithStreetNumber = query.first?.isNumber == true
        if startsWithStreetNumber {
            combined.append(contentsOf: censusResults)
            combined.append(contentsOf: mkResults)
            combined.append(contentsOf: nomResults)
            combined.append(contentsOf: photonResults)
        } else {
            combined.append(contentsOf: mkResults)
            combined.append(contentsOf: nomResults)
            combined.append(contentsOf: photonResults)
            combined.append(contentsOf: censusResults)
        }

        for city in cityPlaces {
            let subParts = [city.admin1, city.country].filter { !$0.isEmpty }
            let fullAddr = [city.name, city.admin1].filter { !$0.isEmpty }.joined(separator: ", ")
            combined.append(
                WxAddressCandidate(
                    primaryTitle: city.name,
                    subtitle: subParts.joined(separator: ", "),
                    fullAddress: fullAddr,
                    place: city,
                    kind: .city
                )
            )
        }

        // Fill any missing IANA timezones and deduplicate by proximity + title.
        var deduplicated: [WxAddressCandidate] = []
        for item in combined {
            if Task.isCancelled { return [] }
            var resolved = item
            if resolved.place.timezone.isEmpty {
                let tz = resolveTimezone(
                    lat: resolved.place.lat,
                    lon: resolved.place.lon,
                    countryCode: resolved.place.countryCode,
                    admin1: resolved.place.admin1,
                    known: knownTimezones
                )
                if !tz.isEmpty,
                   let withTZ = try? WxPlace(
                       name: resolved.place.name,
                       admin1: resolved.place.admin1.isEmpty ? nil : resolved.place.admin1,
                       country: resolved.place.country.isEmpty ? nil : resolved.place.country,
                       countryCode: resolved.place.countryCode.isEmpty ? nil : resolved.place.countryCode,
                       lat: resolved.place.lat,
                       lon: resolved.place.lon,
                       timezone: tz
                   )
                {
                    var updatedPlace = withTZ
                    updatedPlace.isCustomLocation = resolved.place.isCustomLocation
                    updatedPlace.customName = resolved.place.customName
                    updatedPlace.streetAddress = resolved.place.streetAddress
                    resolved = WxAddressCandidate(
                        id: resolved.id,
                        primaryTitle: resolved.primaryTitle,
                        subtitle: resolved.subtitle,
                        fullAddress: resolved.fullAddress,
                        place: updatedPlace,
                        kind: resolved.kind
                    )
                }
            }

            let isDup = deduplicated.contains { existing in
                let distKm = WxGeo.distanceKm(
                    aLat: existing.place.lat,
                    aLon: existing.place.lon,
                    bLat: resolved.place.lat,
                    bLon: resolved.place.lon
                )
                if distKm < 0.15
                    && existing.primaryTitle.caseInsensitiveCompare(resolved.primaryTitle) == .orderedSame
                {
                    return true
                }
                if existing.kind == .city && resolved.kind == .city && distKm < 5.0
                    && existing.primaryTitle.caseInsensitiveCompare(resolved.primaryTitle) == .orderedSame
                {
                    return true
                }
                return false
            }
            if !isDup {
                deduplicated.append(resolved)
            }
            if deduplicated.count >= 20 {
                break
            }
        }

        return deduplicated
    }

    // MARK: - 1. Direct Coordinate Parsing ("25.7617, -80.1918")

    private static func parseDirectCoordinates(_ query: String) async -> WxAddressCandidate? {
        let cleaned = query
            .replacingOccurrences(of: "°", with: " ")
            .replacingOccurrences(of: ",", with: " ")
        let tokens = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count == 2,
              let lat = Double(tokens[0]),
              let lon = Double(tokens[1]),
              WxGeo.isValid(lat: lat, lon: lon)
        else {
            return nil
        }

        let coordTitle = String(format: "%.4f, %.4f", lat, lon)
        if let reversed = await reverseGeocodeNominatim(lat: lat, lon: lon) {
            return reversed
        }

        let tz = inferFallbackTimezone(lat: lat, lon: lon, countryCode: "", admin1: "")
        guard var place = try? WxPlace(
            name: coordTitle,
            admin1: "Coordinates",
            country: nil,
            countryCode: nil,
            lat: lat,
            lon: lon,
            timezone: tz
        ) else {
            return nil
        }
        place.isCustomLocation = true
        place.streetAddress = coordTitle
        return WxAddressCandidate(
            primaryTitle: coordTitle,
            subtitle: "Exact coordinates",
            fullAddress: coordTitle,
            place: place,
            kind: .coordinates
        )
    }

    private static func reverseGeocodeNominatim(lat: Double, lon: Double) async -> WxAddressCandidate? {
        let urlStr = String(
            format: "https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=%.5f&lon=%.5f&addressdetails=1&accept-language=en",
            lat, lon
        )
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("WeatherApp/1.0 (macOS; address-geocoder)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 3.0
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let item = try JSONDecoder().decode(NominatimItem.self, from: data)
            return buildNominatimCandidate(item, overrideLat: lat, overrideLon: lon)
        } catch {
            return nil
        }
    }

    // MARK: - 2. Apple MapKit / CLGeocoder Street Address & POI Search

    private static func searchMapKit(query: String) async -> [WxAddressCandidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            var out: [WxAddressCandidate] = []
            for item in response.mapItems.prefix(10) {
                if let candidate = candidateFromMapItem(item) {
                    out.append(candidate)
                }
            }
            return out
        } catch {
            return []
        }
    }

    private static func candidateFromMapItem(_ item: MKMapItem) -> WxAddressCandidate? {
        let coord = item.location.coordinate
        guard WxGeo.isValid(lat: coord.latitude, lon: coord.longitude) else { return nil }

        let reps = item.addressRepresentations
        let shortAddr = item.address?.shortAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fullSingleLine = reps?.fullAddress(includingRegion: true, singleLine: true)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? item.address?.fullAddress
                .replacingOccurrences(of: "\n", with: ", ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        let locality = reps?.cityName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cityWithContext = reps?.cityWithContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let country = reps?.regionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cc = (reps?.region?.identifier ?? "").uppercased()

        // Extract street line from shortAddress or first comma component of fullSingleLine
        let firstSegment = fullSingleLine.split(separator: ",").first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        let shortFirstSegment = shortAddr.split(separator: ",").first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        let streetCandidate = !shortFirstSegment.isEmpty ? shortFirstSegment : firstSegment
        let streetLine = (streetCandidate.caseInsensitiveCompare(locality) != .orderedSame
            && streetCandidate.caseInsensitiveCompare(country) != .orderedSame)
            ? streetCandidate
            : ""

        let itemName = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let primary: String
        let kind: WxAddressCandidate.Kind
        if !streetLine.isEmpty {
            if !itemName.isEmpty
                && itemName.caseInsensitiveCompare(streetLine) != .orderedSame
                && itemName.caseInsensitiveCompare(locality) != .orderedSame
            {
                primary = "\(itemName) (\(streetLine))"
                kind = .pointOfInterest
            } else {
                primary = streetLine
                kind = .streetAddress
            }
        } else if !itemName.isEmpty && itemName.caseInsensitiveCompare(locality) != .orderedSame {
            primary = itemName
            kind = .pointOfInterest
        } else if !locality.isEmpty {
            primary = locality
            kind = .city
        } else {
            return nil
        }

        let contextLocality: String = {
            if !cityWithContext.isEmpty && cityWithContext.caseInsensitiveCompare(primary) != .orderedSame {
                return cityWithContext
            }
            if !locality.isEmpty && locality.caseInsensitiveCompare(primary) != .orderedSame {
                return locality
            }
            let remaining = fullSingleLine
                .split(separator: ",")
                .dropFirst()
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.caseInsensitiveCompare(country) != .orderedSame }
                .joined(separator: ", ")
            return remaining
        }()

        let admin1Text = contextLocality
        var subtitleParts: [String] = []
        if !admin1Text.isEmpty {
            subtitleParts.append(admin1Text)
        }
        if !country.isEmpty && !admin1Text.localizedCaseInsensitiveContains(country) {
            subtitleParts.append(country)
        }
        let subtitle = subtitleParts.joined(separator: ", ")
        let fullAddress = [primary, admin1Text].filter { !$0.isEmpty }.joined(separator: ", ")

        let tzID = item.timeZone?.identifier ?? ""
        let cleanPrimary = WxText.sanitize(primary, maxBytes: WxLimits.placeNameMax)
        let cleanAdmin1 = WxText.sanitize(admin1Text, maxBytes: WxLimits.placeNameMax)
        let cleanCountry = WxText.sanitize(country, maxBytes: WxLimits.placeNameMax)
        let validCC = (cc.count == 2 && cc.allSatisfy { $0.isASCII && $0.isUppercase }) ? cc : nil

        guard var place = try? WxPlace(
            name: cleanPrimary,
            admin1: cleanAdmin1.isEmpty ? nil : cleanAdmin1,
            country: cleanCountry.isEmpty ? nil : cleanCountry,
            countryCode: validCC,
            lat: coord.latitude,
            lon: coord.longitude,
            timezone: tzID.isEmpty ? nil : tzID
        ) else {
            return nil
        }
        place.isCustomLocation = kind != .city
        place.streetAddress = WxText.sanitize(fullAddress, maxBytes: WxLimits.placeNameMax)

        return WxAddressCandidate(
            primaryTitle: cleanPrimary,
            subtitle: subtitle,
            fullAddress: place.streetAddress,
            place: place,
            kind: kind
        )
    }

    // MARK: - 3. OpenStreetMap Nominatim Address Search

    private struct NominatimItem: Decodable {
        struct Address: Decodable {
            let house_number: String?
            let road: String?
            let pedestrian: String?
            let suburb: String?
            let neighbourhood: String?
            let city: String?
            let town: String?
            let village: String?
            let municipality: String?
            let county: String?
            let state: String?
            let postcode: String?
            let country: String?
            let country_code: String?
        }
        let lat: String?
        let lon: String?
        let name: String?
        let display_name: String?
        let category: String?
        let type: String?
        let address: Address?
    }

    private static func searchNominatim(query: String) async -> [WxAddressCandidate] {
        guard let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://nominatim.openstreetmap.org/search?q=\(escaped)&format=jsonv2&addressdetails=1&limit=8&accept-language=en")
        else {
            return []
        }
        var req = URLRequest(url: url)
        req.setValue("WeatherApp/1.0 (macOS; address-geocoder)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 3.5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let items = try JSONDecoder().decode([NominatimItem].self, from: data)
            return items.compactMap { buildNominatimCandidate($0) }
        } catch {
            return []
        }
    }

    private static func buildNominatimCandidate(
        _ item: NominatimItem,
        overrideLat: Double? = nil,
        overrideLon: Double? = nil
    ) -> WxAddressCandidate? {
        guard let lat = overrideLat ?? item.lat.flatMap(Double.init),
              let lon = overrideLon ?? item.lon.flatMap(Double.init),
              WxGeo.isValid(lat: lat, lon: lon)
        else {
            return nil
        }
        let addr = item.address
        let house = addr?.house_number?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let road = (addr?.road ?? addr?.pedestrian ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let streetLine = [house, road].filter { !$0.isEmpty }.joined(separator: " ")

        let city = (addr?.city ?? addr?.town ?? addr?.village ?? addr?.municipality ?? addr?.suburb ?? addr?.county ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let state = (addr?.state ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let postcode = (addr?.postcode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let country = (addr?.country ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cc = (addr?.country_code ?? "").uppercased()

        let rawName = (item.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let primary: String
        let kind: WxAddressCandidate.Kind
        if !streetLine.isEmpty {
            if !rawName.isEmpty
                && rawName.caseInsensitiveCompare(road) != .orderedSame
                && rawName.caseInsensitiveCompare(streetLine) != .orderedSame
                && rawName.caseInsensitiveCompare(city) != .orderedSame
            {
                primary = "\(rawName), \(streetLine)"
                kind = .pointOfInterest
            } else {
                primary = streetLine
                kind = .streetAddress
            }
        } else if !rawName.isEmpty && rawName.caseInsensitiveCompare(city) != .orderedSame {
            primary = rawName
            kind = (item.type == "postcode" || item.category == "Boundary") ? .postalCode : .pointOfInterest
        } else if !city.isEmpty {
            primary = city
            kind = .city
        } else if let firstDisplay = item.display_name?.split(separator: ",").first {
            primary = String(firstDisplay).trimmingCharacters(in: .whitespacesAndNewlines)
            kind = .streetAddress
        } else {
            return nil
        }

        let statePostal = [state, postcode].filter { !$0.isEmpty }.joined(separator: " ")
        var adminParts: [String] = []
        if !city.isEmpty && city.caseInsensitiveCompare(primary) != .orderedSame {
            adminParts.append(city)
        }
        if !statePostal.isEmpty {
            adminParts.append(statePostal)
        }
        let admin1Text = adminParts.joined(separator: ", ")
        var subtitleParts = adminParts
        if !country.isEmpty {
            subtitleParts.append(country)
        }
        let subtitle = subtitleParts.joined(separator: ", ")
        let fullAddress = [primary, admin1Text].filter { !$0.isEmpty }.joined(separator: ", ")

        let cleanPrimary = WxText.sanitize(primary, maxBytes: WxLimits.placeNameMax)
        let cleanAdmin1 = WxText.sanitize(admin1Text, maxBytes: WxLimits.placeNameMax)
        let cleanCountry = WxText.sanitize(country, maxBytes: WxLimits.placeNameMax)
        let validCC = (cc.count == 2 && cc.allSatisfy { $0.isASCII && $0.isUppercase }) ? cc : nil
        let tz = inferFallbackTimezone(lat: lat, lon: lon, countryCode: validCC ?? "", admin1: state)

        guard var place = try? WxPlace(
            name: cleanPrimary,
            admin1: cleanAdmin1.isEmpty ? nil : cleanAdmin1,
            country: cleanCountry.isEmpty ? nil : cleanCountry,
            countryCode: validCC,
            lat: lat,
            lon: lon,
            timezone: tz.isEmpty ? nil : tz
        ) else {
            return nil
        }
        place.isCustomLocation = kind != .city
        place.streetAddress = WxText.sanitize(fullAddress, maxBytes: WxLimits.placeNameMax)

        return WxAddressCandidate(
            primaryTitle: cleanPrimary,
            subtitle: subtitle,
            fullAddress: place.streetAddress,
            place: place,
            kind: kind
        )
    }

    // MARK: - 4. OpenStreetMap Photon Geocoder (komoot)

    private struct PhotonResponse: Decodable {
        struct Feature: Decodable {
            struct Geometry: Decodable {
                let coordinates: [Double]?
            }
            struct Properties: Decodable {
                let name: String?
                let housenumber: String?
                let street: String?
                let district: String?
                let city: String?
                let state: String?
                let postcode: String?
                let country: String?
                let countrycode: String?
                let osm_value: String?
            }
            let geometry: Geometry?
            let properties: Properties?
        }
        let features: [Feature]?
    }

    private static func searchPhoton(query: String) async -> [WxAddressCandidate] {
        guard let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://photon.komoot.io/api/?q=\(escaped)&limit=8&lang=en")
        else {
            return []
        }
        var req = URLRequest(url: url)
        req.setValue("WeatherApp/1.0 (macOS; address-geocoder)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 3.5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode(PhotonResponse.self, from: data)
            return (decoded.features ?? []).compactMap { f in
                guard let coords = f.geometry?.coordinates, coords.count >= 2,
                      let props = f.properties
                else {
                    return nil
                }
                let lon = coords[0]
                let lat = coords[1]
                guard WxGeo.isValid(lat: lat, lon: lon) else { return nil }

                let house = props.housenumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let street = props.street?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let streetLine = [house, street].filter { !$0.isEmpty }.joined(separator: " ")
                let city = (props.city ?? props.district ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let state = (props.state ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let postcode = (props.postcode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let country = (props.country ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let cc = (props.countrycode ?? "").uppercased()
                let name = (props.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                let primary: String
                let kind: WxAddressCandidate.Kind
                if !streetLine.isEmpty {
                    primary = (!name.isEmpty && name.caseInsensitiveCompare(street) != .orderedSame && name.caseInsensitiveCompare(city) != .orderedSame)
                        ? "\(name), \(streetLine)"
                        : streetLine
                    kind = .streetAddress
                } else if !name.isEmpty && name.caseInsensitiveCompare(city) != .orderedSame {
                    primary = name
                    kind = .pointOfInterest
                } else if !city.isEmpty {
                    primary = city
                    kind = .city
                } else {
                    return nil
                }

                let statePostal = [state, postcode].filter { !$0.isEmpty }.joined(separator: " ")
                var adminParts: [String] = []
                if !city.isEmpty && city.caseInsensitiveCompare(primary) != .orderedSame {
                    adminParts.append(city)
                }
                if !statePostal.isEmpty {
                    adminParts.append(statePostal)
                }
                let admin1Text = adminParts.joined(separator: ", ")
                var subtitleParts = adminParts
                if !country.isEmpty {
                    subtitleParts.append(country)
                }
                let subtitle = subtitleParts.joined(separator: ", ")
                let fullAddress = [primary, admin1Text].filter { !$0.isEmpty }.joined(separator: ", ")

                let cleanPrimary = WxText.sanitize(primary, maxBytes: WxLimits.placeNameMax)
                let cleanAdmin1 = WxText.sanitize(admin1Text, maxBytes: WxLimits.placeNameMax)
                let cleanCountry = WxText.sanitize(country, maxBytes: WxLimits.placeNameMax)
                let validCC = (cc.count == 2 && cc.allSatisfy { $0.isASCII && $0.isUppercase }) ? cc : nil
                let tz = inferFallbackTimezone(lat: lat, lon: lon, countryCode: validCC ?? "", admin1: state)

                guard var place = try? WxPlace(
                    name: cleanPrimary,
                    admin1: cleanAdmin1.isEmpty ? nil : cleanAdmin1,
                    country: cleanCountry.isEmpty ? nil : cleanCountry,
                    countryCode: validCC,
                    lat: lat,
                    lon: lon,
                    timezone: tz.isEmpty ? nil : tz
                ) else {
                    return nil
                }
                place.isCustomLocation = kind != .city
                place.streetAddress = WxText.sanitize(fullAddress, maxBytes: WxLimits.placeNameMax)

                return WxAddressCandidate(
                    primaryTitle: cleanPrimary,
                    subtitle: subtitle,
                    fullAddress: place.streetAddress,
                    place: place,
                    kind: kind
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - 5. US Census Bureau Street Address Geocoder

    private struct CensusResponse: Decodable {
        struct Result: Decodable {
            struct AddressMatch: Decodable {
                struct Coordinates: Decodable {
                    let x: Double?
                    let y: Double?
                }
                struct AddressComponents: Decodable {
                    let city: String?
                    let state: String?
                    let zip: String?
                }
                let matchedAddress: String?
                let coordinates: Coordinates?
                let addressComponents: AddressComponents?
            }
            let addressMatches: [AddressMatch]?
        }
        let result: Result?
    }

    private static func searchUSCensus(query: String) async -> [WxAddressCandidate] {
        // US Census geocoder requires a street address (typically starting with a house number).
        guard query.first?.isNumber == true,
              query.contains(" "),
              let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding.geo.census.gov/geocoder/locations/onelineaddress?address=\(escaped)&benchmark=Public_AR_Current&format=json")
        else {
            return []
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode(CensusResponse.self, from: data)
            return (decoded.result?.addressMatches ?? []).prefix(5).compactMap { match in
                guard let lon = match.coordinates?.x,
                      let lat = match.coordinates?.y,
                      WxGeo.isValid(lat: lat, lon: lon),
                      let matched = match.matchedAddress
                else {
                    return nil
                }
                let parts = matched.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let streetPart = Self.titleCaseAddress(parts.first ?? matched)
                let city = Self.titleCaseAddress(match.addressComponents?.city ?? (parts.count > 1 ? parts[1] : ""))
                let state = (match.addressComponents?.state ?? "").uppercased()
                let zip = match.addressComponents?.zip ?? ""
                let stateZip = [state, zip].filter { !$0.isEmpty }.joined(separator: " ")
                let admin1Text = [city, stateZip].filter { !$0.isEmpty }.joined(separator: ", ")
                let subtitle = [admin1Text, "United States"].filter { !$0.isEmpty }.joined(separator: ", ")
                let fullAddress = [streetPart, admin1Text].filter { !$0.isEmpty }.joined(separator: ", ")
                let tz = inferFallbackTimezone(lat: lat, lon: lon, countryCode: "US", admin1: state)

                let cleanPrimary = WxText.sanitize(streetPart, maxBytes: WxLimits.placeNameMax)
                let cleanAdmin1 = WxText.sanitize(admin1Text, maxBytes: WxLimits.placeNameMax)
                guard var place = try? WxPlace(
                    name: cleanPrimary,
                    admin1: cleanAdmin1.isEmpty ? nil : cleanAdmin1,
                    country: "United States",
                    countryCode: "US",
                    lat: lat,
                    lon: lon,
                    timezone: tz
                ) else {
                    return nil
                }
                place.isCustomLocation = true
                place.streetAddress = WxText.sanitize(fullAddress, maxBytes: WxLimits.placeNameMax)
                return WxAddressCandidate(
                    primaryTitle: cleanPrimary,
                    subtitle: subtitle,
                    fullAddress: place.streetAddress,
                    place: place,
                    kind: .streetAddress
                )
            }
        } catch {
            return []
        }
    }

    private static func titleCaseAddress(_ raw: String) -> String {
        let directionals: Set<String> = ["NW", "NE", "SW", "SE", "N", "S", "E", "W"]
        return raw.split(separator: " ").map { word in
            let upper = word.uppercased()
            if directionals.contains(upper) {
                return upper
            }
            return upper.prefix(1) + upper.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    // MARK: - Timezone Resolution

    private static func resolveTimezone(
        lat: Double,
        lon: Double,
        countryCode: String,
        admin1: String,
        known: [(lat: Double, lon: Double, tz: String)]
    ) -> String {
        for item in known {
            if WxGeo.distanceKm(aLat: lat, aLon: lon, bLat: item.lat, bLon: item.lon) <= 75.0 {
                return item.tz
            }
        }
        return inferFallbackTimezone(lat: lat, lon: lon, countryCode: countryCode, admin1: admin1)
    }

    private static func inferFallbackTimezone(
        lat: Double,
        lon: Double,
        countryCode: String,
        admin1: String
    ) -> String {
        if countryCode == "CA" || (countryCode != "US" && WxGeo.inCanada(lat: lat, lon: lon, countryCode: countryCode)) {
            let u = admin1.uppercased()
            if u == "NL" || u.contains("NEWFOUNDLAND") || lon >= -57.0 {
                return "America/St_Johns"
            }
            if u == "NS" || u == "NB" || u == "PE" || u.contains("NOVA SCOTIA") || u.contains("NEW BRUNSWICK") || lon >= -67.0 {
                return "America/Halifax"
            }
            if u == "SK" || u.contains("SASKATCHEWAN") {
                return "America/Regina"
            }
            if lon >= -90.0 { return "America/Toronto" }
            if lon >= -102.0 { return "America/Winnipeg" }
            if lon >= -115.0 { return "America/Edmonton" }
            return "America/Vancouver"
        }
        if countryCode == "US" || WxGeo.inUSNWS(lat: lat, lon: lon) {
            if lat >= 51.0 && lon <= -130.0 { return "America/Anchorage" }
            if lat <= 23.0 && lon <= -154.0 { return "Pacific/Honolulu" }
            if lat <= 19.0 && lon >= -68.0 && lon <= -64.5 { return "America/Puerto_Rico" }
            if lon >= -84.5 { return "America/New_York" }
            if lon >= -102.0 { return "America/Chicago" }
            if lon >= -115.0 {
                let u = admin1.uppercased()
                if u == "AZ" || u.contains("ARIZONA") { return "America/Phoenix" }
                return "America/Denver"
            }
            return "America/Los_Angeles"
        }
        switch countryCode {
        case "GB": return "Europe/London"
        case "IE": return "Europe/Dublin"
        case "FR": return "Europe/Paris"
        case "DE": return "Europe/Berlin"
        case "AT": return "Europe/Vienna"
        case "ES": return "Europe/Madrid"
        case "IT": return "Europe/Rome"
        case "CH": return "Europe/Zurich"
        case "NL": return "Europe/Amsterdam"
        case "BE": return "Europe/Brussels"
        case "NO": return "Europe/Oslo"
        case "SE": return "Europe/Stockholm"
        case "IS": return "Atlantic/Reykjavik"
        case "JP": return "Asia/Tokyo"
        case "KR": return "Asia/Seoul"
        case "SG": return "Asia/Singapore"
        case "NZ": return "Pacific/Auckland"
        default:
            let offsetHours = Int((lon / 15.0).rounded())
            if offsetHours == 0 {
                return "UTC"
            }
            // POSIX Etc/GMT sign convention is inverted relative to UTC offset
            let sign = offsetHours > 0 ? "-" : "+"
            return "Etc/GMT\(sign)\(abs(offsetHours))"
        }
    }
}
