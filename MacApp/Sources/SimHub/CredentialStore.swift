import Darwin
import Foundation

// Credentials survive replacement of the signed app bundle. No Keychain ACL
// depends on the changing identity of an ad-hoc development signature.
enum CredentialStore {
  static func read(_ url: URL) throws -> Bootstrap {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
    guard values.isRegularFile == true, values.isSymbolicLink != true, mode & 0o077 == 0,
      owner == getuid()
    else { throw CocoaError(.fileReadNoPermission) }
    let boot = try JSONDecoder().decode(Bootstrap.self, from: Data(contentsOf: url))
    guard boot.origin == "https://worker.example.com", boot.token.count >= 32 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return boot
  }
  static func save(_ boot: Bootstrap, folder: URL) throws {
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    let url = folder.appendingPathComponent("credentials.json")
    try JSONEncoder().encode(boot).write(to: url, options: [.atomic, .completeFileProtection])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
