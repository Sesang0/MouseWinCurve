import Foundation
import IOKit.hid
import AppKit

struct DPIConversion {
    static func ratio(current: Int?, target: Int) -> Double? {
        if target == 0 { return 1 }
        guard (1...57343).contains(target), let current, (1...57343).contains(current) else { return nil }
        return Double(target)/Double(current)
    }
    static func readDPI(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 7, [UInt8(0x10),0x11].contains(bytes[0]), bytes[4] == 0 else { return nil }
        let value = Int(bytes[5])*256+Int(bytes[6])
        return (1...57343).contains(value) ? value : nil
    }
}

struct MouseDevice: Identifiable {
    let id: UInt64
    let name: String
    let vendor: Int
    let transport: String
    let device: IOHIDDevice
    static func identifier(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }
}

final class MouseCatalog: ObservableObject {
    @Published var devices: [MouseDevice] = []
    @Published var selected: UInt64 = 0
    @Published var manualDPI = ""
    @Published var target = 0
    @Published var targetInput = ""
    var requestedTarget: Int? {
        guard let value = Int(targetInput.trimmingCharacters(in: .whitespaces)), (1...57343).contains(value) else { return nil }
        return value
    }
    var canApplyTarget: Bool {
        guard let value = requestedTarget else { return false }
        return DPIConversion.ratio(current: current, target: value) != nil
    }
    func applyTarget() {
        guard canApplyTarget, let value = requestedTarget else { return }
        target = value
    }
    @Published var status = "마우스를 찾는 중…"
    var onUnavailable: (() -> Void)?
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault,IOOptionBits(kIOHIDOptionsTypeNone))
    private var timer: Timer?
    private var lastInputStamp: UInt64 = 0
    private var savedDPI: [UInt64: (String, Int, String)] = [:]
    func observeMotion(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == kHIDPage_GenericDesktop,
              IOHIDElementIsRelative(element),
              [kHIDUsage_GD_X,kHIDUsage_GD_Y].contains(Int(IOHIDElementGetUsage(element))),
              IOHIDValueGetIntegerValue(value) != 0 else { return }
        let stamp = IOHIDValueGetTimeStamp(value)
        guard stamp >= lastInputStamp else { return }
        let id = MouseDevice.identifier(IOHIDElementGetDevice(element))
        if !devices.contains(where: { $0.id == id }) { refreshDevices() }
        guard devices.contains(where: { $0.id == id }) else { return }
        lastInputStamp = stamp
        if selected != id { choose(id) }
    }
    var current: Int? { Int(manualDPI.trimmingCharacters(in:.whitespaces)) }
    var ratio: Double? { DPIConversion.ratio(current:current,target:target) }
    init() {
        IOHIDManagerSetDeviceMatching(manager,[kIOHIDDeviceUsagePageKey:kHIDPage_GenericDesktop,kIOHIDDeviceUsageKey:kHIDUsage_GD_Mouse] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<MouseCatalog>.fromOpaque(context).takeUnretainedValue().observeMotion(value)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
        _ = IOHIDManagerOpen(manager,IOOptionBits(kIOHIDOptionsTypeNone))
        refreshDevices()
        timer = Timer.scheduledTimer(withTimeInterval:5,repeats:true) { [weak self] _ in
            self?.refreshDevices()
        }
    }
    func refreshDevices() {
        let all = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        devices = all.compactMap { d in
            let name = IOHIDDeviceGetProperty(d,kIOHIDProductKey as CFString) as? String ?? "이름 없는 마우스"
            if name.localizedCaseInsensitiveContains("trackpad") { return nil }
            let vendor = (IOHIDDeviceGetProperty(d,kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
            let transport = IOHIDDeviceGetProperty(d,kIOHIDTransportKey as CFString) as? String ?? "HID"
            return MouseDevice(id:MouseDevice.identifier(d),name:name,vendor:vendor,transport:transport,device:d)
        }.sorted { $0.vendor == $1.vendor ? $0.id < $1.id : $0.vendor < $1.vendor }
        if !devices.contains(where:{$0.id == selected}) {
            onUnavailable?()
            choose(devices.first?.id ?? 0)
        }
        if devices.isEmpty { status = "연결된 외장 마우스가 없습니다." }
    }
    func choose(_ id: UInt64) {
        guard id != selected else { return }
        if selected != 0 { savedDPI[selected] = (manualDPI,target,targetInput) }
        selected = id
        let values = savedDPI[id] ?? ("",0,"")
        manualDPI = values.0; target = values.1; targetInput = values.2
    }
}
