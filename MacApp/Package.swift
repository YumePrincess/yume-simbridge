// swift-tools-version: 6.0
import PackageDescription
let package = Package(name:"YumeSimHub",platforms:[.macOS(.v14)],products:[.executable(name:"YumeSimHub",targets:["SimHub"])],targets:[.executableTarget(name:"SimHub")])
