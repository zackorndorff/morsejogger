//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

/// Source-aligned random call generator, independent of UIKit or JavaScript.
/// Region restrictions are important for JA-area and ARRL DX practice.
public enum CallerRegion:String, CaseIterable, Sendable {case all,usve,dx,ja}
public enum CallsignGenerator {
    public static func makeCall(_ rng:inout ContestRNG,region:CallerRegion = .all) -> String {
        let us1=["K","N","W"]
        let us2=["AA","AB","AC","AE","AF","KC","KD","KE","KF","KG","KI","KJ","KK","KL","KM","KN","KO","KP","KQ","KR","KS","KT","KU","KV","KW","KX","KY","KZ","WA","WB","WD","WE","WF","WG","WI","WJ"]
        let dx1=["G","F","I"]
        let dx2=["DL","EA","JA","VK","VE","PY","SM","OH","ON","PA","HB","OE","SP","OK","OM","YO","LZ","UA","YU","4X","ZL"]
        let japanese=["JA","JE","JF","JG","JH","JI","JJ","JK","JL","JM","JN","JO","JP","JQ","JR","JS"]
        let format=[(1,2),(1,3),(2,1),(2,2),(2,3),(1,1)][rng.int(0,5)]
        let preferUS=region == .usve || (region == .all && rng.random()<0.62)
        let pool:[String]
        switch region {
        case .ja:pool=japanese
        case .dx:pool=format.0 == 1 ? dx1 : dx2.filter{$0 != "VE"}
        default:pool=preferUS ? (format.0 == 1 ? us1 : us2) : (format.0 == 1 ? dx1 : dx2)
        }
        var prefix=pool[rng.int(0,pool.count-1)]
        if region == .ja && format.0 == 1 {prefix=pool[rng.int(0,pool.count-1)]}
        let letters=Array("ABCDEFGHJKLMNPRSTUVWXYZ")
        var suffix=""
        for _ in 0..<format.1 {suffix.append(letters[rng.int(0,letters.count-1)])}
        let number=rng.int(0,9)
        let portable=rng.random()<0.035 ? "/P" : ""
        return prefix+String(number)+suffix+portable
    }
}
