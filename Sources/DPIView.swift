import SwiftUI

struct DPISettingsView: View {
    @ObservedObject var mice: MouseCatalog
    @ObservedObject var engine: MouseEngine
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("현재 DPI")
                TextField("예: 1000",text:$mice.manualDPI).frame(width:120).disabled(engine.active)
            }
            Text("현재 DPI는 직접 입력하세요. 마우스에서는 이름만 불러옵니다.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("목표 감도").font(.headline)
            HStack(spacing:10) {
                Text("목표 DPI")
                TextField("예: 1200",text:$mice.targetInput)
                    .frame(width:150)
                    .onSubmit { mice.applyTarget() }
                Button("감도 설정") { mice.applyTarget() }
                    .disabled(!mice.canApplyTarget)
            }
            Text(mice.targetInput.isEmpty || mice.requestedTarget != nil
                 ? "1–57,343 사이의 원하는 정수를 입력한 뒤 ‘감도 설정’을 누르세요."
                 : "목표 DPI는 1–57,343 사이의 정수여야 합니다. 기존 설정은 유지됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if mice.target == 0 { Text("보정 없음 · 원래 입력 유지") }
                else if let ratio = mice.ratio {
                    Text("\(mice.current ?? 0) → \(mice.target) DPI 상당 · \(ratio,specifier:"%.3f")배")
                } else { Text("현재 DPI를 확인하거나 입력하세요.") }
                Spacer()
                Button("보정 해제") { mice.target = 0 }
            }.font(.subheadline)
            Text(engine.active ? "선택한 감도를 잠금 영역에 적용 중입니다." : "감도 설정 후 기본 창의 ‘활성화’를 누르세요.")
                .font(.subheadline).foregroundStyle(.teal)
            Text("센서 DPI는 변경하지 않습니다. 목표/현재 비율로 이동량을 변환한 뒤 가속 곡선을 적용합니다. 낮은 센서 DPI를 높이는 경우 실제 고해상도 센서와 같은 정밀도는 얻을 수 없습니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(12)
    }
}
