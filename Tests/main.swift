import Foundation
import CoreGraphics
func near(_ a: Double,_ b: Double) { precondition(abs(a-b)<0.000001,"\(a) != \(b)") }
for (x,y) in PointerCurve.points { near(PointerCurve.gain(x),y) }
near(PointerCurve.gain(1000),2.41)
near(PointerCurve.gain(-10),0.55)
var last = 0.0
for i in 0...7500 { let y = PointerCurve.gain(Double(i)/100); precondition(y >= last); last = y }
let rect = CGRect(x:-500,y:100,width:200,height:100)
var p = CGPoint(x:-400,y:150)
p = PointerCurve.advance(p,dx:10000,dy:-10000,enabled:true,scaleX:2,scaleY:2,bounds:rect)
near(p.x,-300.5); near(p.y,100)
p = PointerCurve.advance(p,dx:-1,dy:1,enabled:false,scaleX:2,scaleY:2,bounds:rect)
near(p.x,-301); near(p.y,100.5) // no edge windup
let q = PointerCurve.advance(CGPoint(x:0,y:0),dx:3,dy:4,enabled:true,scaleX:1,scaleY:1,bounds:CGRect(x:-100,y:-100,width:200,height:200))
near(q.x/3,q.y/4); near(q.x/3,PointerCurve.gain(5))
var r = CGPoint(x:0,y:0)
for _ in 0..<10 { r = PointerCurve.advance(r,dx:1,dy:0,enabled:true,scaleX:2,scaleY:2,bounds:CGRect(x:0,y:0,width:100,height:100)) }
near(r.x,5*PointerCurve.gain(1))
print("PASS: curve anchors, monotonicity, tail clamp, diagonal gain, Retina conversion, fractional movement, negative display origin, bounds and edge reversal")

// DPI normalization must precede the nonlinear curve.
for target in [1,400,750,800,1200,1600,2400,57343] {
    let ratio = DPIConversion.ratio(current:1000,target:target)!
    near(ratio,Double(target)/1000)
    let native = PointerCurve.advance(.zero,dx:10*ratio,dy:5*ratio,enabled:true,scaleX:2,scaleY:2,bounds:CGRect(x:0,y:0,width:100,height:100))
    let equivalent = PointerCurve.advance(.zero,dx:Double(target)/100,dy:Double(target)/200,enabled:true,scaleX:2,scaleY:2,bounds:CGRect(x:0,y:0,width:100,height:100))
    near(native.x,equivalent.x); near(native.y,equivalent.y)
}
precondition(DPIConversion.ratio(current:nil,target:400) == nil)
precondition(DPIConversion.ratio(current:0,target:800) == nil)
precondition(DPIConversion.ratio(current:-1,target:800) == nil)
precondition(DPIConversion.ratio(current:65535,target:800) == nil)
near(DPIConversion.ratio(current:1000,target:1200)!,1.2)
precondition(DPIConversion.ratio(current:1000,target:57344) == nil)
precondition(DPIConversion.ratio(current:1000,target:-1) == nil)
near(DPIConversion.ratio(current:nil,target:0)!,1)
precondition(DPIConversion.readDPI([0x11,0xff,7,0x2b,0,0x03,0xe8]) == 1000)
precondition(DPIConversion.readDPI([0x11,0xff,7,0x2b,0,0,0]) == nil)
precondition(DPIConversion.readDPI([0x11,0xff,7,0x2b,1,0x03,0xe8]) == nil)
precondition(DPIConversion.readDPI([0x11,0xff]) == nil)
print("PASS: 400/800/1600 normalization before acceleration, invalid and missing DPI, bypass, HID++ DPI parsing")

precondition(!UnlockShortcut.matches(keyCode:53,flags:[]))
precondition(!UnlockShortcut.matches(keyCode:53,flags:.maskControl))
precondition(UnlockShortcut.matches(keyCode:53,flags:.maskCommand))
precondition(!UnlockShortcut.matches(keyCode:0,flags:.maskCommand))
print("PASS: arbitrary target DPI and Command+Escape (plain Escape passes through)")

// Real-event retargeting must not turn drag events into plain motion or lose
// click count / number / modifiers, which AppKit needs for native dragging.
for (type,button) in [(CGEventType.leftMouseDragged,CGMouseButton.left),(.rightMouseDragged,.right),(.otherMouseDragged,.center),(.mouseMoved,.left)] {
    let e = CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:CGPoint(x:100,y:100),mouseButton:button)!
    e.flags = [.maskShift,.maskAlternate]
    e.setIntegerValueField(.mouseEventClickState,value:2)
    e.setIntegerValueField(.mouseEventNumber,value:123)
    e.setIntegerValueField(.eventSourceUserData,value:777)
    e.timestamp = 100000
    let originalButton = e.getIntegerValueField(.mouseEventButtonNumber)
    PointerEvent.retarget(e,to:CGPoint(x:250,y:175),previous:CGPoint(x:240,y:160))
    precondition(e.type == type)
    precondition(e.flags == [.maskShift,.maskAlternate])
    precondition(e.getIntegerValueField(.mouseEventButtonNumber) == originalButton)
    precondition(e.getIntegerValueField(.mouseEventClickState) == 2)
    precondition(e.getIntegerValueField(.mouseEventNumber) == 123)
    precondition(e.getIntegerValueField(.eventSourceUserData) == 777)
    precondition(e.timestamp == 100000)
    near(e.location.x,250); near(e.location.y,175)
    near(e.getDoubleValueField(.mouseEventDeltaX),10)
    near(e.getDoubleValueField(.mouseEventDeltaY),15)
}
print("PASS: native left/right/other drag metadata retained, motion position and delta retargeting")

precondition(SpeedMath.factors.count == 11)
near(SpeedMath.pointer(6),1)
for step in 2...11 { precondition(SpeedMath.pointer(step) > SpeedMath.pointer(step-1)) }
near(SpeedMath.league(0),0.25); near(SpeedMath.league(50),1); near(SpeedMath.league(100),4)
precondition(SpeedMath.isLeagueGame(bundleID:"com.riotgames.LeagueofLegends.GameClient",executable:"LeagueofLegends"))
precondition(!SpeedMath.isLeagueGame(bundleID:"com.riotgames.LeagueofLegends.LeagueClientUx",executable:"LeagueClientUx"))
precondition(!SpeedMath.isLeagueGame(bundleID:"com.apple.finder",executable:"Finder"))
let speedBounds = CGRect(x:-1000,y:-1000,width:2000,height:2000)
let baseSpeed = PointerCurve.advance(.zero,dx:12,dy:5,enabled:true,scaleX:2,scaleY:2,bounds:speedBounds)
let fastSpeed = PointerCurve.advance(.zero,dx:12,dy:5,enabled:true,scaleX:2,scaleY:2,bounds:speedBounds,speed:2.5)
near(fastSpeed.x,baseSpeed.x*2.5); near(fastSpeed.y,baseSpeed.y*2.5)
print("PASS: 11 speed steps, neutral setting, League speed limits, game/client distinction, speed after curve")
