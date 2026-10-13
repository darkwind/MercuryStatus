import SwiftUI
import AppKit

@main
struct MercuryStatusApp: App {
    @State private var monitor = MouseMonitor()

    var body: some Scene {
        MenuBarExtra {
            StatusView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let monitor: MouseMonitor

    var body: some View {
        if let b = monitor.battery, monitor.state == .ready {
            Image(systemName: b.charging ? "battery.100percent.bolt" : batterySymbol(b.percent))
            Text("\(b.percent)%")
        } else {
            Image(systemName: "computermouse")
        }
    }
}

func batterySymbol(_ p: Int) -> String {
    switch p {
    case ..<13: "battery.0percent"
    case ..<38: "battery.25percent"
    case ..<63: "battery.50percent"
    case ..<88: "battery.75percent"
    default: "battery.100percent"
    }
}

struct StatusView: View {
    let monitor: MouseMonitor
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            switch monitor.state {
            case .needsPermission: permissionView
            case .searching: message("수신기를 찾는 중…", "USB 수신기를 연결하거나 유선으로 연결하세요.", "cable.connector")
            case .asleep: message("마우스가 응답하지 않습니다", "절전 상태일 수 있습니다. 마우스를 움직인 뒤 새로고침하세요.", "moon.zzz")
            case .error(let e): message("오류", e, "exclamationmark.triangle")
            case .ready: readings
            }
            if showRaw { rawView }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Image(systemName: "computermouse.fill").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.deviceName).font(.headline)
                Text(monitor.receiverName.map { "\($0) 경유" } ?? "연결 안 됨")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var readings: some View {
        VStack(spacing: 10) {
            if let b = monitor.battery {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("배터리", systemImage: b.charging ? "bolt.fill" : batterySymbol(b.percent))
                        Spacer()
                        Text("\(b.percent)%").font(.title3.monospacedDigit().bold())
                    }
                    ProgressView(value: Double(b.percent), total: 100)
                        .tint(b.percent <= 20 ? .red : b.charging ? .green : .accentColor)
                    HStack {
                        Text(b.charging ? "충전 중" : "방전 중")
                        Spacer()
                        if b.millivolts > 0 { Text(String(format: "%.2f V", Double(b.millivolts) / 1000)) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            settingsPanel
        }
    }

    /// 값을 바꾸면 즉시 마우스에 쓰고 다시 읽어 검증하는 바인딩
    private func bind<T>(_ value: T, _ make: @escaping (T) -> Setting) -> Binding<T> {
        Binding(get: { value }, set: { v in Task { await monitor.apply(make(v)) } })
    }

    @ViewBuilder private var settingsPanel: some View {
        let c = monitor.config
        if c.verified {
            VStack(spacing: 8) {
                section("응답 속도")
                if let rate = c.pollingRate {
                    control("폴링레이트") {
                        Picker("", selection: bind(rate) { .pollingRate($0) }) {
                            ForEach(DecodedConfig.pollingRates, id: \.self) { Text(hz($0)).tag($0) }
                        }
                    }
                }
                HStack {
                    Text("실측")
                    if (monitor.measuredPollingRate ?? 0) >= 4000 {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                            .help("macOS가 4000Hz 이상 리포트를 묶어 전달해 실제보다 낮게 측정될 수 있습니다.")
                    }
                    Spacer()
                    Text(monitor.measuredPollingRate.map(hz) ?? "마우스를 움직여 보세요")
                        .monospacedDigit()
                        .foregroundStyle(monitor.measuredPollingRate == nil ? .secondary : .primary)
                }

                section("DPI")
                control("단계 수") {
                    Picker("", selection: bind(c.dpiStages.count) { .stageCount($0) }) {
                        ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                if !c.dpiStages.isEmpty { dpiStages }
                if let stage = c.activeStage, let dpi = c.activeDPI {
                    DPIEditor(stage: stage, dpi: dpi) { v in Task { await monitor.apply(.dpi(stage: stage, value: v)) } }
                }

                section("센서 설정")
                if let m = c.sensorMode.flatMap(DecodedConfig.sensorModes.firstIndex) {
                    control("센서 모드") {
                        Picker("", selection: bind(m) { .sensorMode($0) }) {
                            ForEach(DecodedConfig.sensorModes.indices, id: \.self) { Text(DecodedConfig.sensorModes[$0]).tag($0) }
                        }
                    }
                }
                if let l = c.lod.flatMap(DecodedConfig.lodNames.firstIndex) {
                    control("LOD") {
                        Picker("", selection: bind(l) { .lod($0) }) {
                            ForEach(DecodedConfig.lodNames.indices, id: \.self) { Text(DecodedConfig.lodNames[$0]).tag($0) }
                        }
                    }
                }
                if let on = c.maxPerformance {
                    toggle("최대 성능", on) { .maxPerformance($0) }
                    if on, let sec = c.maxPerformanceSeconds {
                        control("  유지 시간") {
                            Picker("", selection: bind(sec) { .maxPerformanceSeconds($0) }) {
                                ForEach(DecodedConfig.maxPerformanceSeconds, id: \.self) { Text(duration($0)).tag($0) }
                            }
                        }
                    }
                }
                if let v = c.rippleControl { toggle("리플 제어", v) { .rippleControl($0) } }
                if let v = c.angleSnapping { toggle("직선 보정", v) { .angleSnapping($0) } }
                if let v = c.motionSync { toggle("모션 싱크", v) { .motionSync($0) } }

                if let e = monitor.writeError {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.callout)
            .disabled(monitor.writing)
            .overlay(alignment: .topTrailing) { if monitor.writing { ProgressView().controlSize(.small) } }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
    }

    private func control<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(title)
            Spacer()
            content().labelsHidden().fixedSize()
        }
    }

    private func toggle(_ title: String, _ on: Bool, _ make: @escaping (Bool) -> Setting) -> some View {
        Toggle(title, isOn: bind(on, make)).toggleStyle(.switch).controlSize(.small)
    }

    /// 웹 UI처럼 단계별 DPI 아래에 LED 색 막대, 현재 단계는 강조. 클릭하면 해당 단계로 전환.
    private var dpiStages: some View {
        let c = monitor.config
        return HStack(spacing: 4) {
            ForEach(Array(c.dpiStages.enumerated()), id: \.offset) { i, d in
                let active = i == c.activeStage
                Button { Task { await monitor.apply(.activeStage(i)) } } label: {
                    VStack(spacing: 0) {
                        Text(d >= 10000 ? "\(d / 1000)k" : "\(d)")
                            .font(.caption2.monospacedDigit().weight(active ? .bold : .regular))
                            .frame(maxWidth: .infinity).padding(.vertical, 3)
                        Rectangle()
                            .fill(i < c.dpiColors.count ? Color(c.dpiColors[i]) : .secondary)
                            .frame(height: 3)
                    }
                    .background(Color.secondary.opacity(active ? 0.28 : 0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(active ? Color.primary.opacity(0.6) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(d) DPI — 클릭하면 이 단계로 전환")
            }
        }
    }

    private func duration(_ sec: Int) -> String { sec < 60 ? "\(sec)초" : "\(sec / 60)분" }

    private func hz(_ v: Int) -> String { "\(v) Hz" }

    private func row(_ title: String, icon: String, value: String, note: String?) -> some View {
        HStack {
            Label(title, systemImage: icon)
            if let note {
                Text(note).font(.caption2).foregroundStyle(.orange)
                    .padding(.horizontal, 4).background(.orange.opacity(0.12), in: Capsule())
            }
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(value.hasPrefix("마우스") ? .secondary : .primary)
        }
    }

    private var permissionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("입력 모니터링 권한 필요", systemImage: "lock.shield").font(.subheadline.bold())
            Text("마우스 상태를 읽으려면 시스템 설정 › 개인정보 보호 및 보안 › 입력 모니터링에서 MercuryStatus를 허용하세요. 허용하면 자동으로 다시 연결합니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("시스템 설정 열기") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            }
        }
    }

    private func message(_ title: String, _ detail: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.subheadline.bold())
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rawView: some View {
        ScrollView {
            Text(monitor.diagnosticsText)
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 180)
    }

    private var footer: some View {
        HStack {
            if let t = monitor.lastUpdated {
                Text("업데이트 \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showRaw.toggle() } label: { Image(systemName: "ladybug") }
                .buttonStyle(.borderless).help("진단 정보")
            Button { Task { await monitor.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("새로고침")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).help("종료")
        }
    }
}

extension Color {
    init(_ c: RGB) { self.init(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255) }
}

/// 현재 단계의 DPI 값 편집. Enter 또는 ± 버튼으로 적용 (25600 이하 50 단위, 초과 100 단위).
struct DPIEditor: View {
    let stage: Int
    let dpi: Int
    let commit: (Int) -> Void
    @State private var text = ""

    private func step(_ d: Int, up: Bool) -> Int {
        let s = (up ? d >= 25600 : d > 25600) ? 100 : 50
        return min(max(d + (up ? s : -s), DecodedConfig.dpiRange.lowerBound), DecodedConfig.dpiRange.upperBound)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(stage + 1)단계 DPI")
            Spacer()
            Button { commit(step(dpi, up: false)) } label: { Image(systemName: "minus") }
            TextField("", text: $text)
                .multilineTextAlignment(.trailing).monospacedDigit()
                .frame(width: 64)
                .onSubmit {
                    if let v = Int(text.filter(\.isNumber)) { commit(v) } else { text = "\(dpi)" }
                }
            Button { commit(step(dpi, up: true)) } label: { Image(systemName: "plus") }
        }
        .buttonStyle(.borderless)
        .onAppear { text = "\(dpi)" }
        .onChange(of: dpi) { text = "\(dpi)" }
        .onChange(of: stage) { text = "\(dpi)" }
    }
}
