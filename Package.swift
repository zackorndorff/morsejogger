// swift-tools-version: 6.0
//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import PackageDescription

let package = Package(
    name: "MorseJoggerNative",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "MorseJoggerCore", targets: ["MorseJoggerCore"]),
        .executable(name: "morsejogger-wasi", targets: ["MorseJoggerWasmCLI"])
    ],
    targets: [
        .target(name: "MorseJoggerCore"),
        .executableTarget(name: "MorseJoggerWasmCLI", dependencies: ["MorseJoggerCore"]),
        .testTarget(name: "MorseJoggerCoreTests", dependencies: ["MorseJoggerCore"], resources: [.process("SourceFixtures.json"), .process("SerialFixtures.json"), .process("OperatorFixtures.json"), .process("ConfidenceFixtures.json"), .process("OperatorTransitions.json"), .process("CallFixtures.json"), .process("MRCEConversationFixtures.json"), .process("MRCEKeyerFixtures.json"), .process("MRCEPrefixFixtures.json"), .process("MRCEReceiverFixtures.json"), .process("MRCESweepstakesParserFixtures.json")])
    ]
)
