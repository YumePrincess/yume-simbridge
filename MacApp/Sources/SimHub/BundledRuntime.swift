import Foundation

struct ClientRelease: Decodable {
  let version: String
  let build: Int
  let url: String
}
enum BundledRuntime {
  static func environment(resources: URL) -> [String: String] {
    var values = ProcessInfo.processInfo.environment
    for key in ["PYTHONHOME", "PYTHONPATH", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"] {
      values.removeValue(forKey: key)
    }
    values["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    values["PYTHONDONTWRITEBYTECODE"] = "1"
    values["PYTHONNOUSERSITE"] = "1"
    values["SSL_CERT_FILE"] =
      resources.appendingPathComponent("Python/lib/python3.12/site-packages/certifi/cacert.pem")
      .path
    return values
  }
  static func run(resources: URL, arguments: [String]) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      let process = Process()
      process.executableURL = resources.appendingPathComponent("Python/bin/python3.12")
      process.currentDirectoryURL = resources
      process.arguments = ["-s", "-B"] + arguments
      process.environment = environment(resources: resources)
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let output = String(decoding: data, as: UTF8.self)
      guard process.terminationStatus == 0 else {
        throw NSError(
          domain: "SimHubRuntime", code: Int(process.terminationStatus),
          userInfo: [NSLocalizedDescriptionKey: output])
      }
      return output
    }.value
  }
}
