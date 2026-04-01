//
//  NodeNameBuilder.swift
//  MeshCoreApple
//
//  Assembles standardized node names and handles reverse geocoding for the Node Setup Wizard.
//  Infrastructure format: CC-RGN-CTY-RL-XXXXX
//  Mobile format:         [emoji]XX-RL-XXXXX
//
//  Created by Michael P. Bedworth on 4/1/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation
#if !os(watchOS)
import CoreLocation
#endif

/// Maximum bytes for a MeshCore advert name.
let maxAdvertNameBytes = 24

/// Reverse-geocoded location codes for infrastructure node naming.
struct LocationCodes {
    var country: String  // ISO 3166-1 alpha-2 (e.g. "US")
    var region: String   // 2-3 char state/province (e.g. "CA")
    var city: String     // 3 char city code (e.g. "SFO")
}

/// Available emoji identifiers for mobile/client node names.
let nodeEmojis: [(emoji: String, label: String)] = [
    ("🦊", "Fox"), ("🐺", "Wolf"), ("🦅", "Eagle"), ("🐻", "Bear"),
    ("🦎", "Lizard"), ("🐝", "Bee"), ("🦉", "Owl"), ("🐍", "Snake"),
    ("🦈", "Shark"), ("🐢", "Turtle"), ("🦇", "Bat"), ("🐋", "Whale"),
    ("⚡", "Bolt"), ("🔥", "Fire"), ("🌲", "Tree"), ("🏔️", "Mountain"),
    ("🌊", "Wave"), ("☀️", "Sun"), ("🌙", "Moon"), ("⭐", "Star"),
    ("📡", "Satellite"), ("📻", "Antenna"), ("🏔️", "Peak"), ("🏠", "Home"),
]

/// Builds a standardized node name from its components.
struct NodeNameBuilder {
    var role: NodeRole
    // Infrastructure fields
    var locationCodes: LocationCodes?
    // Mobile/client fields
    var emoji: String?
    var initials: String = ""
    // Common
    var keyPrefix: String = ""

    /// Assemble the final node name string.
    var assembledName: String {
        if role.isInfrastructure {
            return assembleInfrastructureName()
        } else {
            return assembleMobileName()
        }
    }

    /// UTF-8 byte count of the assembled name.
    var byteCount: Int {
        assembledName.utf8.count
    }

    /// Whether the name fits within the 24-byte MeshCore advert name limit.
    var isValid: Bool {
        byteCount <= maxAdvertNameBytes && !assembledName.isEmpty
    }

    // MARK: - Name Assembly

    private func assembleInfrastructureName() -> String {
        guard let loc = locationCodes else { return "" }
        let parts = [
            loc.country.uppercased(),
            loc.region.uppercased(),
            loc.city.uppercased(),
            role.code,
            keyPrefix.lowercased()
        ]
        return parts.joined(separator: "-")
    }

    private func assembleMobileName() -> String {
        let prefix = emoji ?? ""
        let parts = [
            initials.uppercased(),
            role.code,
            keyPrefix.lowercased()
        ]
        return prefix + parts.joined(separator: "-")
    }

    // MARK: - Reverse Geocoding

    #if !os(watchOS)
    /// Reverse geocode a CLLocation into LocationCodes.
    static func reverseGeocode(location: CLLocation) async throws -> LocationCodes {
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.reverseGeocodeLocation(location)
        guard let placemark = placemarks.first else {
            throw NodeNameError.geocodingFailed
        }

        let country = placemark.isoCountryCode ?? "XX"
        let region = abbreviateRegion(placemark.administrativeArea, country: country)
        let city = abbreviateCity(placemark.locality)

        return LocationCodes(country: country, region: region, city: city)
    }
    #endif

    /// Abbreviate a state/province name to 2-3 characters.
    static func abbreviateRegion(_ adminArea: String?, country: String) -> String {
        guard let area = adminArea, !area.isEmpty else { return "XX" }

        // Use US/CA state abbreviations if available via lookup
        if let abbr = stateAbbreviations[area.uppercased()] {
            return abbr
        }

        // Fallback: first 2-3 characters
        let clean = area.replacingOccurrences(of: " ", with: "")
        return String(clean.prefix(3)).uppercased()
    }

    /// Abbreviate a city name to 3 characters.
    static func abbreviateCity(_ locality: String?) -> String {
        guard let city = locality, !city.isEmpty else { return "XXX" }

        // Well-known city codes
        if let code = cityCodes[city.uppercased()] {
            return code
        }

        // Fallback: first 3 consonants, or first 3 characters
        let clean = city.uppercased().replacingOccurrences(of: " ", with: "")
        let consonants = clean.filter { !"AEIOU".contains($0) }
        if consonants.count >= 3 {
            return String(consonants.prefix(3))
        }
        return String(clean.prefix(3))
    }
}

enum NodeNameError: LocalizedError {
    case geocodingFailed

    var errorDescription: String? {
        switch self {
        case .geocodingFailed:
            return "Could not determine location codes from coordinates."
        }
    }
}

// MARK: - Abbreviation Lookups

/// Common US/CA state name → abbreviation mapping.
private let stateAbbreviations: [String: String] = [
    // US States
    "ALABAMA": "AL", "ALASKA": "AK", "ARIZONA": "AZ", "ARKANSAS": "AR",
    "CALIFORNIA": "CA", "COLORADO": "CO", "CONNECTICUT": "CT", "DELAWARE": "DE",
    "FLORIDA": "FL", "GEORGIA": "GA", "HAWAII": "HI", "IDAHO": "ID",
    "ILLINOIS": "IL", "INDIANA": "IN", "IOWA": "IA", "KANSAS": "KS",
    "KENTUCKY": "KY", "LOUISIANA": "LA", "MAINE": "ME", "MARYLAND": "MD",
    "MASSACHUSETTS": "MA", "MICHIGAN": "MI", "MINNESOTA": "MN", "MISSISSIPPI": "MS",
    "MISSOURI": "MO", "MONTANA": "MT", "NEBRASKA": "NE", "NEVADA": "NV",
    "NEW HAMPSHIRE": "NH", "NEW JERSEY": "NJ", "NEW MEXICO": "NM", "NEW YORK": "NY",
    "NORTH CAROLINA": "NC", "NORTH DAKOTA": "ND", "OHIO": "OH", "OKLAHOMA": "OK",
    "OREGON": "OR", "PENNSYLVANIA": "PA", "RHODE ISLAND": "RI", "SOUTH CAROLINA": "SC",
    "SOUTH DAKOTA": "SD", "TENNESSEE": "TN", "TEXAS": "TX", "UTAH": "UT",
    "VERMONT": "VT", "VIRGINIA": "VA", "WASHINGTON": "WA", "WEST VIRGINIA": "WV",
    "WISCONSIN": "WI", "WYOMING": "WY", "DISTRICT OF COLUMBIA": "DC",
    // Canadian Provinces
    "ONTARIO": "ON", "QUEBEC": "QC", "BRITISH COLUMBIA": "BC", "ALBERTA": "AB",
    "MANITOBA": "MB", "SASKATCHEWAN": "SK", "NOVA SCOTIA": "NS",
    "NEW BRUNSWICK": "NB", "NEWFOUNDLAND AND LABRADOR": "NL",
    "PRINCE EDWARD ISLAND": "PE", "NORTHWEST TERRITORIES": "NT",
    "YUKON": "YT", "NUNAVUT": "NU",
    // Australian States
    "NEW SOUTH WALES": "NSW", "VICTORIA": "VIC", "QUEENSLAND": "QLD",
    "SOUTH AUSTRALIA": "SA", "WESTERN AUSTRALIA": "WA", "TASMANIA": "TAS",
    "NORTHERN TERRITORY": "NT", "AUSTRALIAN CAPITAL TERRITORY": "ACT",
    // UK Nations
    "ENGLAND": "ENG", "SCOTLAND": "SCT", "WALES": "WLS", "NORTHERN IRELAND": "NIR",
]

/// Well-known city → 3-letter code mapping.
private let cityCodes: [String: String] = [
    "SAN FRANCISCO": "SFO", "LOS ANGELES": "LAX", "NEW YORK": "NYC",
    "CHICAGO": "CHI", "HOUSTON": "HOU", "DALLAS": "DFW", "AUSTIN": "AUS",
    "SEATTLE": "SEA", "PORTLAND": "PDX", "DENVER": "DEN", "PHOENIX": "PHX",
    "SAN DIEGO": "SAN", "SAN JOSE": "SJC", "BOSTON": "BOS", "ATLANTA": "ATL",
    "MIAMI": "MIA", "ORLANDO": "ORL", "TAMPA": "TPA", "NASHVILLE": "BNA",
    "LONDON": "LDN", "MANCHESTER": "MAN", "BIRMINGHAM": "BHM", "EDINBURGH": "EDI",
    "GLASGOW": "GLA", "PARIS": "PAR", "BERLIN": "BER", "AMSTERDAM": "AMS",
    "SYDNEY": "SYD", "MELBOURNE": "MEL", "BRISBANE": "BNE", "PERTH": "PER",
    "AUCKLAND": "AKL", "WELLINGTON": "WLG", "CHRISTCHURCH": "CHC",
    "TORONTO": "TOR", "VANCOUVER": "VAN", "MONTREAL": "MTL", "CALGARY": "YYC",
    "TOKYO": "TKY", "BANGKOK": "BKK", "MUMBAI": "BOM", "DELHI": "DEL",
    "SINGAPORE": "SIN", "SEOUL": "ICN", "TAIPEI": "TPE", "HONG KONG": "HKG",
]
