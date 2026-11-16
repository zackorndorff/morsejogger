//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

/// MRCE CqWpx.pas / Ini.pas serial-number draws. WPX Mid/End caller serials
/// use the source's weighted bins; other contests draw uniformly from their
/// configured segment using Ini.SerialNRSettings.GetNR.
public enum SerialDistribution {
    private static let bins:[(Int,Int)] = [
        (0,344),(10,188),(20,178),(30,164),(40,156),(50,179),(60,149),
        (70,126),(80,118),(90,124),(100,957),(200,628),(300,368),(400,257),
        (500,239),(600,150),(700,129),(800,100),(900,65),(1000,79),
        (1100,59),(1200,47),(1300,44),(1400,26),(1500,28),(1600,36),
        (1700,23),(1800,25),(1900,23),(2000,17),(2100,24),(2200,16),
        (2300,15),(2400,7),(2500,11),(2600,6),(2700,11),(2800,4),
        (2900,5),(3000,6),(3100,1),(3200,4),(3300,6),(3400,3),
        (3500,1),(3600,2),(3700,3),(3800,0),(3900,1),(4000,2),
        (4100,0),(4200,0),(4300,0),(4400,0),(4500,0),(4600,1),
        (4700,0),(4800,0),(4900,0),(5000,0)
    ]
    public static func draw(_ settings:ContestSettings,rng:inout ContestRNG,elapsed:Double,skill:Int) -> Int {
        if settings.serialRange == .custom {
            let minimum=max(1,settings.serialMin),maximum=max(minimum,settings.serialMax)
            // MRCE accepts equal endpoints, but Random(0)'s Delphi runtime
            // behavior is unknown. Preserve the accepted value safely.
            guard maximum > minimum else { return minimum }
            // ParseSerialNR preserves the entered values; GetNR's Random(N)
            // excludes N, so the configured upper endpoint is exclusive.
            return minimum + Int(rng.random()*Double(maximum-minimum))
        }
        // WPX and HST caller Start serials use DxOper.GetNR. The simulator's
        // clock is elapsed seconds; the source scales a random fraction by
        // elapsed minutes and the operator skill, then rounds it.
        if settings.serialRange == .start && (settings.contest == .wpx || settings.mode == .hstCompetition) {
            let span=max(0,elapsed/60*Double(max(0,skill)))
            return 1+Int((rng.random()*span).rounded(.toNearestOrEven))
        }
        // Every other serial-sending contest (Sweepstakes, ARRL 10m DX callers)
        // uses `Ini.SerialNRSettings[snStartContest].GetNR`: MinVal 1, MaxVal 176,
        // drawn as `MinVal + Random(MaxVal - MinVal)`, so 1...175.
        if settings.mode == .hstCompetition || settings.serialRange == .start {
            return 1 + Int(rng.random()*175)
        }
        let low=settings.serialRange == .mid ? 50 : 500
        let high=settings.serialRange == .mid ? 500 : 5000
        guard settings.contest == .wpx else {
            return low + Int(rng.random()*Double(high-low))
        }
        var eligible:[(Int,Int,Int)]=[]
        var total=0
        for (i,(begin,weight)) in bins.enumerated() {
            let end=i+1<bins.count ? bins[i+1].0 : 5010
            let left=max(low,begin),right=min(high,end-1)
            if left<=right && weight>0 {eligible.append((left,right,weight));total+=weight}
        }
        var hit=rng.random()*Double(total)
        for (left,right,weight) in eligible {
            hit-=Double(weight)
            if hit<0 {return rng.int(left,right)}
        }
        return high
    }
}
