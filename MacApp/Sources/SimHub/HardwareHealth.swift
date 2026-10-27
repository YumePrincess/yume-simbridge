import Foundation
import IOKit

@MainActor enum HardwareHealth {
  struct Module: Identifiable, Equatable {
    let location: UInt32
    let name: String
    var id: String { String(location) }
    var label: String { "\(name) · USB 0x\(String(location, radix: 16).uppercased())" }
  }
  static func modules() -> [Module] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var result: [Module] = []
    while true {
      let service = IOIteratorNext(iterator)
      if service == 0 { break }
      defer { IOObjectRelease(service) }
      func property(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      }
      guard let vendor = property("idVendor") as? NSNumber,
        let product = property("idProduct") as? NSNumber,
        (vendor.intValue == 0x2CA3 && product.intValue == 0x4006) || (vendor.intValue == 0x2C7C && product.intValue == 0x0125),
        let location = property("locationID") as? NSNumber else { continue }
      result.append(Module(location: location.uint32Value, name: property("USB Product Name") as? String ?? "DJI Cellular Dongle"))
    }
    return result.sorted { $0.location < $1.location }
  }
}
