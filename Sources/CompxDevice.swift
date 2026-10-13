import Foundation
import IOKit.hid

/// Compx 칩셋(CX5x 계열) 벤더 HID 프로토콜.
/// 패킷: Report ID 0x08, 17바이트 = [08, cmd, 00, addrHi, addrLo, len, data×10, checksum]
/// checksum: 앞 16바이트 합 + checksum ≡ 0x55 (mod 256)
/// 명령: 0x03 상태, 0x04 전원, 0x07 메모리 쓰기, 0x08 메모리 읽기.
/// 쓰기 데이터는 레코드(값… + 레코드 체크섬, 합 ≡ 0x55) 단위이며, 쓴 뒤 다시 읽어 검증한다.
enum Compx {
    static let vendorID = 0x3554
    static let vendorUsagePage = 0xFF05
    static let reportID: UInt8 = 0x08

    enum Command: UInt8 {
        case status = 0x03
        case power = 0x04
        case writeMemory = 0x07
        case readMemory = 0x08
    }

    static func packet(_ cmd: Command, addr: UInt16 = 0, len: UInt8 = 0, data: [UInt8] = []) -> [UInt8] {
        precondition(data.count <= 10)
        var p: [UInt8] = [reportID, cmd.rawValue, 0, UInt8(addr >> 8), UInt8(addr & 0xFF), len]
        p += data + Array(repeating: 0, count: 10 - data.count)
        p.append(0x55 &- p.reduce(0, &+))
        return p
    }
}

enum DeviceError: LocalizedError {
    case permissionDenied, notFound, openFailed(IOReturn), sendFailed(IOReturn), timeout

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "입력 모니터링 권한이 필요합니다."
        case .notFound: "그라비스타 수신기/마우스를 찾을 수 없습니다."
        case .openFailed(let r): String(format: "장치를 열 수 없습니다 (0x%08x)", r)
        case .sendFailed(let r): String(format: "명령 전송 실패 (0x%08x)", r)
        case .timeout: "마우스가 응답하지 않습니다 (절전 중일 수 있음)."
        }
    }
}

/// 수신기(또는 유선 연결된 마우스)의 벤더 HID 인터페이스와 통신한다.
/// 모든 호출과 콜백은 메인 런루프에서 실행된다.
@MainActor
final class CompxDevice {
    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
    private var pending: (cmd: UInt8, addr: UInt16?, cont: CheckedContinuation<[UInt8], Error>)?

    /// 일반 마우스 이동 리포트(ID 0x0B) 수신 시각 — 실측 폴링레이트 계산용.
    var onMotionReport: ((UInt64) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private(set) var productName: String?
    private(set) var productID: Int?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // 벤더 인터페이스(명령/응답) + 일반 마우스 인터페이스(이동 리포트 → 실측 폴링레이트)
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDVendorIDKey: Compx.vendorID, kIOHIDPrimaryUsagePageKey: Compx.vendorUsagePage],
            [kIOHIDVendorIDKey: Compx.vendorID, kIOHIDPrimaryUsagePageKey: 0x01, kIOHIDPrimaryUsageKey: 0x02],
        ] as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            let me = Unmanaged<CompxDevice>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.attach(dev) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            let me = Unmanaged<CompxDevice>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.detach(dev) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    static var hasPermission: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    static func requestPermission() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start() throws {
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if r == kIOReturnNotPermitted { throw DeviceError.permissionDenied }
        if r != kIOReturnSuccess { throw DeviceError.openFailed(r) }
    }

    var isConnected: Bool { device != nil }

    private(set) var openResult: IOReturn = kIOReturnSuccess

    private var pointer: IOHIDDevice?
    private let pointerBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    private func attach(_ dev: IOHIDDevice) {
        let usagePage = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int
        if usagePage == 0x01 { attachPointer(dev); return }
        // 매니저가 열리기 전에 매칭된 장치는 열리지 않으므로 직접 연다.
        openResult = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        device = dev
        productName = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String
        productID = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(dev, inputBuffer, 128, { ctx, _, _, _, rid, report, len, ts in
            let me = Unmanaged<CompxDevice>.fromOpaque(ctx!).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: len))
            MainActor.assumeIsolated { me.handleInput(id: UInt8(rid), bytes: bytes, timestamp: ts) }
        }, ctx)
        onConnectionChange?(true)
    }

    private func attachPointer(_ dev: IOHIDDevice) {
        pointer = dev
        IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(dev, pointerBuffer, 64, { ctx, _, _, _, _, _, _, ts in
            let me = Unmanaged<CompxDevice>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.onMotionReport?(ts) }
        }, ctx)
    }

    private func detach(_ dev: IOHIDDevice) {
        if dev == pointer { pointer = nil; return }
        guard dev == device else { return }
        device = nil
        pending?.cont.resume(throwing: DeviceError.notFound)
        pending = nil
        onConnectionChange?(false)
    }

    private func handleInput(id: UInt8, bytes: [UInt8], timestamp: UInt64) {
        if id == 0x0B { onMotionReport?(timestamp); return }
        guard id == 0x08 || id == 0x09, bytes.count > 5, let p = pending else { return }
        // macOS는 보통 리포트 ID를 바이트 0에 포함해 전달한다.
        let body = bytes[0] == id ? bytes : [id] + bytes
        guard body[1] == p.cmd else { return }
        if let addr = p.addr, (UInt16(body[3]) << 8 | UInt16(body[4])) != addr { return }
        pending = nil
        p.cont.resume(returning: body)
    }

    /// 명령을 보내고 같은 cmd(읽기는 같은 주소)의 응답을 기다린다.
    func send(_ cmd: Compx.Command, addr: UInt16 = 0, len: UInt8 = 0, data: [UInt8] = [], timeout: Double = 0.6) async throws -> [UInt8] {
        guard let dev = device else { throw DeviceError.notFound }
        if openResult != kIOReturnSuccess {
            // 권한이 나중에 부여된 경우 재시도
            openResult = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            if openResult == kIOReturnNotPermitted { throw DeviceError.permissionDenied }
            if openResult != kIOReturnSuccess { throw DeviceError.openFailed(openResult) }
        }
        while pending != nil { try await Task.sleep(for: .milliseconds(10)) }
        let pkt = Compx.packet(cmd, addr: addr, len: len, data: data)
        return try await withCheckedThrowingContinuation { cont in
            pending = (cmd.rawValue, cmd == .readMemory || cmd == .writeMemory ? addr : nil, cont)
            let r = pkt.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(Compx.reportID), $0.baseAddress!, pkt.count)
            }
            if r != kIOReturnSuccess {
                pending = nil
                cont.resume(throwing: r == kIOReturnNotPermitted ? DeviceError.permissionDenied : DeviceError.sendFailed(r))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let p = self.pending, p.cmd == cmd.rawValue else { return }
                self.pending = nil
                p.cont.resume(throwing: DeviceError.timeout)
            }
        }
    }

    /// 레코드를 쓰고 같은 구간을 다시 읽어 반환한다. 쓰기 응답(ack)은 없을 수도 있어 기다리지만 필수는 아니다.
    func write(addr: UInt16, data: [UInt8]) async throws -> [UInt8] {
        _ = try? await send(.writeMemory, addr: addr, len: UInt8(data.count), data: data, timeout: 0.3)
        var back: [UInt8]?
        for _ in 0..<3 where back == nil {
            back = try? await send(.readMemory, addr: addr, len: UInt8(data.count), timeout: 0.4)
        }
        guard let r = back else { throw DeviceError.timeout }
        return Array(r[6..<(6 + data.count)])
    }

    /// `start`부터 `count`바이트를 10바이트 단위로 읽는다. 응답 없는 구간은 nil.
    func readMemory(from start: UInt16, count: Int) async -> [UInt16: [UInt8]] {
        var out: [UInt16: [UInt8]] = [:]
        var addr = start
        while Int(addr) < Int(start) + count {
            // 무선 구간에서 가끔 응답이 유실되므로 한 번 재시도
            var reply = try? await send(.readMemory, addr: addr, len: 10, timeout: 0.3)
            if reply == nil { reply = try? await send(.readMemory, addr: addr, len: 10, timeout: 0.5) }
            if let r = reply {
                let n = min(Int(r[5]), r.count - 7, 10)
                out[addr] = n > 0 ? Array(r[6..<(6 + n)]) : []
            }
            addr += 10
        }
        return out
    }
}
