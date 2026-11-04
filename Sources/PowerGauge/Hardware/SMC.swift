import Foundation
import IOKit

/// Read-only access to the System Management Controller, the chip that keeps the Mac's sensor
/// readings, for what neither powermetrics nor the GPU drivers give: each core's temperature, a
/// GPU's temperature and power where its driver has none, and with the kernel readings the CPU's
/// temperature and the fan.
///
/// Any process may read it. Only the two commands that read are ever sent, never one that writes.
/// It is used from the main thread only, so it has no locks.
final class SMC {
  static let shared = SMC()

  /// Why a key has no value.
  enum Problem: Error, CustomStringConvertible {
    /// The SMC could not be opened.
    case unavailable
    /// This Mac has no such key.
    case notFound
    /// The call did not go through: the kernel's and the SMC's result.
    case failed(kern_return_t, UInt8)
    /// The value is of a type this reader does not decode.
    case undecoded(String)
    /// It decoded to NaN or infinity.
    case notANumber

    var description: String {
      switch self {
      case .unavailable: return "no access to the SMC"
      case .notFound: return "no such key"
      case .failed(let kernel, let smc):
        return String(format: "read failed (kernel 0x%x, SMC %d)", kernel, smc)
      case .undecoded(let type): return "type \"\(type)\" not decoded"
      case .notANumber: return "value is not a number"
      }
    }
  }

  /// The kernel's request record (`SMCKeyData_t`), 80 bytes: the key at 0; its size and type at
  /// 28, as a little-endian `UInt32` and four characters; the SMC's result at 40; the command
  /// at 42; and the value from 48.
  private enum ABI {
    static let size = 80
    /// `kSMCHandleYPCEvent`.
    static let selector: UInt32 = 2
    static let key = 0..<4
    static let keyInfo = 28..<40
    /// Within the key info.
    static let infoSize = 0..<4
    static let infoType = 4..<8
    static let result = 40
    static let command = 42
    static let value = 48
    static let readKey: UInt8 = 5
    static let getKeyInfo: UInt8 = 9
    static let succeeded: UInt8 = 0
    static let notFound: UInt8 = 0x84
  }

  /// Held for the life of the app; the kernel closes it at exit.
  private var connection: io_connect_t = 0
  private var keyInfo: [String: [UInt8]] = [:]
  /// Keys that will never have a value.
  private var unreadable: [String: Problem] = [:]

  private init() {
    let service = IOServiceGetMatchingService(SMC.defaultMainPort, IOServiceMatching("AppleSMC"))
    guard service != 0 else { return }
    defer { IOObjectRelease(service) }
    if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
  }

  private func call(_ request: [UInt8]) -> Result<[UInt8], Problem> {
    guard connection != 0 else { return .failure(.unavailable) }
    var reply = [UInt8](repeating: 0, count: ABI.size)
    var size = reply.count
    let kernel = request.withUnsafeBytes { input in
      reply.withUnsafeMutableBytes { output in
        IOConnectCallStructMethod(
          connection,
          ABI.selector,
          input.baseAddress,
          request.count,
          output.baseAddress,
          &size
        )
      }
    }
    guard kernel == KERN_SUCCESS, size == ABI.size else { return .failure(.failed(kernel, 0)) }
    switch reply[ABI.result] {
    case ABI.succeeded: return .success(reply)
    case ABI.notFound: return .failure(.notFound)
    case let smc: return .failure(.failed(kernel, smc))
    }
  }

  /// A key's value, or why there is none.
  ///
  /// A key that does not exist, or whose type this does not decode, is not asked for again; after
  /// any other failure it is tried afresh next time, since that may have been passing.
  func read(_ key: String) -> Result<Double, Problem> {
    guard key.utf8.count == ABI.key.count else { return .failure(.notFound) }
    if let problem = unreadable[key] { return .failure(problem) }
    var request = [UInt8](repeating: 0, count: ABI.size)
    // Four characters as a little-endian UInt32.
    request.replaceSubrange(ABI.key, with: key.utf8.reversed())
    if keyInfo[key] == nil {
      request[ABI.command] = ABI.getKeyInfo
      switch call(request) {
      case .success(let reply): keyInfo[key] = Array(reply[ABI.keyInfo])
      case .failure(let problem):
        if case .notFound = problem { unreadable[key] = problem }
        return .failure(problem)
      }
    }
    let info = keyInfo[key]!
    let size = Int(SMC.littleEndian(info[ABI.infoSize]))
    let type = String(bytes: info[ABI.infoType].reversed(), encoding: .ascii) ?? "?"
    guard let decode = SMC.decoder(type: type, size: size) else {
      unreadable[key] = .undecoded(type)
      return .failure(.undecoded(type))
    }
    request.replaceSubrange(ABI.keyInfo, with: info)
    request[ABI.command] = ABI.readKey
    return call(request).flatMap { reply in
      let value = decode(Array(reply[ABI.value..<(ABI.value + size)]))
      return value.isFinite ? .success(value) : .failure(.notANumber)
    }
  }

  func value(_ key: String) -> Double? { try? read(key).get() }

  /// Each core's temperature, in °C, from the keys of `coreTemperatureKeys` that this Mac has.
  ///
  /// Keys it doesn't have are asked for once only. Empty on a Mac with none.
  func coreTemperatures() -> [Double] {
    SMC.coreTemperatureKeys.compactMap { value($0) }.filter {
      $0 > 0 && $0 < SMC.temperatureCeilingC
    }
  }

  /// A key per physical core, numbered from 0 or from 1 depending on the Mac: TC0C to TC9C, then on
  /// with capital letters, TCAC for core 10, as VirtualSMC, which emulates Macs' SMCs, names them.
  ///
  /// The keys stop at this Mac's number of cores, since further letters name other sensors on some
  /// Macs: TCGC the integrated GPU, TCXC the CPU as a whole.
  static let coreTemperatureKeys = keyIndexes.prefix(
    min(ThisMac.coreCount, keyIndexes.count - 1) + 1
  ).map { "TC\($0)C" }

  /// The characters that number the keys of a set: digits, then capital letters.
  private static let keyIndexes = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
  /// A temperature reading at or above this is a sensor with nothing to report.
  static let temperatureCeilingC = 130.0
  /// IOKit's default main port, whose named constant needs macOS 12.
  private static let defaultMainPort: mach_port_t = 0

  /// How to read a value of one of the types that sensor keys use.
  ///
  /// Those are two-byte big-endian fixed point, signed (`sp78`) or not (`fpe2`), whose last hex
  /// digit is the number of fraction bits; and little-endian 32-bit floats (`flt `).
  ///
  /// - Parameters:
  ///   - type: The key's type code.
  ///   - size: The value's size in bytes.
  /// - Returns: The decoder, or nil for a type or size it doesn't read.
  private static func decoder(type: String, size: Int) -> (([UInt8]) -> Double)? {
    let code = Array(type)
    if size == MemoryLayout<UInt16>.size, code.count == ABI.infoType.count,
      code[0] == "s" || code[0] == "f",
      code[1] == "p",
      let fractionBits = Int(String(code[3]), radix: 16)
    {
      let signed = code[0] == "s"
      return { bytes in
        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        return (signed ? Double(Int16(bitPattern: raw)) : Double(raw)) / Double(1 << fractionBits)
      }
    }
    if size == MemoryLayout<Float>.size, type == "flt " {
      return { bytes in Double(Float(bitPattern: littleEndian(bytes))) }
    }
    return nil
  }

  /// A little-endian number from its bytes.
  private static func littleEndian<Bytes: Collection>(_ bytes: Bytes) -> UInt32
  where Bytes.Element == UInt8 {
    bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) }
  }
}
