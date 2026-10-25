// swift-tools-version: 6.2
import PackageDescription
let package = Package(name:"YumeSimHub",platforms:[.macOS(.v26)],products:[.executable(name:"YumeSimHub",targets:["SimHub"])],targets:[.executableTarget(name:"SimHub")])
