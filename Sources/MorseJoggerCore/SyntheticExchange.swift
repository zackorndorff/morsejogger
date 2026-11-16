//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import Foundation

/// Made-up exchange details for a caller that no imported call history covers.
///
/// Nothing here is real data about the station. The values are derived from
/// the call alone, so the same call sends the same exchange every time it is
/// heard, in any session, the way a real station does. (Names are handed out
/// by the simulator, which keeps one per call for the session.) US, Canadian and
/// Japanese locations follow the call area, which is where most such stations
/// really are.
enum SyntheticExchange {
    struct Fields: Equatable {
        /// State or province and a matching ARRL/RAC section; nil outside
        /// the United States and Canada.
        var state: String?, section: String?
        var fdClass: String, check: String, cwops: String, power: String
        var jaPref: String, jaCity: String, jaPower: String
    }

    /// (state, section) pairs by US call area.
    private static let usAreas: [Character: [(String, String)]] = [
        "1": [("CT","CT"),("MA","EMA"),("MA","WMA"),("ME","ME"),("NH","NH"),("RI","RI"),("VT","VT")],
        "2": [("NJ","NNJ"),("NJ","SNJ"),("NY","ENY"),("NY","NLI"),("NY","NNY"),("NY","WNY")],
        "3": [("DE","DE"),("MD","MDC"),("PA","EPA"),("PA","WPA")],
        "4": [("AL","AL"),("FL","NFL"),("FL","SFL"),("FL","WCF"),("GA","GA"),("KY","KY"),
              ("NC","NC"),("SC","SC"),("TN","TN"),("VA","VA")],
        "5": [("AR","AR"),("LA","LA"),("MS","MS"),("NM","NM"),("OK","OK"),("TX","NTX"),("TX","STX"),("TX","WTX")],
        "6": [("CA","EB"),("CA","LAX"),("CA","ORG"),("CA","SB"),("CA","SCV"),("CA","SDG"),
              ("CA","SF"),("CA","SJV"),("CA","SV")],
        "7": [("AZ","AZ"),("ID","ID"),("MT","MT"),("NV","NV"),("OR","OR"),("UT","UT"),
              ("WA","EWA"),("WA","WWA"),("WY","WY")],
        "8": [("MI","MI"),("OH","OH"),("WV","WV")],
        "9": [("IL","IL"),("IN","IN"),("WI","WI")],
        "0": [("CO","CO"),("IA","IA"),("KS","KS"),("MN","MN"),("MO","MO"),("NE","NE"),("ND","ND"),("SD","SD")],
    ]
    /// (province, section) pairs by Canadian prefix and call area.
    private static func canada(_ call: String, area: Character) -> [(String, String)] {
        if call.hasPrefix("VO") { return [("NL","NL")] }
        if call.hasPrefix("VY") {
            return area == "1" ? [("YT","TER")] : area == "2" ? [("PE","PE")] : [("NU","TER")]
        }
        switch area {
        case "1": return [("NS","NS")]
        case "2": return [("QC","QC")]
        case "3": return [("ON","ONE"),("ON","ONN"),("ON","ONS"),("ON","GH")]
        case "4": return [("MB","MB")]
        case "5": return [("SK","SK")]
        case "6": return [("AB","AB")]
        case "7": return [("BC","BC")]
        case "8": return [("NT","TER")]
        case "9": return [("NB","NB")]
        default: return [("ON","ONE")]
        }
    }
    /// JARL prefecture numbers by Japanese call area. Area 8 is Hokkaido,
    /// which the All JA contest splits into sub-prefectures 101...114.
    private static let japanAreas: [Character: [Int]] = [
        "1": [10,11,12,13,14,15,16,17], "2": [18,19,20,21], "3": [22,23,24,25,26,27],
        "4": [31,32,33,34,35], "5": [36,37,38,39], "6": [40,41,42,43,44,45,46,47],
        "7": [2,3,4,5,6,7], "8": Array(101...114), "9": [28,29,30], "0": [8,9],
    ]
    /// Field Day classes, weighted roughly as they are heard.
    private static let fdClasses: [(String, Double)] = [
        ("1D",0.40),("1E",0.13),("1B",0.13),("2A",0.08),("3A",0.07),("4A",0.04),("1A",0.03),
        ("5A",0.02),("2D",0.02),("1C",0.02),("2B",0.01),("2E",0.01),("2F",0.01),("3F",0.01),
        ("6A",0.01),("1F",0.01),
    ]
    /// ARRL DX power as sent by DX stations.
    private static let powers: [(String, Double)] = [
        ("100",0.42),("KW",0.26),("500",0.07),("400",0.06),("200",0.05),("1TT",0.04),("50",0.04),("5",0.04),("10",0.02),
    ]

    private static func weighted(_ table: [(String, Double)], _ draw: Double) -> String {
        var left = draw * table.reduce(0) { $0 + $1.1 }
        for (value, weight) in table { left -= weight; if left < 0 { return value } }
        return table[table.count - 1].0
    }
    /// FNV-1a, so the result depends on the call and nothing else.
    private static func seed(_ call: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in call.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    static func fields(call: String, country: String) -> Fields {
        var rng = ContestRNG(seed: seed(call))
        // The call area is the last digit of the first part that has one.
        let base = call.split(separator: "/").first { $0.contains(where: \.isNumber) && $0.count >= 3 }.map(String.init) ?? call
        let area = base.last(where: \.isNumber) ?? "0"
        var place: (String, String)?
        if country == "K", let list = usAreas[area] { place = list[rng.int(0, list.count - 1)] }
        else if country == "VE" { let list = canada(base, area: area); place = list[rng.int(0, list.count - 1)] }
        else { _ = rng.int(0, 1) }
        let fdClass = weighted(fdClasses, rng.random())
        // Year first licensed: two digits, most often the 1960s to the 2010s.
        let year = 1955 + Int((Double(2024 - 1955) * rng.random()).rounded())
        let check = String(format: "%02d", year % 100)
        let cwops = String(rng.int(1, 3_700))
        let power = weighted(powers, rng.random())
        let prefectures = japanAreas[area] ?? [10]
        let prefecture = prefectures[rng.int(0, prefectures.count - 1)]
        let jaPref = prefecture >= 100 ? String(prefecture) : String(format: "%02d", prefecture)
        // A city code is the prefecture (01 for all of Hokkaido) and a city number.
        let jaCity = String(format: "%02d%02d", prefecture >= 100 ? 1 : prefecture, rng.int(1, 12))
        let jaPower = weighted([("H",0.25),("M",0.50),("L",0.15),("P",0.10)], rng.random())
        return Fields(state: place?.0, section: place?.1, fdClass: fdClass, check: check,
                      cwops: cwops, power: power, jaPref: jaPref, jaCity: jaCity, jaPower: jaPower)
    }
}
