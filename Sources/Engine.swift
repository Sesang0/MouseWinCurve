import AppKit
import IOKit.hid
import ApplicationServices

final class MouseEngine: ObservableObject {
    weak var dpiSettings: MouseCatalog?
    weak var speedProfiles: SpeedProfiles?
    @Published var active = false
    @Published var waitingForGame = false
    @Published var inputRate = 0
    private var reportMeter = HIDRateMeter()
    private var rateStart = 0.0
    private var requested: (width:Int,height:Int,display:CGDirectDisplayID,enhanced:Bool)?

    func syncGameLock() {
        guard active, let config = requested else { return }
        let shouldWait = speedProfiles?.waitsForGame ?? false
        if shouldWait && !waitingForGame {
            stop(nil)
            requested = config; active = true; waitingForGame = true
            message = "게임 대기 중 · 화면 제한 없음 · ⌘ Esc로 비활성화"
        } else if !shouldWait && (waitingForGame || usingFullscreen != (speedProfiles?.leagueFullscreenLock ?? false) || usingWindowFollow != (speedProfiles?.followGameWindow ?? false)) {
            start(width:config.width,height:config.height,display:config.display,enhanced:config.enhanced)
        } else if !shouldWait && usingWindowFollow {
            updateWindowRegion()
        }
    }
    @Published var message = "해상도와 포인터 정확도 향상을 설정한 뒤 적용하세요."
    @Published var diagnostics = "아직 적용하지 않았습니다."
    @Published var lastGain = 1.0
    private var manager: IOHIDManager?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var usingWindowFollow = false
    private var usingFullscreen = false
    private var region = CGRect.zero
    private var position = CGPoint.zero
    private var scaleX = 1.0, scaleY = 1.0
    private var enhanced = true
    private var lastRaw = 0.0
    private var missingSince: Double?
    private var nativeCount = 0
    private var pending: [(stamp: UInt64, device: IOHIDDevice, dx: Double, dy: Double)] = []
    private var inputSession = InputSession()
    private var activationStamp: UInt64 = 0
    private var gain = 1.0
    private var deliveredPosition = CGPoint.zero
    private var observers: [NSObjectProtocol] = []
    private var overlay: NSWindow?

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.screenChanged() })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.stop("잠자기 또는 사용자 전환으로 잠금을 해제했습니다.") })
        }
    }

    private func updateWindowRegion() {
        guard let rect = speedProfiles?.gameWindowBounds,
              let display = GameWindow.display(for:rect), let mode = CGDisplayCopyDisplayMode(display) else { return }
        let screen = CGDisplayBounds(display), clipped = rect.intersection(CGDisplayBounds(display))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }
        scaleX = Double(mode.pixelWidth)/screen.width; scaleY = Double(mode.pixelHeight)/screen.height
        if region != clipped {
            region = clipped
            let previousPosition = position
            position = PointerCurve.advance(position,dx:0,dy:0,enabled:false,scaleX:scaleX,scaleY:scaleY,bounds:region)
            overlay?.orderOut(nil); overlay = nil
            // Do not overlay the game or move the cursor to the center during tracking.
            diagnostics = "롤 창 추적 · 영역 \(Int(region.width)) × \(Int(region.height))pt"
            if position != previousPosition {
                deliveredPosition = position
                if CGWarpMouseCursorPosition(position) != .success { stop("롤 창의 포인터 위치 변경에 실패했습니다.") }
            }
        }
    }

    private func screenChanged() {
        guard active, (speedProfiles?.leagueFullscreenLock == true || speedProfiles?.followGameWindow == true), let config = requested else {
            stop("화면 구성이 변경되어 잠금을 해제했습니다."); return
        }
        stop(nil)
        requested = config; active = true; waitingForGame = true
        message = "화면 모드 변경 중 · 게임 잠금 재적용 대기"
        let token = inputSession.generation
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in
            guard let self, self.inputSession.generation == token else { return }
            self.syncGameLock()
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
        let follow = speedProfiles?.followGameWindow ?? false
        let originalDisplay = display
        let display = follow ? (speedProfiles?.gameWindowBounds.flatMap { GameWindow.display(for:$0) } ?? display) : display
        let fullscreen = (speedProfiles?.leagueFullscreenLock ?? false) || follow
        guard CGDisplayIsActive(display) != 0, let mode = CGDisplayCopyDisplayMode(display) else { message = "선택한 화면을 찾을 수 없습니다."; return }
        let screen = CGDisplayBounds(display)
        let effectiveWidth = fullscreen ? Int(screen.width) : width
        let effectiveHeight = fullscreen ? Int(screen.height) : height
        guard effectiveWidth >= 64, effectiveHeight >= 64,
              Double(effectiveWidth) <= screen.width, Double(effectiveHeight) <= screen.height else {
            message = "잠금 영역을 화면 크기 이내로 설정하세요."; return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            message = "적용 불가: 손쉬운 사용 또는 입력 모니터링 권한이 없습니다. 아래 권한 버튼을 누르세요."; return
        }
        guard let dpi = dpiSettings, dpi.selected != 0 else { message = "첫 화면에서 연결된 마우스를 선택하세요."; return }
        guard (speedProfiles.map { $0.ratio(mice:dpi) } ?? dpi.ratio) != nil else { message = "목표 감도를 적용하려면 유효한 현재 DPI가 필요합니다. DPI 창을 확인하세요."; return }
        requested = (width,height,originalDisplay,enhanced)
        if speedProfiles?.waitsForGame ?? false {
            active = true; waitingForGame = true
            message = "게임 대기 중 · 화면 제한 없음 · ⌘ Esc로 비활성화"
            diagnostics = "리그오브레전드 실제 게임으로 전환하면 설정한 영역을 적용합니다."
            return
        }
        usingWindowFollow = follow
        usingFullscreen = speedProfiles?.leagueFullscreenLock ?? false
        self.enhanced = enhanced
        scaleX = Double(mode.pixelWidth)/screen.width
        scaleY = Double(mode.pixelHeight)/screen.height
        let w = Double(effectiveWidth), h = Double(effectiveHeight)
        region = CGRect(x: screen.midX-w/2, y: screen.midY-h/2, width: w, height: h)
        pending.reserveCapacity(8192)
        reportMeter = HIDRateMeter(); rateStart = CACurrentMediaTime()
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(m, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<MouseEngine>.fromOpaque(context).takeUnretainedValue().receive(value)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, device in
            guard let context else { return }
            let engine = Unmanaged<MouseEngine>.fromOpaque(context).takeUnretainedValue()
            if MouseDevice.identifier(device) == engine.dpiSettings?.selected { engine.stop("마우스 연결이 해제되어 잠금을 해제했습니다.") }
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
        if follow, let bounds = speedProfiles?.gameWindowBounds {
            region = bounds.intersection(screen)
        }
        position = CGPoint(x: region.midX, y: region.midY)
        deliveredPosition = position
        lastRaw = 0; nativeCount = 0; missingSince = nil
        activationStamp = mach_absolute_time()
        active = true
        guard CGWarpMouseCursorPosition(position) == .success else { stop("포인터 위치 변경에 실패했습니다."); return }
        // A full-display lock needs no visible boundary.
        if Double(effectiveWidth) != screen.width || Double(effectiveHeight) != screen.height { showBorder() }
        message = "잠금 적용됨 · ⌘ Esc로 즉시 해제"
        let name = dpi.devices.first(where: { $0.id == dpi.selected })?.name ?? "마우스"
        diagnostics = "연결: \(name)\n영역 \(effectiveWidth) × \(effectiveHeight)pt (현재 화면 배율 기준)"
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.active else { return }
            if let t = self.tap, !CGEvent.tapIsEnabled(tap: t) { self.stop("이벤트 제어가 중단되어 안전하게 해제했습니다. 다시 적용하세요."); return }
            if !AXIsProcessTrusted() || !CGPreflightListenEventAccess() { self.stop("권한이 해제되어 잠금을 중단했습니다."); return }
            if let since = self.missingSince, CACurrentMediaTime()-since > 0.7, self.nativeCount > 3 {
                self.stop("포인터 이동은 감지됐지만 원시 HID 입력이 없습니다. 입력 모니터링 권한, 마우스 연결, 다른 마우스 제어 앱을 확인하세요."); return
            }
            self.lastGain = self.gain
            let now = CACurrentMediaTime()
            if now-self.rateStart >= 1 {
                self.inputRate = self.reportMeter.sample(elapsed:now-self.rateStart)
                self.rateStart = now
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func receive(_ value: IOHIDValue) {
        guard active, !waitingForGame, IOHIDValueGetTimeStamp(value) >= activationStamp else { return }
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == kHIDPage_GenericDesktop,
              IOHIDElementIsRelative(element) else { return }
        let usage = IOHIDElementGetUsage(element)
        guard usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y else { return }
        dpiSettings?.observeMotion(value)
        let stamp = IOHIDValueGetTimeStamp(value), device = IOHIDElementGetDevice(element)
        guard MouseDevice.identifier(device) == dpiSettings?.selected else { return }
        reportMeter.record(stamp:stamp,device:MouseDevice.identifier(device))
        let v = Double(IOHIDValueGetIntegerValue(value))
        // Pair X/Y from the same device and report timestamp, without mixing reports.
        if let i = pending.indices.last, pending[i].stamp == stamp, pending[i].device == device {
            if usage == kHIDUsage_GD_X { pending[i].dx += v } else { pending[i].dy += v }
        } else {
            pending.append((stamp,device,usage == kHIDUsage_GD_X ? v : 0,usage == kHIDUsage_GD_Y ? v : 0))
        }
        lastRaw = CACurrentMediaTime(); missingSince = nil; nativeCount = 0
        if let token = inputSession.schedule() {
            // Common modes also run during AppKit's modal mouse tracking loop.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
                guard let self, self.inputSession.consume(token) else { return }
                self.drain()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func drain() {
        let batch = pending; pending.removeAll(keepingCapacity: true)
        guard active else { return }
        for report in batch {
            guard MouseDevice.identifier(report.device) == dpiSettings?.selected else { continue }
            guard let mice = dpiSettings, let ratio = speedProfiles.map({ $0.ratio(mice:mice) }) ?? mice.ratio else { stop("현재 DPI를 확인할 수 없어 감도 보정을 중지했습니다."); return }
            let dx = report.dx * ratio, dy = report.dy * ratio
            let speed = speedProfiles?.speed ?? 1
            gain = ratio * speed * (enhanced ? PointerCurve.gain(hypot(dx, dy)) : 1)
            position = PointerCurve.advance(position, dx: dx, dy: dy, enabled: enhanced, scaleX: scaleX, scaleY: scaleY, bounds: region, speed: speed)
            // Native Quartz events are retargeted in filter(). Never synthesize a
            // parallel mouseMoved/drag stream: preserve native drag identity/order.

        }
        // Only calculate here. Cursor writes belong to the native event callback,
        // so HID delivery and Quartz delivery cannot alternately move the cursor.
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
            let stationary = PointerEvent.isStationaryMove(type:type,to:position,previous:deliveredPosition)
            let nativePosition = event.location
            PointerEvent.retarget(event, to: position, previous: deliveredPosition)
            deliveredPosition = position
            // One correction per native event, only when the OS position differs.
            if nativePosition != position, CGWarpMouseCursorPosition(position) != .success {
                stop("포인터 제한 실패로 잠금을 해제했습니다.")
                return Unmanaged.passUnretained(event)
            }
            // At a clamped edge, do not forward a stream of zero-distance hover moves.
            // Drag/down/up events always retain their native identity and order.
            return stationary ? nil : Unmanaged.passUnretained(event)
        }
        drain()
        guard active else { return Unmanaged.passUnretained(event) }
        event.location = position // Preserve the native down/up sequence and metadata.
        return Unmanaged.passUnretained(event)
    }

    func stop(_ reason: String? = "잠금을 해제했습니다.") {
        active = false; waitingForGame = false; requested = nil; inputRate = 0
        // Invalidate old queued drains and delayed screen restarts before teardown.
        inputSession.reset()
        timer?.invalidate(); timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
        if let manager {
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil; pending.removeAll(keepingCapacity: true)
        missingSince = nil; lastRaw = 0; nativeCount = 0; activationStamp = 0
        reportMeter = HIDRateMeter(); rateStart = 0
        gain = 1; lastGain = 1
        position = .zero; deliveredPosition = .zero; region = .zero
        scaleX = 1; scaleY = 1; enhanced = true
        usingWindowFollow = false; usingFullscreen = false
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
