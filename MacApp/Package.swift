// swift-tools-version: 6.2
import PackageDescription
let package = Package(name:"YumeSIMBridge",platforms:[.macOS(.v26)],products:[.executable(name:"YumeSIMBridge",targets:["SimHub"])],targets:[.executableTarget(name:"SimHub")])
