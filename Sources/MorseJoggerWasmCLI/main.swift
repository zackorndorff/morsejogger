//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WASILibc)
import WASILibc
#endif
import MorseJoggerCore

/// The same Swift core used by iOS is built as a WASI executable with an
/// installed Swift Wasm SDK. The host communicates through JSON-lines stdin/stdout.
/// Input: {"action":"start"|"tick"|"command"|"stop","time":0.0,"command":"cq","call":"...","exchange":"...","exchangeFirst":"...","exchangeSecond":"..."}
struct Request:Decodable {
    var action:String
    var time:Double?=nil
    var command:String?=nil
    var call:String?=nil
    var exchange:String?=nil
    var exchangeFirst:String?=nil
    var exchangeSecond:String?=nil
}
struct Response:Encodable {
    var snapshot:SessionSnapshot
    var events:[RadioEvent]
    var log:[QSOEntry]
    var error:String? = nil
}
var game=ContestSimulator(settings:ContestSettings())
var configurationFailure: String?
let encoder=JSONEncoder(),decoder=JSONDecoder()
while let line=readLine() {
    var responseError:String?=nil
    do {
        let request=try decoder.decode(Request.self,from:Data(line.utf8))
        switch request.action {
        case "configure":
            let object=try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any] ?? [:]
            var defaults=try JSONSerialization.jsonObject(with:encoder.encode(ContestSettings())) as? [String:Any] ?? [:]
            if let updates=object["settings"] as? [String:Any] {
                for (key,value) in updates {
                    if key=="effects",let patch=value as? [String:Any],var current=defaults["effects"] as? [String:Any] {
                        for (effect,flag) in patch {current[effect]=flag}
                        defaults[key]=current
                    } else {defaults[key]=value}
                }
            }
            let settings=try decoder.decode(ContestSettings.self,from:JSONSerialization.data(withJSONObject:defaults))
            configurationFailure = settings.configurationError
            if let error = configurationFailure { responseError = error }
            else { game=ContestSimulator(settings:settings) }
        case "start":
            if let error = configurationFailure { responseError = error; break }
            let wasRunning=game.running
            if !game.start() && !wasRunning {responseError="Session instances are single-use; configure a new session before starting again."}
        case "tick":game.tick(request.time ?? 0)
        case "command":
            if let command=request.command.flatMap(Command.init(rawValue:)) {
                game.command(command,call:request.call ?? "",exchange:request.exchange ?? "",
                             exchangeFirst:request.exchangeFirst,exchangeSecond:request.exchangeSecond)
            }
        case "stop":game.stopSession()
        default:break
        }
        let result=Response(snapshot:game.snapshot,events:game.drainEvents(),log:game.log,error:responseError)
        if let string=String(data:try encoder.encode(result),encoding:.utf8){print(string);fflush(stdout)}
    }catch{print("{\"error\":\"Invalid JSON or request\"}");fflush(stdout)}
}
