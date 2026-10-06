import AppKit
import SwiftUI

final class SpeedProfiles: ObservableObject {
    @Published var pointerStep = min(11,max(1,UserDefaults.standard.object(forKey:"pointerStep") as? Int ?? 6)) {
        didSet { UserDefaults.standard.set(pointerStep,forKey:"pointerStep") }
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
    @Published var gameForeground = false
    private var observer: NSObjectProtocol?
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
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] _ in self?.refreshFocus() }
    }
    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    func refreshFocus() {
        let app = NSWorkspace.shared.frontmostApplication
        gameForeground = SpeedMath.isLeagueGame(bundleID:app?.bundleIdentifier,executable:app?.executableURL?.lastPathComponent)
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
            HStack {
                TextField("예: 800",text:$profiles.dpiInput).frame(width:140)
                Button("DPI 적용") { if let n = profiles.requestedDPI { profiles.leagueDPI = n } }
                    .disabled(profiles.requestedDPI == nil || DPIConversion.ratio(current:mice.current,target:profiles.requestedDPI ?? -1) == nil)
                Button("일반 DPI 사용") { profiles.leagueDPI = 0; profiles.dpiInput = "" }
            }
            Text(profiles.leagueDPI == 0 ? "일반 DPI 설정의 목표 DPI를 사용합니다." : "리그오브레전드에서만 \(profiles.leagueDPI) DPI 상당으로 보정합니다.")
                .font(.caption).foregroundStyle(.secondary)
            }.padding(.top,8)
            } label: { Text("게임 목표 DPI").font(.headline).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()).onTapGesture { leagueDPIExpanded.toggle() } }
            Text("일반 포인터 속도 \(profiles.pointerStep)/11 × 게임 추가 속도가 함께 적용됩니다.").font(.caption)
            Text(engine.active ? "잠금 실행 중 · 게임으로 돌아가면 자동 전환됩니다." : "기본 창에서 ‘활성화’를 켠 뒤 게임으로 돌아가세요.")
                .foregroundStyle(.teal).font(.subheadline)
            Text("0~100은 이 앱의 감도 조절값입니다(0=0.25배, 50=1배, 100=4배). 게임 내부 수치와 같은 배율을 보장하지 않습니다. 센서 DPI와 게임 파일은 변경하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:0)
        }.padding(12)
    }
}
