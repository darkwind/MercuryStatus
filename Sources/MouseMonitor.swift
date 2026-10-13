import Foundation
import Observation

struct Battery: Equatable {
    var percent: Int
    var charging: Bool
    var millivolts: Int
}

struct RGB: Equatable { var r, g, b: UInt8 }

/// 설정 메모리(0x0000~) 해석. 머큐리 X Pro(수신기 PID 0xF54B)에서 웹 UI 설정을 바꿔가며
/// 덤프를 비교해 확인한 레이아웃. 각 레코드는 값 + 체크섬(합 ≡ 0x55).
///   0x00 폴링 코드          0x02 DPI 단계 수        0x04 현재 단계(0부터)
///   0x0A LOD(0=0.7 1=1 2=2mm) 0x2C~ 단계별 색(R G B ck)
///   0x0C~ DPI 표: 단계당 [X Y hi ck]. hi 니블(하위=X, 상위=Y)의 bit2 = 값의 bit8,
///         bit0 = 100 단위(아니면 50 단위). DPI = (값+1) × 단위. 예) 20000 = 8f 8f 44, 32000 = 3f 3f 55
///   0xAB 모션 싱크   0xAF 직선 보정   0xB1 리플 제어   0xB5 최대 성능
///   0xB7 최대 성능 시간(10초 단위)   0xB9 센서 모드(0=LP 1=HP 2=Corded)
struct DecodedConfig: Equatable {
    var pollingRate: Int?
    var dpiStages: [Int] = []
    var dpiColors: [RGB] = []
    var activeStage: Int?
    var lod: String?
    var sensorMode: String?
    var motionSync: Bool?
    var angleSnapping: Bool?
    var rippleControl: Bool?
    var maxPerformance: Bool?
    var maxPerformanceSeconds: Int?
    var verified = false

    static let pollingCodes: [UInt8: Int] = [
        0x08: 125, 0x04: 250, 0x02: 500, 0x01: 1000,
        0x10: 2000, 0x20: 4000, 0x40: 8000,
    ]
    static let pollingRates = pollingCodes.values.sorted()
    static let maxPerformanceSeconds = [10, 30, 60, 120, 180, 300, 600, 900]
    static let dpiRange = 50...32000
    static let lodNames = ["0.7mm", "1mm", "2mm"]
    static let sensorModes = ["LP", "HP", "Corded"]

    init() {}

    init(memory m: [UInt8]) {
        guard m.count >= 0xC0, Self.isRecord(m, 0x00, 2) else { return }
        verified = true
        pollingRate = Self.pollingCodes[m[0x00]]
        let count = Int(m[0x02])
        if (1...8).contains(count) {
            for i in 0..<count {
                let o = 0x0C + i * 4
                dpiStages.append(Self.decodeDPI(lo: m[o], hi: m[o + 2]))
                let c = 0x2C + i * 4
                dpiColors.append(RGB(r: m[c], g: m[c + 1], b: m[c + 2]))
            }
            if Int(m[0x04]) < count { activeStage = Int(m[0x04]) }
        }
        lod = byte(m, 0x0A).flatMap { $0 < 3 ? Self.lodNames[Int($0)] : nil }
        sensorMode = byte(m, 0xB9).flatMap { $0 < 3 ? Self.sensorModes[Int($0)] : nil }
        motionSync = flag(m, 0xAB)
        angleSnapping = flag(m, 0xAF)
        rippleControl = flag(m, 0xB1)
        maxPerformance = flag(m, 0xB5)
        maxPerformanceSeconds = byte(m, 0xB7).map { Int($0) * 10 }
    }

    static func decodeDPI(lo: UInt8, hi: UInt8) -> Int {
        let n = Int(hi & 0x0F)
        return ((Int(lo) | (n >> 2 & 1) << 8) + 1) * (n & 1 == 1 ? 100 : 50)
    }

    /// DPI → 레코드 [X Y hi ck]. 25600 이하는 50 단위, 초과는 100 단위로 반올림.
    static func encodeDPI(_ dpi: Int) -> [UInt8] {
        let d = min(max(dpi, dpiRange.lowerBound), dpiRange.upperBound)
        let wide = d > 25600
        let raw = (d + (wide ? 50 : 25)) / (wide ? 100 : 50) - 1
        let nibble = UInt8((raw >> 8 & 1) << 2 | (wide ? 1 : 0))
        return record([UInt8(raw & 0xFF), UInt8(raw & 0xFF), nibble | nibble << 4])
    }

    static func record(_ v: [UInt8]) -> [UInt8] { v + [0x55 &- v.reduce(0, &+)] }

    private static func isRecord(_ m: [UInt8], _ at: Int, _ len: Int) -> Bool {
        m[at..<(at + len)].reduce(0, &+) == 0x55
    }
    private func byte(_ m: [UInt8], _ at: Int) -> UInt8? { Self.isRecord(m, at, 2) ? m[at] : nil }
    private func flag(_ m: [UInt8], _ at: Int) -> Bool? { byte(m, at).map { $0 != 0 } }

    var activeDPI: Int? { activeStage.flatMap { $0 < dpiStages.count ? dpiStages[$0] : nil } }
}

/// 앱에서 바꿀 수 있는 설정과 그 메모리 위치/인코딩
enum Setting {
    case pollingRate(Int), stageCount(Int), activeStage(Int), dpi(stage: Int, value: Int)
    case lod(Int), sensorMode(Int), motionSync(Bool), angleSnapping(Bool), rippleControl(Bool)
    case maxPerformance(Bool), maxPerformanceSeconds(Int)

    var write: (addr: UInt16, data: [UInt8])? {
        func one(_ a: UInt16, _ v: Int) -> (UInt16, [UInt8]) { (a, DecodedConfig.record([UInt8(v)])) }
        switch self {
        case .pollingRate(let hz):
            guard let code = DecodedConfig.pollingCodes.first(where: { $0.value == hz })?.key else { return nil }
            return one(0x00, Int(code))
        case .stageCount(let n): return (1...8).contains(n) ? one(0x02, n) : nil
        case .activeStage(let i): return (0..<8).contains(i) ? one(0x04, i) : nil
        case .dpi(let stage, let v): return (0..<8).contains(stage) ? (UInt16(0x0C + stage * 4), DecodedConfig.encodeDPI(v)) : nil
        case .lod(let i): return (0..<3).contains(i) ? one(0x0A, i) : nil
        case .sensorMode(let i): return (0..<3).contains(i) ? one(0xB9, i) : nil
        case .motionSync(let on): return one(0xAB, on ? 1 : 0)
        case .angleSnapping(let on): return one(0xAF, on ? 1 : 0)
        case .rippleControl(let on): return one(0xB1, on ? 1 : 0)
        case .maxPerformance(let on): return one(0xB5, on ? 1 : 0)
        case .maxPerformanceSeconds(let s): return (10...2550).contains(s) ? one(0xB7, s / 10) : nil
        }
    }
}

@MainActor
@Observable
final class MouseMonitor {
    enum State: Equatable { case needsPermission, searching, asleep, ready, error(String) }

    var state: State = .searching
    var deviceName = "Gravastar Mercury X Pro"
    var receiverName: String?
    var battery: Battery?
    var config = DecodedConfig()
    var measuredPollingRate: Int?
    var lastUpdated: Date?
    var rawMemory: [UInt8] = []
    var rawStatus: [UInt8] = []
    var rawPower: [UInt8] = []
    var writeError: String?
    var writing = false

    private let device = CompxDevice()
    private var timer: Timer?
    private var refreshing = false
    private var timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()

    var refreshInterval: TimeInterval = 60

    init() {
        device.onMotionReport = { [weak self] ts in self?.recordMotion(ts) }
        device.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.receiverName = connected ? self.device.productName : nil
            if connected, CompxDevice.hasPermission { Task { await self.refresh() } } else if !connected { self.state = .searching }
        }
        start()
    }

    func start() {
        guard CompxDevice.hasPermission else {
            state = .needsPermission
            CompxDevice.requestPermission()
            // 권한 부여 후 앱을 재시작하지 않아도 되도록 주기적으로 재확인
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard CompxDevice.hasPermission else { return }
                    t.invalidate()
                    self?.start()
                }
            }
            return
        }
        do {
            try device.start()
            state = .searching
            if device.isConnected { Task { await refresh() } }
        } catch {
            state = .error(error.localizedDescription)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard device.isConnected, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            rawStatus = try await device.send(.status)
            // 상태 응답 byte 6 == 0 → 수신기는 있으나 마우스가 연결/깨어 있지 않음
            if rawStatus.count > 6, rawStatus[6] == 0 {
                state = .asleep
                writeDiagnostics()
                return
            }
            rawPower = try await device.send(.power)
            if rawPower.count > 9, rawPower[6] <= 100 {
                battery = Battery(
                    percent: Int(rawPower[6]),
                    charging: rawPower[7] == 1 && rawPower[6] < 100,
                    millivolts: Int(rawPower[8]) << 8 | Int(rawPower[9]))
            }
            let chunks = await device.readMemory(from: 0, count: 0x100)
            var mem = [UInt8](repeating: 0, count: 0x100)
            for (addr, bytes) in chunks {
                for (i, b) in bytes.enumerated() where Int(addr) + i < mem.count { mem[Int(addr) + i] = b }
            }
            rawMemory = chunks.isEmpty ? [] : mem
            if !chunks.isEmpty { config = DecodedConfig(memory: mem) }
            lastUpdated = Date()
            state = .ready
        } catch DeviceError.permissionDenied {
            state = .needsPermission
        } catch DeviceError.timeout {
            state = .asleep
        } catch {
            state = .error(error.localizedDescription)
        }
        writeDiagnostics()
    }

    // MARK: 설정 쓰기

    /// 쓰고 다시 읽어 일치하는지 확인한 뒤, 메모리 사본과 화면 값을 갱신한다.
    func apply(_ settings: Setting...) async {
        guard state == .ready, !rawMemory.isEmpty else { return }
        writing = true
        writeError = nil
        defer { writing = false }
        for setting in settings {
            guard let w = setting.write else { writeError = "지원하지 않는 값입니다."; return }
            let (addr, data) = w
            do {
                let back = try await device.write(addr: addr, data: data)
                guard back == data else {
                    writeError = "마우스가 값을 반영하지 않았습니다."
                    break
                }
                for (i, b) in back.enumerated() { rawMemory[Int(addr) + i] = b }
                // 단계 수를 줄여 현재 단계가 범위를 벗어나면 마지막 단계로
                if case .stageCount(let n) = setting, Int(rawMemory[0x04]) >= n {
                    await apply(.activeStage(n - 1))
                }
            } catch {
                writeError = "쓰기 실패: \(error.localizedDescription)"
                break
            }
        }
        config = DecodedConfig(memory: rawMemory)
        writeDiagnostics()
    }

    // MARK: 실측 폴링레이트 — 마우스를 움직이는 동안 0x0B 리포트 간격으로 계산

    private var lastMotionNs: UInt64 = 0
    private var intervals: [UInt64] = []

    /// 리포트는 폴링 주기의 정수배 간격으로 오지만(움직임 없는 슬롯은 건너뜀) 도착 시각에 지터가 있어
    /// 개별 간격은 주기보다 짧게 찍히기도 한다. 연속 16개 간격의 평균은 지터가 상쇄되므로,
    /// 그 평균들 중 최솟값(= 빠르게 움직여 슬롯을 빠짐없이 채운 구간)을 폴링 주기로 본다.
    private func recordMotion(_ ts: UInt64) {
        let ns = ts &* UInt64(timebase.numer) / UInt64(timebase.denom)
        defer { lastMotionNs = ns }
        guard lastMotionNs != 0, ns > lastMotionNs else { return }
        let gap = ns - lastMotionNs
        guard gap < 20_000_000 else { return }  // 멈췄다 재개한 간격은 제외
        intervals.append(gap)
        guard intervals.count >= 400 else { return }
        let run = 16
        var sum = intervals[0..<run].reduce(0, +)
        var best = sum
        for i in run..<intervals.count {
            sum = sum + intervals[i] - intervals[i - run]  // 먼저 더해야 UInt64 언더플로가 없다
            best = min(best, sum)
        }
        intervals.removeAll(keepingCapacity: true)
        let hz = 1e9 / (Double(best) / Double(run))
        measuredPollingRate = [125, 250, 500, 1000, 2000, 4000, 8000]
            .min { abs(log(Double($0) / hz)) < abs(log(Double($1) / hz)) }
    }

    // MARK: 진단

    static var diagnosticsURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MercuryStatus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics.txt")
    }

    var diagnosticsText: String {
        func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
        var s = "MercuryStatus diagnostics — \(Date())\n"
        s += "receiver: \(receiverName ?? "-") pid=\(device.productID.map { String(format: "0x%04x", $0) } ?? "-")\n"
        s += String(format: "open: 0x%08x  permission: %@\n", device.openResult, CompxDevice.hasPermission ? "granted" : "denied")
        s += "state: \(state)\n"
        s += "status(0x03): \(hex(rawStatus))\npower(0x04):  \(hex(rawPower))\n"
        s += "measured polling: \(measuredPollingRate.map(String.init) ?? "-")\n"
        s += "decoded: \(config)\nmemory 0x0000-0x00ff:\n"
        for row in stride(from: 0, to: rawMemory.count, by: 16) {
            s += String(format: "%04x: ", row) + hex(Array(rawMemory[row..<min(row + 16, rawMemory.count)])) + "\n"
        }
        return s
    }

    private func writeDiagnostics() {
        try? diagnosticsText.write(to: Self.diagnosticsURL, atomically: true, encoding: .utf8)
    }
}
