import AppKit
import SwiftUI

final class SpeedProfiles: ObservableObject {
    @Published var pointerStep = min(11,max(1,UserDefaults.standard.object(forKey:"pointerStep") as? Int ?? 6)) {
        didSet { UserDefaults.standard.set(pointerStep,forKey:"pointerStep") }
    }
    @Published var followGameWindow = UserDefaults.standard.bool(forKey:"followGameWindow") {
        didSet { UserDefaults.standard.set(followGameWindow,forKey:"followGameWindow"); refreshFocus(); onLockPolicyChanged?() }
    }
    @Published private(set) var gameWindowBounds: CGRect?
    private var windowTimer: Timer?
    private let windowQueue = DispatchQueue(label:"local.mouselockcurve.window-query",qos:.userInitiated)
    private var windowQueryInFlight = false
    private var windowTitleCache = WindowTitleCache() // accessed only by windowQueue
    private var windowMisses = 0
    private var trackedPID: pid_t?
    private var windowGeneration: UInt64 = 0
    var waitsForGame: Bool {
        (leagueOnlyLock || leagueFullscreenLock || followGameWindow) &&
        (!gameForeground || (followGameWindow && gameWindowBounds == nil))
    }
    var onLockPolicyChanged: (() -> Void)?
    @Published var leagueFullscreenLock = UserDefaults.standard.bool(forKey:"leagueFullscreenLock") {
        didSet { UserDefaults.standard.set(leagueFullscreenLock,forKey:"leagueFullscreenLock"); onLockPolicyChanged?() }
    }
    @Published var leagueOnlyLock = UserDefaults.standard.bool(forKey:"leagueOnlyLock") {
        didSet { UserDefaults.standard.set(leagueOnlyLock,forKey:"leagueOnlyLock"); onLockPolicyChanged?() }
    }
    @Published var leagueEnabled = UserDefaults.standard.bool(forKey:"leagueEnabled") {
        didSet { UserDefaults.standard.set(leagueEnabled,forKey:"leagueEnabled") }
    }
    @Published var leagueSpeed = min(100,max(0,UserDefaults.standard.object(forKey:"leagueSpeed") as? Int ?? 50)) {
        didSet { UserDefaults.standard.set(leagueSpeed,forKey:"leagueSpeed"); leagueSpeedInput = String(leagueSpeed) }
    }
    @Published var leagueSpeedInput = ""
    func applySpeedInput() {
        if let value = Int(leagueSpeedInput.trimmingCharacters(in:.whitespaces)), (0...100).contains(value) {
            leagueSpeed = value
        }
        leagueSpeedInput = String(leagueSpeed)
    }
    @Published var leagueDPI = UserDefaults.standard.integer(forKey:"leagueDPI") {
        didSet { UserDefaults.standard.set(leagueDPI,forKey:"leagueDPI") }
    }
    @Published var dpiInput = ""
    @Published var gameForeground = false { didSet { if oldValue != gameForeground { onLockPolicyChanged?() } } }
    private var observers: [NSObjectProtocol] = []
    var appliesLeague: Bool { leagueEnabled && gameForeground }
    var requestedDPI: Int? {
        guard let n = Int(dpiInput.trimmingCharacters(in:.whitespaces)), (1...57343).contains(n) else { return nil }
        return n
    }
    init() {
        leagueSpeedInput = String(leagueSpeed)
        if !(0...57343).contains(leagueDPI) { leagueDPI = 0 }
        dpiInput = leagueDPI == 0 ? "" : String(leagueDPI)
        refreshFocus()
        windowTimer = Timer(timeInterval:0.1,repeats:true) { [weak self] _ in
            guard let self, self.followGameWindow else { return }
            self.refreshFocus()
        }
        if let windowTimer { RunLoop.main.add(windowTimer,forMode:.common) }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.refreshFocus() })
        }
    }
    deinit { windowTimer?.invalidate(); for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    func refreshFocus() {
        let app = NSWorkspace.shared.frontmostApplication
        let isGame = SpeedMath.isLeagueGame(bundleID:app?.bundleIdentifier,executable:app?.executableURL?.lastPathComponent)
        let pid = isGame && followGameWindow ? app?.processIdentifier : nil
        if pid != trackedPID {
            trackedPID = pid; windowGeneration &+= 1; windowMisses = 0
            if gameWindowBounds != nil { gameWindowBounds = nil; onLockPolicyChanged?() }
        }
        if gameForeground != isGame { gameForeground = isGame }
        guard let pid, !windowQueryInFlight else { return }
        windowQueryInFlight = true
        let token = windowGeneration
        // AppKit objects stay on main. Only immutable geometry crosses the queue.
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return CGDisplayBounds(id)
        }
        let sample = NSRect(x:0,y:0,width:400,height:300)
        let titleHeight = max(28, NSWindow.frameRect(forContentRect:sample,styleMask:.titled).height-sample.height)
        windowQueue.async { [weak self] in
            // AX IPC can wait for the game. Never run it on the HID/event-tap loop.
            guard let self else { return }
            let bounds = GameWindow.bounds(pid:pid,displays:displays,fallbackTitleHeight:titleHeight,titleCache:&self.windowTitleCache)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.windowQueryInFlight = false
                guard self.windowGeneration == token, self.trackedPID == pid,
                      self.followGameWindow,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                let visible = bounds.flatMap { r in displays.contains(where: { $0.intersects(r) }) ? r : nil }
                // A single WindowServer query miss must not stop/restart the HID
                // pipeline and discard fractional motion during a slow movement.
                if visible == nil {
                    self.windowMisses += 1
                    if self.windowMisses < 3 { return }
                } else { self.windowMisses = 0 }
                if self.gameWindowBounds != visible {
                    self.gameWindowBounds = visible
                    self.onLockPolicyChanged?()
                }
            }
        }
    }

    func ratio(mice: MouseCatalog) -> Double? {
        if appliesLeague && leagueDPI > 0 { return DPIConversion.ratio(current:mice.current,target:leagueDPI) }
        return mice.ratio
    }
    var speed: Double { SpeedMath.pointer(pointerStep) * (appliesLeague ? SpeedMath.league(leagueSpeed) : 1) }
}

struct LeagueSettingsView: View {
    @AppStorage("leagueDPIExpanded") private var leagueDPIExpanded = false
    @ObservedObject var mice: MouseCatalog
    @ObservedObject var engine: MouseEngine
    @ObservedObject var profiles: SpeedProfiles
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("리그오브레전드 설정").font(.title3.bold()).foregroundStyle(Color(red:0.68,green:0.55,blue:0.29))
                Spacer()
                Button("기본값 복원") { profiles.leagueSpeed = 50; profiles.leagueDPI = 0; profiles.dpiInput = "" }
            }
            Toggle("리그오브레전드 게임에서만 화면 잠금",isOn:$profiles.leagueOnlyLock)
            Text("앱을 활성화하면 게임을 기다립니다. 실제 게임이 앞에 있을 때만 잠그며, 다른 앱으로 전환하거나 게임을 종료하면 해제합니다. 런처는 제외합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("롤 창에 맞춰 제한 영역 자동 이동",isOn:Binding(get:{profiles.followGameWindow},set:{ value in
                if value { profiles.leagueFullscreenLock = false }
                profiles.followGameWindow = value
            }))
            Text("제목 표시줄을 제외한 게임 영역을 따라갑니다. 제목 영역을 읽지 못하면 상단 기본 높이를 제외합니다. 창을 찾지 못하거나 다른 앱으로 전환하면 제한을 해제합니다. 여러 화면에 걸친 창은 가장 많이 겹치는 화면 안의 영역을 사용합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("전체화면용 디스플레이 전체 잠금",isOn:Binding(get:{profiles.leagueFullscreenLock},set:{ value in
                if value { profiles.followGameWindow = false }
                profiles.leagueFullscreenLock = value
            }))
            Text("게임을 전체화면으로 설정한 뒤 켜세요. 선택한 디스플레이 전체를 잠금 경계로 사용합니다. 창모드를 자동 판별하지 않으며, 다른 앱에서는 제한을 해제합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("리그오브레전드 게임이 활성화되면 전용 감도 사용",isOn:$profiles.leagueEnabled)
            Text(profiles.appliesLeague ? "리그오브레전드 게임 감지 · 전용 설정 선택됨" : "대기 · 실제 게임이 맨 앞에 있을 때만 적용됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("마우스 이동 속도")
                Spacer()
                TextField("0–100",text:$profiles.leagueSpeedInput,onEditingChanged: { editing in
                    if !editing { profiles.applySpeedInput() }
                }).onSubmit { profiles.applySpeedInput() }
                    .frame(width:60).multilineTextAlignment(.trailing).monospacedDigit()
                    .accessibilityLabel("마우스 이동 속도 직접 입력")
                    .help("0~100 정수를 입력하고 Enter를 누르세요. 범위를 벗어나면 이전 값으로 돌아갑니다.")
            }
            Slider(value:Binding(get:{Double(profiles.leagueSpeed)},set:{profiles.leagueSpeed = Int($0.rounded())}),in:0...100,step:1)
                .tint(Color(red:0.68,green:0.55,blue:0.29))
            HStack { Text("느림 · 0"); Spacer(); Text("기본 · 50"); Spacer(); Text("빠름 · 100") }.font(.caption).foregroundStyle(.secondary)
            Text("추가 속도 배율 \(SpeedMath.league(profiles.leagueSpeed),specifier:"%.2f")×")
            Divider()
            DisclosureGroup(isExpanded:$leagueDPIExpanded) {
            VStack(alignment:.leading,spacing:12) {
            Text("현재 DPI: \(mice.current.map(String.init) ?? "직접 입력 필요") · 첫 화면 DPI 설정과 공유")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment:.firstTextBaseline,spacing:10) {
                Text("목표 DPI").frame(width:70,alignment:.leading)
                TextField("예: 800",text:$profiles.dpiInput).frame(width:140)
                Button("DPI 적용") { if let n = profiles.requestedDPI { profiles.leagueDPI = n } }
                    .disabled(profiles.requestedDPI == nil || DPIConversion.ratio(current:mice.current,target:profiles.requestedDPI ?? -1) == nil)
                Button("일반 DPI 사용") { profiles.leagueDPI = 0; profiles.dpiInput = "" }
            }
            Text(profiles.leagueDPI == 0 ? "일반 DPI 설정의 목표 DPI를 사용합니다." : "리그오브레전드에서만 \(profiles.leagueDPI) DPI 상당으로 보정합니다.")
                .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(.top,8)
            } label: { Text("게임 목표 DPI").font(.headline).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()).onTapGesture { leagueDPIExpanded.toggle() } }
            Text("일반 포인터 속도 \(profiles.pointerStep)/11 × 게임 추가 속도가 함께 적용됩니다.").font(.caption)
            Text(engine.active ? "잠금 실행 중 · 게임으로 돌아가면 자동 전환됩니다." : "기본 창에서 ‘활성화’를 켠 뒤 게임으로 돌아가세요.")
                .foregroundStyle(.teal).font(.subheadline)
            Text("0~100은 이 앱의 감도 조절값입니다(0=0.25배, 50=1배, 100=4배). 게임 내부 수치와 같은 배율을 보장하지 않습니다. 센서 DPI와 게임 파일은 변경하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:0)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
    }
}
