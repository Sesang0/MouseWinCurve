import AppKit
import SwiftUI
import ServiceManagement

final class LoginStartup: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var errorMessage: String?
    private var observer: NSObjectProtocol?
    var registered: Bool { status == .enabled || status == .requiresApproval }
    var description: String {
        switch status {
        case .enabled: return "로그인 시 자동 실행이 켜져 있습니다."
        case .requiresApproval: return "시스템 설정의 로그인 항목에서 승인이 필요합니다."
        case .notFound: return "자동 실행 등록 정보를 찾을 수 없습니다. 켜기 버튼으로 등록할 수 있습니다."
        case .notRegistered: return "로그인 시 자동 실행이 꺼져 있습니다."
        @unknown default: return "자동 실행 상태를 확인할 수 없습니다."
        }
    }
    init() {
        observer = NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.refresh() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func refresh() { status = SMAppService.mainApp.status }
    func toggle() {
        errorMessage = nil
        do {
            if registered { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { errorMessage = "자동 실행 변경 실패: \(error.localizedDescription)" }
        refresh()
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

struct LoginStartupView: View {
    @ObservedObject var startup: LoginStartup
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("시작 프로그램").font(.headline)
            HStack {
                Button(startup.registered ? "자동 실행 해제" : "로그인 시 자동 실행 켜기") { startup.toggle() }
                Button("로그인 항목 설정") { startup.openSettings() }
            }
            Text(startup.description).font(.caption).foregroundStyle(.secondary)
            if let error = startup.errorMessage { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(12)
    }
}
