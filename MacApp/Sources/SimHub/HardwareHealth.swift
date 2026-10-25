import Foundation
import IOKit

@MainActor enum HardwareHealth {
  static func modulePresent() -> Bool {
    let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
    matching["idVendor"] = 0x2CA3
    matching["idProduct"] = 0x4006
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
    else { return false }
    defer { IOObjectRelease(iterator) }
    let service = IOIteratorNext(iterator)
    guard service != 0 else { return false }
    IOObjectRelease(service)
    return true
  }
}
