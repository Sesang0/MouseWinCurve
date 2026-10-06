import AppKit
import IOKit.hid
import ApplicationServices

final class MouseEngine: ObservableObject {
    weak var dpiSettings: MouseCatalog?
    weak var speedProfiles: SpeedProfiles?
    @Published var active = false
    @Published var message = "해상도와 포인터 정확도 향상을 설정한 뒤 적용하세요."
    @Published var diagnostics = "아직 적용하지 않았습니다."
    @Published var lastGain = 1.0
    private var manager: IOHIDManager?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var region = CGRect.zero
    private var position = CGPoint.zero
    private var scaleX = 1.0, scaleY = 1.0
    private var enhanced = true
    private var lastRaw = 0.0
    private var missingSince: Double?
    private var nativeCount = 0
    private var pending: [(stamp: UInt64, device: IOHIDDevice, dx: Double, dy: Double)] = []
    private var drainScheduled = false
    private var gain = 1.0
    private var deliveredPosition = CGPoint.zero
    private var observers: [NSObjectProtocol] = []
    private var overlay: NSWindow?

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.stop("화면 구성이 변경되어 잠금을 해제했습니다.") })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.stop("잠자기 또는 사용자 전환으로 잠금을 해제했습니다.") })
        }
    }

    func permissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()
        diagnostics = "시스템 설정 → 개인정보 보호 및 보안에서 손쉬운 사용과 입력 모니터링을 허용하세요. 허용 후 앱을 완전히 종료하고 다시 실행하세요."
    }

    func start(width: Int, height: Int, display: CGDirectDisplayID, enhanced: Bool) {
        stop(nil)
        guard width >= 64, height >= 64 else { message = "가로·세로는 각각 64pt 이상의 정수여야 합니다."; return }
        guard CGDisplayIsActive(display) != 0, let mode = CGDisplayCopyDisplayMode(display) else { message = "선택한 화면을 찾을 수 없습니다."; return }
        let screen = CGDisplayBounds(display)
        guard Double(width) <= screen.width, Double(height) <= screen.height else {
            message = "영역이 화면보다 큽니다. 최대 \(Int(screen.width)) × \(Int(screen.height))pt입니다."; return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            message = "적용 불가: 손쉬운 사용 또는 입력 모니터링 권한이 없습니다. 아래 권한 버튼을 누르세요."; return
        }
        guard let dpi = dpiSettings, dpi.selected != 0 else { message = "첫 화면에서 연결된 마우스를 선택하세요."; return }
        guard (speedProfiles.map { $0.ratio(mice:dpi) } ?? dpi.ratio) != nil else { message = "목표 감도를 적용하려면 유효한 현재 DPI가 필요합니다. DPI 창을 확인하세요."; return }
        self.enhanced = enhanced
        scaleX = Double(mode.pixelWidth)/screen.width
        scaleY = Double(mode.pixelHeight)/screen.height
        let w = Double(width), h = Double(height)
        region = CGRect(x: screen.midX-w/2, y: screen.midY-h/2, width: w, height: h)
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(m, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<MouseEngine>.fromOpaque(context).takeUnretainedValue().receive(value)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<MouseEngine>.fromOpaque(context).takeUnretainedValue().stop("마우스 연결이 해제되어 잠금을 해제했습니다.")
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            stop("HID 입력 열기 실패 (\(result)). 입력 모니터링 권한을 확인한 뒤 앱을 재시작하세요."); return
        }
        let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> ?? []
        guard !devices.isEmpty else { stop("원시 HID 마우스를 찾지 못했습니다. USB/Bluetooth 마우스를 연결하세요. 트랙패드 전용 사용은 지원하지 않습니다."); return }
        let types: [CGEventType] = [.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.scrollWheel,.keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<MouseEngine>.fromOpaque(context).takeUnretainedValue().filter(type, event)
        }, userInfo: ctx) else {
            stop("이벤트 제어 권한을 얻지 못했습니다. 손쉬운 사용 권한을 확인하고 앱을 재시작하세요."); return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        position = CGPoint(x: region.midX, y: region.midY)
        deliveredPosition = position
        lastRaw = 0; nativeCount = 0; missingSince = nil
        active = true
        guard CGWarpMouseCursorPosition(position) == .success else { stop("포인터 위치 변경에 실패했습니다."); return }
        // A full-display lock needs no visible boundary.
        if Double(width) != screen.width || Double(height) != screen.height { showBorder() }
        message = "잠금 적용됨 · ⌘ Esc로 즉시 해제"
        let name = dpi.devices.first(where: { $0.id == dpi.selected })?.name ?? "마우스"
        diagnostics = "연결: \(name)\n영역 \(width) × \(height)pt (현재 화면 배율 기준)"
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.active else { return }
            if let t = self.tap, !CGEvent.tapIsEnabled(tap: t) { self.stop("이벤트 제어가 중단되어 안전하게 해제했습니다. 다시 적용하세요."); return }
            if !AXIsProcessTrusted() || !CGPreflightListenEventAccess() { self.stop("권한이 해제되어 잠금을 중단했습니다."); return }
            if let since = self.missingSince, CACurrentMediaTime()-since > 0.7, self.nativeCount > 3 {
                self.stop("포인터 이동은 감지됐지만 원시 HID 입력이 없습니다. 입력 모니터링 권한, 마우스 연결, 다른 마우스 제어 앱을 확인하세요."); return
            }
            self.lastGain = self.gain
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func receive(_ value: IOHIDValue) {
        guard active else { return }
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == kHIDPage_GenericDesktop,
              IOHIDElementIsRelative(element) else { return }
        let usage = IOHIDElementGetUsage(element)
        guard usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y else { return }
        dpiSettings?.observeMotion(value)
        let stamp = IOHIDValueGetTimeStamp(value), device = IOHIDElementGetDevice(element)
        guard MouseDevice.identifier(device) == dpiSettings?.selected else { return }
        let v = Double(IOHIDValueGetIntegerValue(value))
        // Pair X/Y from the same device and report timestamp, without mixing reports.
        if let i = pending.indices.last, pending[i].stamp == stamp, pending[i].device == device {
            if usage == kHIDUsage_GD_X { pending[i].dx += v } else { pending[i].dy += v }
        } else {
            pending.append((stamp,device,usage == kHIDUsage_GD_X ? v : 0,usage == kHIDUsage_GD_Y ? v : 0))
        }
        lastRaw = CACurrentMediaTime(); missingSince = nil; nativeCount = 0
        if !drainScheduled {
            drainScheduled = true
            // Common modes also run during AppKit's modal mouse tracking loop.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in self?.drain() }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func drain() {
        drainScheduled = false
        let batch = pending; pending.removeAll(keepingCapacity: true)
        guard active else { return }
        for report in batch {
            guard MouseDevice.identifier(report.device) == dpiSettings?.selected else { continue }
            guard let mice = dpiSettings, let ratio = speedProfiles.map({ $0.ratio(mice:mice) }) ?? mice.ratio else { stop("현재 DPI를 확인할 수 없어 감도 보정을 중지했습니다."); return }
            let dx = report.dx * ratio, dy = report.dy * ratio
            let speed = speedProfiles?.speed ?? 1
            gain = ratio * speed * (enhanced ? PointerCurve.gain(hypot(dx, dy)) : 1)
            position = PointerCurve.advance(position, dx: dx, dy: dy, enabled: enhanced, scaleX: scaleX, scaleY: scaleY, bounds: region, speed: speed)
            guard CGWarpMouseCursorPosition(position) == .success else { stop("포인터 이동 실패로 잠금을 해제했습니다."); return }
            // Native Quartz events are retargeted in filter(). Never synthesize a
            // parallel mouseMoved/drag stream: preserve native drag identity/order.

        }
    }

    private func filter(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stop("macOS가 이벤트 제어를 중지하여 잠금을 해제했습니다. 다시 적용하세요.")
            return Unmanaged.passUnretained(event)
        }
        guard active else { return Unmanaged.passUnretained(event) }
        if type == .keyDown {
            // The application-wide Carbon hotkey owns Command+Esc in both states.
            return Unmanaged.passUnretained(event)
        }
        if [.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged].contains(type) {
            if CACurrentMediaTime()-lastRaw > 0.15 {
                if missingSince == nil { missingSince = CACurrentMediaTime() }
                nativeCount += 1
            }
            // Flush available HID reports before forwarding the same native event.
            drain()
            guard active else { return Unmanaged.passUnretained(event) }
            PointerEvent.retarget(event, to: position, previous: deliveredPosition)
            deliveredPosition = position
            if CGWarpMouseCursorPosition(position) != .success { stop("포인터 제한 실패로 잠금을 해제했습니다.") }
            return Unmanaged.passUnretained(event)
        }
        drain()
        guard active else { return Unmanaged.passUnretained(event) }
        event.location = position // Preserve the native down/up sequence and metadata.
        return Unmanaged.passUnretained(event)
    }

    func stop(_ reason: String? = "잠금을 해제했습니다.") {
        active = false
        timer?.invalidate(); timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil; pending.removeAll(); missingSince = nil
        overlay?.orderOut(nil); overlay = nil
        if let reason { message = reason }
    }

    private func showBorder() {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let r = NSRect(x: region.minX, y: mainHeight-region.maxY, width: region.width, height: region.height)
        let window = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear
        window.ignoresMouseEvents = true; window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: r.size))
        view.wantsLayer = true; view.layer?.borderColor = NSColor.systemTeal.withAlphaComponent(0.7).cgColor; view.layer?.borderWidth = 1
        window.contentView = view; window.orderFrontRegardless(); overlay = window
    }
}
