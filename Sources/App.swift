import SwiftUI
import AppKit
import Carbon

struct DisplayOption: Identifiable {
    var id: CGDirectDisplayID
    var name: String
    var width: Int
    var height: Int
}
struct CurveChart: View {
    var enabled: Bool
    var body: some View {
        GeometryReader { g in
            let w = g.size.width-38, h = g.size.height-25
            ZStack(alignment: .topLeading) {
                Path { p in
                    for i in 0...5 {
                        let y = h*Double(i)/5
                        p.move(to: CGPoint(x: 30,y:y)); p.addLine(to: CGPoint(x:w+30,y:y))
                    }
                    for i in 0...5 {
                        let x = 30+w*Double(i)/5
                        p.move(to: CGPoint(x:x,y:0)); p.addLine(to: CGPoint(x:x,y:h))
                    }
                }.stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                Path { p in
                    for i in 0...150 {
                        let x = Double(i)/2
                        let y = enabled ? PointerCurve.gain(x) : 1
                        let v = CGPoint(x:30+w*x/75,y:h*(1-y/2.5))
                        if i == 0 { p.move(to:v) } else { p.addLine(to:v) }
                    }
                }.stroke(enabled ? Color.teal : Color.secondary, style: StrokeStyle(lineWidth: 2.5,lineCap:.round))
                Text("2.5×").font(.caption2).foregroundStyle(.secondary).offset(x:0,y:-6)
                Text("0").font(.caption2).foregroundStyle(.secondary).offset(x:15,y:h-8)
                Text("0").font(.caption2).foregroundStyle(.secondary).offset(x:28,y:h+5)
                Text("75").font(.caption2).foregroundStyle(.secondary).offset(x:w+18,y:h+5)
                Text("입력 이동량 / HID 보고 1회").font(.caption2).foregroundStyle(.secondary).position(x:30+w/2,y:h+13)
            }
        }.frame(height:145)
    }
}
final class DisplaySettings: ObservableObject {
    @Published var displays: [DisplayOption] = []
    @Published var display = CGMainDisplayID()
}
struct SettingsView: View {
    @ObservedObject var engine: MouseEngine
    @AppStorage("logicalWidth") var width = ""
    @AppStorage("logicalHeight") var height = ""
    @AppStorage("enhance") var enhance = true
    @AppStorage("curveExpanded") private var curveExpanded = false
    @AppStorage("dpiExpanded") private var dpiExpanded = false
    @AppStorage("otherSettingsExpanded") private var otherSettingsExpanded = false
    @ObservedObject var settings: DisplaySettings
    @ObservedObject var mice: MouseCatalog
    @ObservedObject var profiles: SpeedProfiles
    @ObservedObject var startup: LoginStartup
    var openLeague: () -> Void
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:18) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width:44,height:44)
                VStack(alignment:.leading,spacing:4) {
                    Text("MouseWinCurve").font(.title2.bold())
                }
                Spacer()
                Text(engine.waitingForGame ? "게임 대기" : (engine.active ? "잠금 중" : "대기")).font(.caption.bold()).padding(8)
                    .background(engine.active ? Color.teal.opacity(0.18) : Color.secondary.opacity(0.12)).clipShape(Capsule())
                if engine.active { Button("비활성화") { engine.stop() }
                    .buttonStyle(.borderedProminent).tint(Color(red:0.88,green:0.32,blue:0.36)).foregroundColor(.black) }
                else {
                    Button("활성화") {
                        guard let w = Int(width.trimmingCharacters(in:.whitespaces)), let h = Int(height.trimmingCharacters(in:.whitespaces)) else { engine.message = "해상도는 정수로 입력하세요."; return }
                        engine.start(width:w,height:h,display:settings.display,enhanced:enhance)
                    }.buttonStyle(.borderedProminent).tint(.teal)
                }
            }
            Picker("연결된 마우스",selection:Binding(get:{mice.selected},set:{mice.choose($0)})) {
                if mice.devices.isEmpty { Text("연결된 마우스 없음").tag(UInt64(0)) }
                ForEach(Array(mice.devices.enumerated()),id: \.element.id) { index, d in Text("\(index + 1). \(d.name)").tag(d.id) }
            }.disabled(engine.active)
            GroupBox {
                VStack(alignment:.leading,spacing:12) {
                    Text("01  포인터 제한 영역").font(.headline)
                    Picker("디스플레이",selection:$settings.display) {
                        ForEach(settings.displays) { d in Text("\(d.name) · \(d.width) × \(d.height)pt").tag(d.id) }
                    }
                    HStack {
                        Text("해상도")
                        TextField("가로",text:$width).frame(width:95)
                        Text("×").foregroundStyle(.secondary)
                        TextField("세로",text:$height).frame(width:95)
                        Text("pt").foregroundStyle(.secondary)
                        Spacer()
                        Button("화면 전체") { if let d = settings.displays.first(where:{$0.id == settings.display}) { width = String(d.width); height = String(d.height) } }
                    }
                    Text("현재 디스플레이 배율이 반영된 크기(pt)입니다. 선택한 화면의 중앙에 영역을 만듭니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }.disabled(engine.active)
            GroupBox {
                VStack(alignment:.leading,spacing:12) {
                    HStack {
                        Text("포인터 속도 선택").font(.headline)
                        Spacer()
                        Text("\(profiles.pointerStep)/11 · \(SpeedMath.pointer(profiles.pointerStep),specifier:"%.3f")×").monospacedDigit()
                    }
                    Slider(value:Binding(get:{Double(profiles.pointerStep)},set:{profiles.pointerStep = Int($0.rounded())}),in:1...11,step:1)
                    HStack {
                        ForEach(1...11,id: \.self) { step in
                            Rectangle().fill(step == profiles.pointerStep ? Color.teal : Color.secondary.opacity(0.5))
                                .frame(width:1,height:step == 6 ? 8 : 5)
                            if step < 11 { Spacer() }
                        }
                    }.padding(.horizontal,8)
                    HStack { Text("느림"); Spacer(); Text("기본 6/11"); Spacer(); Text("빠름") }.font(.caption).foregroundStyle(.secondary)
                    Toggle("02  포인터 정확도 향상",isOn:$enhance).font(.headline).toggleStyle(.switch)
                    Text(enhance ? "첨부 그래프 근사 곡선 · 곡선 배율 × 선택 속도" : "가속 끔 · DPI 비율 × 선택 속도 적용")
                        .font(.subheadline).foregroundStyle(.secondary)
                    DisclosureGroup(isExpanded:$curveExpanded) {
                        CurveChart(enabled:enhance).padding(.top,10)
                    } label: {
                        Text("가속 그래프").frame(maxWidth:.infinity,alignment:.leading)
                            .contentShape(Rectangle()).onTapGesture { curveExpanded.toggle() }
                    }
                    Text("보고 1회당 이동량에 적용합니다. DPI·폴링레이트에 따라 체감이 달라지며 Windows와의 완전한 일치는 보장하지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }.disabled(engine.active)
            GroupBox {
                DisclosureGroup(isExpanded:$dpiExpanded) {
                    DPISettingsView(mice:mice,engine:engine)
                } label: {
                    Text("DPI 설정").font(.headline).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()).onTapGesture { dpiExpanded.toggle() }
                }.padding(12)
            }
            VStack(alignment:.leading,spacing:8) {
                Label(engine.message,systemImage:engine.active ? "lock.fill" : "info.circle").font(.subheadline)
                    .fixedSize(horizontal:false,vertical:true)
                Text("수신 이동 보고: \(engine.inputRate) Hz · 장치가 보내는 입력 주기로 처리")
                    .font(.caption).foregroundStyle(.secondary)
                Text(engine.diagnostics).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Text("현재 배율 \(engine.lastGain,specifier:"%.2f")×")
                    Spacer()
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(12).background(Color.secondary.opacity(0.07)).cornerRadius(10)
            GroupBox {
                DisclosureGroup(isExpanded:$otherSettingsExpanded) {
                VStack(alignment:.leading,spacing:12) {
                    LoginStartupView(startup:startup)
                    Divider()
                    Text("⌘ Esc · 활성화 / 비활성화   /   ⌘ Q · 앱 종료")
                        .font(.callout).padding(.horizontal,12)
                    HStack {
                        Button("권한 설정") { engine.permissions() }
                        Button("입력 모니터링 열기") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!) }
                    }.padding(.horizontal,12).padding(.bottom,12)
                }
                } label: { Text("기타 설정").font(.headline).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()).onTapGesture { otherSettingsExpanded.toggle() } }.padding(12)
            }
            GroupBox {
                HStack {
                    Text("리그오브레전드 설정").font(.headline)
                    Spacer()
                    Button("설정 열기",action:openLeague)
                }.padding(12)
            }
        }.padding(24).frame(width:620) }.frame(width:620,height: min(980, (NSScreen.main?.visibleFrame.height ?? 940)-60))
        .onAppear { reloadDisplays() }
        .onChange(of: settings.display) { _ in fitResolution() }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didChangeScreenParametersNotification)) { _ in reloadDisplays() }
    }
    func fitResolution(forceFull: Bool = false) {
        guard let d = settings.displays.first(where: { $0.id == settings.display }) else { return }
        if forceFull || width.isEmpty || height.isEmpty {
            width = String(d.width); height = String(d.height)
        } else {
            if let w = Int(width), w > d.width { width = String(d.width) }
            if let h = Int(height), h > d.height { height = String(d.height) }
        }
    }
    func reloadDisplays() {
        let old = settings.displays.first(where: { $0.id == settings.display })
        let wasFull = old.map { Int(width) == $0.width && Int(height) == $0.height } ?? false
        settings.displays = NSScreen.screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let bounds = CGDisplayBounds(n.uint32Value)
            return DisplayOption(id:n.uint32Value,name:s.localizedName,width:Int(bounds.width),height:Int(bounds.height))
        }
        if !settings.displays.contains(where:{$0.id == settings.display}) { settings.display = settings.displays.first?.id ?? CGMainDisplayID() }
        fitResolution(forceFull: wasFull)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let engine = MouseEngine()
    let settings = DisplaySettings()
    let mice = MouseCatalog()
    let profiles = SpeedProfiles()
    let startup = LoginStartup()
    var leagueWindow: NSWindow!
    var window: NSWindow!
    var statusItem: NSStatusItem!
    private var localShortcutMonitor: Any?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private func registerToggleShortcut() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape), event.modifierFlags.contains(.command) else { return event }
            if !event.isARepeat { self?.toggleActivation() }
            return nil
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().toggleActivation()
            return noErr
        }, 1, &type, context, &hotKeyHandler)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(cmdKey), EventHotKeyID(signature:0x4D574356,id:1), GetApplicationEventTarget(), 0, &hotKey)
        if handlerStatus != noErr || status != noErr { engine.message = "Command+Esc 단축키 등록 실패. 화면의 활성화 버튼을 사용하세요." }
    }
    @objc func toggleActivation() {
        if engine.active { engine.stop(); return }
        let defaults = UserDefaults.standard
        guard let w = Int(defaults.string(forKey:"logicalWidth") ?? ""),
              let h = Int(defaults.string(forKey:"logicalHeight") ?? "") else {
            engine.message = "해상도는 정수로 입력하세요."; showSettings(); return
        }
        engine.start(width:w,height:h,display:settings.display,enhanced:defaults.object(forKey:"enhance") as? Bool ?? true)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle:"MouseWinCurve 종료",action:#selector(quit),keyEquivalent:"q").target = self
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title:"편집"); editItem.submenu = editMenu
        editMenu.addItem(withTitle:"잘라내기",action:Selector(("cut:")),keyEquivalent:"x")
        editMenu.addItem(withTitle:"복사",action:Selector(("copy:")),keyEquivalent:"c")
        editMenu.addItem(withTitle:"붙여넣기",action:Selector(("paste:")),keyEquivalent:"v")
        editMenu.addItem(withTitle:"전체 선택",action:Selector(("selectAll:")),keyEquivalent:"a")
        NSApp.mainMenu = mainMenu
        engine.dpiSettings = mice
        engine.speedProfiles = profiles
        profiles.onLockPolicyChanged = { [weak self] in self?.engine.syncGameLock() }
        mice.onUnavailable = { [weak self] in
            if self?.engine.active == true { self?.engine.stop("마우스 또는 DPI 정보를 사용할 수 없어 잠금을 해제했습니다.") }
        }
        leagueWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:620),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        leagueWindow.title = "리그오브레전드 설정"
        leagueWindow.isReleasedWhenClosed = false
        leagueWindow.contentView = NSHostingView(rootView:ScrollView { LeagueSettingsView(mice:mice,engine:engine,profiles:profiles) }.frame(width:600,height:620))
        leagueWindow.center()
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:980),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "MouseWinCurve"
        window.contentView = NSHostingView(rootView:SettingsView(engine:engine,settings:settings,mice:mice,profiles:profiles,startup:startup,openLeague:{ [weak self] in self?.showLeague() }))
        window.center(); window.delegate = self; window.isReleasedWhenClosed = false
        if let iconURL = Bundle.main.url(forResource:"AppIcon",withExtension:"icns"), let icon = NSImage(contentsOf:iconURL) { NSApp.applicationIconImage = icon }
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        if let url = Bundle.main.url(forResource:"MenuIcon",withExtension:"png"), let icon = NSImage(contentsOf:url) {
            icon.size = NSSize(width:18,height:18); icon.isTemplate = true
            statusItem.button?.image = icon
        } else { statusItem.button?.image = NSImage(systemSymbolName:"computermouse",accessibilityDescription:"MouseWinCurve") }
        statusItem.button?.toolTip = "MouseWinCurve · ⌘ Esc로 활성화 / 비활성화"
        let menu = NSMenu()
        menu.addItem(withTitle:"설정 창 열기",action:#selector(showSettings),keyEquivalent:"").target = self
        menu.addItem(withTitle:"리그오브레전드 설정",action:#selector(showLeague),keyEquivalent:"").target = self
        menu.addItem(withTitle:"비활성화",action:#selector(unlock),keyEquivalent:"").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle:"종료",action:#selector(quit),keyEquivalent:"q").target = self
        statusItem.menu = menu
        showSettings()
        registerToggleShortcut()
    }
    @objc func showLeague() { leagueWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
    @objc func showSettings() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
    @objc func unlock() { engine.stop() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification:Notification) {
        if let localShortcutMonitor { NSEvent.removeMonitor(localShortcutMonitor) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        engine.stop(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool { showSettings(); return true }
}

@main struct Launcher {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
