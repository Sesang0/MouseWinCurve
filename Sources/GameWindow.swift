import AppKit
import ApplicationServices

// Cached title geometry is stable while a window merely moves. AX requests
// reach the game's own UI thread even when our caller runs on a worker queue.
struct WindowTitleCache {
    private var key: String?
    private var height: CGFloat?
    mutating func lookup(pid: pid_t, window: UInt32, size: CGSize) -> CGFloat? {
        let candidate = "\(pid):\(window):\(size.width):\(size.height)"
        if key != candidate { key = candidate; height = nil }
        return height
    }
    mutating func store(_ height: CGFloat) { self.height = height }
}

// Window server bounds use the same global coordinates as Quartz mouse events.
enum GameWindow {
    static func bounds(pid:pid_t, displays:[CGRect], fallbackTitleHeight:CGFloat, titleCache: inout WindowTitleCache) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] else { return nil }
        let candidate = windows.compactMap { item -> (CGRect, UInt32)? in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let data = item[kCGWindowBounds as String] as? [String:Any],
                  let rect = CGRect(dictionaryRepresentation:data as CFDictionary), rect.width >= 64, rect.height >= 64 else { return nil }
            return (rect, (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }.max { $0.0.width*$0.0.height < $1.0.width*$1.0.height }
        guard let (frame, windowID) = candidate else { return nil }
        // Fullscreen/borderless display-sized windows have no title strip.
        let fullscreen = displays.contains { r in
            abs(r.minX-frame.minX) < 1 && abs(r.minY-frame.minY) < 1 && abs(r.width-frame.width) < 1 && abs(r.height-frame.height) < 1
        }
        if fullscreen { return frame }
        if let height = titleCache.lookup(pid:pid,window:windowID,size:frame.size) {
            return contentBounds(frame:frame,titleBarHeight:height)
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        if let list = attribute(app, kAXWindowsAttribute) as? [AXUIElement],
           let window = list.first(where: { element in
               guard let r = rect(element) else { return false }
               return abs(r.minX-frame.minX) < 2 && abs(r.minY-frame.minY) < 2 && abs(r.width-frame.width) < 2 && abs(r.height-frame.height) < 2
           }) {
            if (attribute(window, "AXFullScreen") as? Bool) == true { titleCache.store(0); return frame }
            // Some games expose their client area directly through AXContents.
            if let contents = attribute(window, "AXContents"), CFGetTypeID(contents) == AXUIElementGetTypeID(),
               let content = rect(unsafeBitCast(contents, to: AXUIElement.self)),
               frame.contains(content), abs(content.width-frame.width) < 4,
               abs(content.maxY-frame.maxY) < 4, content.minY > frame.minY, content.height >= 64 { titleCache.store(content.minY-frame.minY); return content }
            for key in [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute] {
                if let value = attribute(window, key), CFGetTypeID(value) == AXUIElementGetTypeID(),
                   let button = rect(unsafeBitCast(value, to: AXUIElement.self)), frame.contains(button) {
                    let topPadding = button.minY-frame.minY
                    let height = button.maxY-frame.minY+topPadding
                    if height > 0 && height <= 100 { titleCache.store(height); return contentBounds(frame:frame,titleBarHeight:height) }
                }
            }
        }
        // AX is often sparse for games. Reserve the system's standard title height
        // rather than allowing the pointer onto the title bar when detection fails.
        titleCache.store(fallbackTitleHeight)
        return contentBounds(frame:frame,titleBarHeight:fallbackTitleHeight)
    }
    static func contentBounds(frame:CGRect, titleBarHeight:CGFloat) -> CGRect? {
        guard titleBarHeight.isFinite, titleBarHeight >= 0, frame.width >= 64, frame.height-titleBarHeight >= 64 else { return nil }
        return CGRect(x:frame.minX,y:frame.minY+titleBarHeight,width:frame.width,height:frame.height-titleBarHeight)
    }
    private static func attribute(_ element: AXUIElement,_ name:String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else { return nil }
        return value
    }
    private static func rect(_ element:AXUIElement) -> CGRect? {
        guard let p = attribute(element,kAXPositionAttribute), let s = attribute(element,kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p,to:AXValue.self),.cgPoint,&point),
              AXValueGetValue(unsafeBitCast(s,to:AXValue.self),.cgSize,&size) else { return nil }
        return CGRect(origin:point,size:size)
    }
    static func display(for rect:CGRect) -> CGDirectDisplayID? {
        NSScreen.screens.compactMap { screen -> CGDirectDisplayID? in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }.filter { CGDisplayBounds($0).intersects(rect) }.max {
            let a = CGDisplayBounds($0).intersection(rect), b = CGDisplayBounds($1).intersection(rect)
            return a.width*a.height < b.width*b.height
        }
    }
}
