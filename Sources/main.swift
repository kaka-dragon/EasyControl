import Cocoa
import ApplicationServices
import os.lock

private let standardModifiers: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]
private let syntheticMarker: Int64 = 0x45415359 // "EASY"
private let defaults = UserDefaults.standard

private enum PrefKey {
    static let windowFlags = "windowFlags"
    static let scrollFlags = "scrollFlags"
    static let touchResize = "touchResize"
    static let threeFingerDragEnabled = "threeFingerDragEnabled"
    static let disabled = "disabled"
    static let disabledNames = "disabledNames"
}

private func axAttr(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
}

private func axIsSettable(_ element: AXUIElement, _ name: CFString) -> Bool {
    var settable: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(element, name, &settable) == .success && settable.boolValue
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let p = axAttr(element, kAXPositionAttribute as CFString),
          let s = axAttr(element, kAXSizeAttribute as CFString),
          CFGetTypeID(p) == AXValueGetTypeID(),
          CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
          AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
}

private func axSetPosition(_ element: AXUIElement, _ point: CGPoint) {
    var pt = point
    if let val = AXValueCreate(.cgPoint, &pt) {
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, val)
    }
}

private func axSetSize(_ element: AXUIElement, _ size: CGSize) {
    var sz = size
    if let val = AXValueCreate(.cgSize, &sz) {
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, val)
    }
}

private func formatModifiers(_ flags: CGEventFlags) -> String {
    let ordered: [(String, CGEventFlags)] = [
        ("⌃", .maskControl),
        ("⌥", .maskAlternate),
        ("⇧", .maskShift),
        ("⌘", .maskCommand)
    ]
    return ordered.compactMap { flags.contains($0.1) ? $0.0 : nil }.joined()
}

private final class MultitouchTracker {
    static let shared = MultitouchTracker()

    private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias MTDeviceStopFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias MTContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias MTRegisterFn = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
    private typealias MTUnregisterFn = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void

    private var lock = os_unfair_lock_s()
    private var started = false
    private var devices: [AnyObject] = []
    private var currentFingers: Int32 = 0
    private var lastThreeFingerTime: CFTimeInterval = 0

    private var stopFn: MTDeviceStopFn?
    private var unregFn: MTUnregisterFn?

    private static let contactCallback: MTContactCallback = { _, _, numFingers, _, _ in
        MultitouchTracker.shared.recordFingers(numFingers)
        return 0
    }

    private init() {}

    func startIfNeeded() {
        os_unfair_lock_lock(&lock)
        if started {
            os_unfair_lock_unlock(&lock)
            return
        }
        started = true
        os_unfair_lock_unlock(&lock)

        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
              let createSym = dlsym(handle, "MTDeviceCreateList"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let stopSym = dlsym(handle, "MTDeviceStop"),
              let regSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let unregSym = dlsym(handle, "MTUnregisterContactFrameCallback") else {
            return
        }

        let createList = unsafeBitCast(createSym, to: MTDeviceCreateListFn.self)
        let startDev = unsafeBitCast(startSym, to: MTDeviceStartFn.self)
        let stopDev = unsafeBitCast(stopSym, to: MTDeviceStopFn.self)
        let regCb = unsafeBitCast(regSym, to: MTRegisterFn.self)
        let unregCb = unsafeBitCast(unregSym, to: MTUnregisterFn.self)

        guard let list = createList()?.takeRetainedValue() as? [AnyObject] else { return }

        os_unfair_lock_lock(&lock)
        self.stopFn = stopDev
        self.unregFn = unregCb
        self.devices = list
        os_unfair_lock_unlock(&lock)

        for dev in list {
            let ptr = Unmanaged.passUnretained(dev).toOpaque()
            regCb(ptr, MultitouchTracker.contactCallback)
            _ = startDev(ptr, 0)
        }
    }

    func stop() {
        os_unfair_lock_lock(&lock)
        let devs = devices
        let unreg = unregFn
        let stopDev = stopFn
        devices = []
        started = false
        currentFingers = 0
        os_unfair_lock_unlock(&lock)

        for dev in devs {
            let ptr = Unmanaged.passUnretained(dev).toOpaque()
            unreg?(ptr, MultitouchTracker.contactCallback)
            _ = stopDev?(ptr)
        }
    }

    private func recordFingers(_ count: Int32) {
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(&lock)
        currentFingers = count
        if count >= 3 {
            lastThreeFingerTime = now
        }
        os_unfair_lock_unlock(&lock)
    }

    func isThreeFingerActive() -> Bool {
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(&lock)
        let active = (currentFingers >= 3) || (now - lastThreeFingerTime < 0.18)
        os_unfair_lock_unlock(&lock)
        return active
    }
}

private enum DragMode {
    case none
    case move
    case resize
    case scroll
}

private struct ResizeDirection: Equatable {
    var x: Int // -1 left, 0 none, +1 right
    var y: Int // -1 top, 0 none, +1 bottom

    static func from(point: CGPoint, in frame: CGRect, fallbackCenterToBottomRight: Bool = false) -> ResizeDirection {
        let relX = point.x - frame.origin.x
        let relY = point.y - frame.origin.y
        let dirX: Int = relX < frame.width / 3 ? -1 : (relX > 2 * frame.width / 3 ? 1 : 0)
        let dirY: Int = relY < frame.height / 3 ? -1 : (relY > 2 * frame.height / 3 ? 1 : 0)
        if fallbackCenterToBottomRight && dirX == 0 && dirY == 0 {
            return ResizeDirection(x: 1, y: 1)
        }
        return ResizeDirection(x: dirX, y: dirY)
    }
}

private struct ActiveAXDrag {
    let sessionID: UInt64
    let window: AXUIElement
    let mode: DragMode
    let initialFrame: CGRect
    let initialMouse: CGPoint
    let resizeDir: ResizeDirection
}

private struct ActiveTouchResize {
    var window: AXUIElement
    var initialFrame: CGRect
    var resizeDir: ResizeDirection
    var totalDX: CGFloat
    var totalDY: CGFloat
    var lastTime: TimeInterval
    var ended: Bool
}

private final class AXWorker {
    private let queue = DispatchQueue(label: "local.easycontrol.ax", qos: .userInteractive)
    private var lock = os_unfair_lock_s()

    private var activeDrag: ActiveAXDrag?
    private var finishedSessionID: UInt64 = 0
    private var latestMouse: CGPoint = .zero
    private var needsDragFlush = false
    private var dragWorkerRunning = false
    private var lastAppliedDragFrame: CGRect?
    private var lastAppliedDragMouse: CGPoint?
    private var lastDragSessionID: UInt64 = 0

    // Two-finger scroll resize coalescing
    private var activeTouch: ActiveTouchResize?
    private var needsTouchFlush = false
    private var touchWorkerRunning = false
    private var lastAppliedTouchDelta: CGPoint?
    private var lastAppliedTouchFrame: CGRect?

    func startDrag(_ drag: ActiveAXDrag) {
        os_unfair_lock_lock(&lock)
        activeDrag = drag
        finishedSessionID = 0
        latestMouse = drag.initialMouse
        needsDragFlush = false
        lastAppliedDragFrame = drag.initialFrame
        lastAppliedDragMouse = drag.initialMouse
        lastDragSessionID = drag.sessionID
        os_unfair_lock_unlock(&lock)
    }

    func enqueueDragMouse(_ point: CGPoint, sessionID: UInt64) {
        os_unfair_lock_lock(&lock)
        guard let drag = activeDrag, drag.sessionID == sessionID else {
            os_unfair_lock_unlock(&lock)
            return
        }
        latestMouse = point
        needsDragFlush = true
        let shouldLaunch = !dragWorkerRunning
        if shouldLaunch { dragWorkerRunning = true }
        os_unfair_lock_unlock(&lock)

        if shouldLaunch {
            queue.async { [weak self] in self?.runDragLoop() }
        }
    }

    func finishDrag(finalPoint: CGPoint?, sessionID: UInt64) {
        os_unfair_lock_lock(&lock)
        guard let drag = activeDrag, drag.sessionID == sessionID else {
            os_unfair_lock_unlock(&lock)
            return
        }
        finishedSessionID = sessionID
        var shouldLaunch = false
        if let pt = finalPoint {
            latestMouse = pt
            needsDragFlush = true
            if !dragWorkerRunning {
                dragWorkerRunning = true
                shouldLaunch = true
            }
        } else if !dragWorkerRunning {
            activeDrag = nil
            needsDragFlush = false
        }
        os_unfair_lock_unlock(&lock)

        if shouldLaunch {
            queue.async { [weak self] in self?.runDragLoop() }
        }
    }

    func cancelDrag() {
        os_unfair_lock_lock(&lock)
        activeDrag = nil
        finishedSessionID = 0
        needsDragFlush = false
        os_unfair_lock_unlock(&lock)
    }

    private func runDragLoop() {
        while true {
            os_unfair_lock_lock(&lock)
            guard needsDragFlush, let drag = activeDrag else {
                if let drag = activeDrag, finishedSessionID == drag.sessionID {
                    activeDrag = nil
                }
                dragWorkerRunning = false
                os_unfair_lock_unlock(&lock)
                return
            }
            let mouse = latestMouse
            let alreadyApplied = (lastDragSessionID == drag.sessionID && lastAppliedDragMouse == mouse)
            needsDragFlush = false
            os_unfair_lock_unlock(&lock)

            if !alreadyApplied {
                applyDrag(drag, mouse: mouse)
                os_unfair_lock_lock(&lock)
                lastAppliedDragMouse = mouse
                os_unfair_lock_unlock(&lock)
            }
        }
    }

    private func applyResize(
        window w: AXUIElement,
        initial: CGRect,
        dx: CGFloat,
        dy: CGFloat,
        dir: ResizeDirection,
        lastFrame: CGRect?
    ) -> CGRect? {
        if dir.x == 0 && dir.y == 0 { return lastFrame }

        let minW: CGFloat = 80
        let minH: CGFloat = 60
        let anchorMaxX = initial.maxX
        let anchorMaxY = initial.maxY

        var targetW = initial.width
        var targetX = initial.origin.x
        if dir.x > 0 {
            targetW = max(minW, (initial.width + dx).rounded())
        } else if dir.x < 0 {
            targetW = max(minW, (initial.width - dx).rounded())
            targetX = anchorMaxX - targetW
        }

        var targetH = initial.height
        var targetY = initial.origin.y
        if dir.y > 0 {
            targetH = max(minH, (initial.height + dy).rounded())
        } else if dir.y < 0 {
            targetH = max(minH, (initial.height - dy).rounded())
            targetY = anchorMaxY - targetH
        }

        let current = lastFrame ?? axFrame(w) ?? initial

        // Expanding left or top: move origin FIRST so opposite edge does not collide with screen bounds.
        var prePos = current.origin
        var needPrePos = false
        if dir.x < 0 && targetX < current.origin.x - 0.5 {
            prePos.x = targetX
            needPrePos = true
        }
        if dir.y < 0 && targetY < current.origin.y - 0.5 {
            prePos.y = targetY
            needPrePos = true
        }
        if needPrePos {
            axSetPosition(w, prePos)
            if let afterPre = axFrame(w) {
                if dir.x < 0 && afterPre.origin.x > targetX + 0.5 {
                    targetW = max(minW, anchorMaxX - afterPre.origin.x)
                }
                if dir.y < 0 && afterPre.origin.y > targetY + 0.5 {
                    targetH = max(minH, anchorMaxY - afterPre.origin.y)
                }
            }
        }

        axSetSize(w, CGSize(width: targetW, height: targetH))

        if let accepted = axFrame(w) {
            var finalPos = accepted.origin
            var needPostPos = false

            if dir.x < 0 {
                let desiredX = anchorMaxX - accepted.width
                if abs(desiredX - accepted.origin.x) > 0.5 {
                    finalPos.x = desiredX
                    needPostPos = true
                }
            } else if abs(initial.origin.x - accepted.origin.x) > 0.5 {
                finalPos.x = initial.origin.x
                needPostPos = true
            }

            if dir.y < 0 {
                let desiredY = anchorMaxY - accepted.height
                if abs(desiredY - accepted.origin.y) > 0.5 {
                    finalPos.y = desiredY
                    needPostPos = true
                }
            } else if abs(initial.origin.y - accepted.origin.y) > 0.5 {
                finalPos.y = initial.origin.y
                needPostPos = true
            }

            if needPostPos {
                axSetPosition(w, finalPos)
                return axFrame(w) ?? CGRect(origin: finalPos, size: accepted.size)
            }
            return accepted
        }
        return lastFrame
    }

    private func applyDrag(_ drag: ActiveAXDrag, mouse: CGPoint) {
        let dx = mouse.x - drag.initialMouse.x
        let dy = mouse.y - drag.initialMouse.y
        let w = drag.window

        if drag.mode == .move {
            let target = CGPoint(
                x: (drag.initialFrame.origin.x + dx).rounded(),
                y: (drag.initialFrame.origin.y + dy).rounded()
            )
            axSetPosition(w, target)
            return
        }

        guard drag.mode == .resize else { return }
        lastAppliedDragFrame = applyResize(
            window: w,
            initial: drag.initialFrame,
            dx: dx,
            dy: dy,
            dir: drag.resizeDir,
            lastFrame: lastAppliedDragFrame
        )
    }

    func enqueueTouchResize(
        window: AXUIElement,
        windowFrame: CGRect,
        cursor: CGPoint,
        dx: CGFloat,
        dy: CGFloat,
        phase: Int64
    ) {
        let now = CACurrentMediaTime()
        let isBegan = (phase == 1 || phase == 128)
        let isEnded = (phase == 4 || phase == 8)

        os_unfair_lock_lock(&lock)
        let expired = activeTouch.map { (now - $0.lastTime) > 0.35 } ?? true
        let sameWindow = activeTouch.map { CFEqual($0.window, window) } ?? false

        if isBegan || !sameWindow || expired || (activeTouch?.ended == true) {
            let dir = ResizeDirection.from(point: cursor, in: windowFrame, fallbackCenterToBottomRight: true)
            activeTouch = ActiveTouchResize(
                window: window,
                initialFrame: windowFrame,
                resizeDir: dir,
                totalDX: dx,
                totalDY: dy,
                lastTime: now,
                ended: isEnded
            )
            lastAppliedTouchDelta = nil
            lastAppliedTouchFrame = windowFrame
        } else {
            activeTouch?.totalDX += dx
            activeTouch?.totalDY += dy
            activeTouch?.lastTime = now
            if isEnded { activeTouch?.ended = true }
        }

        let hasDelta = abs(dx) > 0.01 || abs(dy) > 0.01
        if hasDelta {
            needsTouchFlush = true
        }
        let shouldLaunch = needsTouchFlush && !touchWorkerRunning
        if shouldLaunch { touchWorkerRunning = true }
        if isEnded && !needsTouchFlush && !touchWorkerRunning {
            activeTouch = nil
        }
        os_unfair_lock_unlock(&lock)

        if shouldLaunch {
            queue.async { [weak self] in self?.runTouchLoop() }
        }
    }

    private func runTouchLoop() {
        while true {
            os_unfair_lock_lock(&lock)
            guard needsTouchFlush, let touch = activeTouch else {
                if activeTouch?.ended == true { activeTouch = nil }
                touchWorkerRunning = false
                os_unfair_lock_unlock(&lock)
                return
            }
            let delta = CGPoint(x: touch.totalDX.rounded(), y: touch.totalDY.rounded())
            needsTouchFlush = false
            let alreadyApplied = (lastAppliedTouchDelta == delta)
            let lastFrame = lastAppliedTouchFrame
            os_unfair_lock_unlock(&lock)

            if !alreadyApplied && (abs(delta.x) >= 1 || abs(delta.y) >= 1) {
                let updated = applyResize(
                    window: touch.window,
                    initial: touch.initialFrame,
                    dx: delta.x,
                    dy: delta.y,
                    dir: touch.resizeDir,
                    lastFrame: lastFrame
                )
                os_unfair_lock_lock(&lock)
                lastAppliedTouchDelta = delta
                lastAppliedTouchFrame = updated
                os_unfair_lock_unlock(&lock)
            }
        }
    }
}

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?
    private var lastApp: NSRunningApplication?

    private let axWorker = AXWorker()
    private var mode: DragMode = .none
    private var dragSessionID: UInt64 = 0
    private var anchor = CGPoint.zero
    private var lastScrollPoint = CGPoint.zero
    private var scrollAccumX: CGFloat = 0
    private var scrollAccumY: CGFloat = 0
    private var savedDown: CGEvent?
    private var dragged = false
    private var cancelled = false

    private var disabled: [String] {
        get { defaults.stringArray(forKey: PrefKey.disabled) ?? [] }
        set { defaults.set(newValue, forKey: PrefKey.disabled) }
    }

    private var disabledNames: [String: String] {
        get { defaults.dictionary(forKey: PrefKey.disabledNames) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: PrefKey.disabledNames) }
    }

    private func flags(_ key: String) -> CGEventFlags {
        CGEventFlags(rawValue: UInt64(defaults.integer(forKey: key)))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            PrefKey.windowFlags: Int(CGEventFlags([.maskControl, .maskCommand]).rawValue),
            PrefKey.scrollFlags: Int(CGEventFlags.maskControl.rawValue),
            PrefKey.touchResize: false,
            PrefKey.threeFingerDragEnabled: true
        ])

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "local.easycontrol.statusItem"
        if let img = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "EasyControl") {
            img.isTemplate = true
            item.button?.image = img
        } else {
            item.button?.title = "EC"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != getpid() {
                self?.lastApp = app
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            lastApp = front
        }

        MultitouchTracker.shared.startIfNeeded()
        refreshTapState()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshTapState()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        teardownTap()
        MultitouchTracker.shared.stop()
    }

    private func hasConflictingTool() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.localizedName == "Easy Move+Resize" || $0.localizedName == "Hammerspoon"
        }
    }

    private func refreshTapState() {
        let trusted = AXIsProcessTrusted()
        if !trusted || hasConflictingTool() {
            teardownTap()
            return
        }
        if tap == nil {
            installTap()
        }
    }

    private func installTap() {
        guard AXIsProcessTrusted(), !hasConflictingTool() else { return }
        let kinds: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .scrollWheel, .flagsChanged
        ]
        let mask = kinds.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, ref in
                let me = Unmanaged<Controller>.fromOpaque(ref!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    me.resetSession(cancelWorker: true)
                    if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return me.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = created
        runLoopSource = source
    }

    private func teardownTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
            tap = nil
        }
        resetSession(cancelWorker: true)
    }

    private func resetSession(cancelWorker: Bool) {
        if cancelWorker {
            axWorker.cancelDrag()
        }
        mode = .none
        savedDown = nil
        cancelled = false
        dragged = false
        scrollAccumX = 0
        scrollAccumY = 0
    }

    private func findAXWindow(forPid pid: pid_t, at point: CGPoint, matchingBounds: CGRect?) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.2)

        var candidates: [AXUIElement] = []
        if let list = axAttr(appEl, kAXWindowsAttribute as CFString) as? [AXUIElement] {
            candidates.append(contentsOf: list)
        }
        if let focused = axAttr(appEl, kAXFocusedWindowAttribute as CFString) {
            let fw = focused as! AXUIElement
            if !candidates.contains(where: { CFEqual($0, fw) }) { candidates.append(fw) }
        }
        if let main = axAttr(appEl, kAXMainWindowAttribute as CFString) {
            let mw = main as! AXUIElement
            if !candidates.contains(where: { CFEqual($0, mw) }) { candidates.append(mw) }
        }

        var scored: [(AXUIElement, CGFloat)] = []
        for win in candidates {
            guard let f = axFrame(win) else { continue }
            guard f.insetBy(dx: -2, dy: -2).contains(point) else { continue }
            if let b = matchingBounds {
                let diff = abs(f.origin.x - b.origin.x)
                    + abs(f.origin.y - b.origin.y)
                    + abs(f.width - b.width)
                    + abs(f.height - b.height)
                scored.append((win, diff))
            } else {
                scored.append((win, 0))
            }
        }
        return scored.min(by: { $0.1 < $1.1 })?.0
    }

    private func topmostWindowInfo(at point: CGPoint) -> (pid: pid_t, bundleId: String?, bounds: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ignoredBundleIds: Set<String> = [
            "com.apple.dock",
            "com.apple.controlcenter",
            "com.apple.notificationcenterui",
            "com.apple.systemuiserver"
        ]
        for info in list {
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            if layer != 0 { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            if alpha <= 0.01 { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 40, bounds.height >= 40,
                  bounds.contains(point) else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != getpid() else { continue }
            let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            if bid == "com.apple.WindowManager" {
                return nil
            }
            if let bid = bid, ignoredBundleIds.contains(bid) { continue }
            return (pid, bid, bounds)
        }
        return nil
    }

    private func targetAppBundleID(at point: CGPoint) -> String? {
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
           let h = hit {
            var pid: pid_t = 0
            AXUIElementGetPid(h, &pid)
            if pid != 0 && pid != getpid(),
               let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
               bid != "com.apple.WindowManager" {
                return bid
            }
        }
        return topmostWindowInfo(at: point)?.bundleId
    }

    private func targetWindow(at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
           let h = hit {
            var pid: pid_t = 0
            AXUIElementGetPid(h, &pid)
            if pid == getpid() { return nil }
            let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            if bid == "com.apple.WindowManager" { return nil }
            if let bid = bid, disabled.contains(bid) { return nil }

            if let role = axAttr(h, kAXRoleAttribute as CFString) as? String, role == kAXWindowRole {
                AXUIElementSetMessagingTimeout(h, 0.25)
                return h
            }
            if let win = axAttr(h, kAXWindowAttribute as CFString) {
                let w = win as! AXUIElement
                AXUIElementSetMessagingTimeout(w, 0.25)
                return w
            }
            var current: AXUIElement? = h
            for _ in 0..<16 {
                guard let node = current,
                      let parent = axAttr(node, kAXParentAttribute as CFString) else { break }
                let parentEl = parent as! AXUIElement
                if let role = axAttr(parentEl, kAXRoleAttribute as CFString) as? String, role == kAXWindowRole {
                    AXUIElementSetMessagingTimeout(parentEl, 0.25)
                    return parentEl
                }
                current = parentEl
            }
            if pid != 0, let w = findAXWindow(forPid: pid, at: point, matchingBounds: nil) {
                AXUIElementSetMessagingTimeout(w, 0.25)
                return w
            }
        }

        guard let top = topmostWindowInfo(at: point) else { return nil }
        if let bid = top.bundleId, disabled.contains(bid) { return nil }
        guard let w = findAXWindow(forPid: top.pid, at: point, matchingBounds: top.bounds) else { return nil }
        AXUIElementSetMessagingTimeout(w, 0.25)
        return w
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        if e.getIntegerValueField(.eventSourceUserData) == syntheticMarker { return false }

        let f = e.flags.intersection(standardModifiers)
        let p = e.location

        if type == .flagsChanged {
            if mode != .none {
                let expected = flags(mode == .scroll ? PrefKey.scrollFlags : PrefKey.windowFlags)
                if f != expected { cancelled = true }
            }
            return false
        }

        if type == .scrollWheel,
           defaults.bool(forKey: PrefKey.touchResize),
           f == flags(PrefKey.windowFlags),
           f != CGEventFlags(),
           e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
            if e.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return true }
            guard let w = targetWindow(at: p),
                  axIsSettable(w, kAXSizeAttribute as CFString),
                  let r = axFrame(w) else { return false }
            let dx = CGFloat(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            let dy = CGFloat(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let phase = e.getIntegerValueField(.scrollWheelEventScrollPhase)
            axWorker.enqueueTouchResize(window: w, windowFrame: r, cursor: p, dx: dx, dy: dy, phase: phase)
            return true
        }

        if type == .leftMouseDown || type == .rightMouseDown {
            resetSession(cancelWorker: true)
            anchor = p
            lastScrollPoint = p

            let winFlags = flags(PrefKey.windowFlags)
            if winFlags != CGEventFlags(), f == winFlags {
                if type == .leftMouseDown,
                   !defaults.bool(forKey: PrefKey.threeFingerDragEnabled),
                   MultitouchTracker.shared.isThreeFingerActive() {
                    return false
                }

                if let w = targetWindow(at: p), let r = axFrame(w) {
                    let isResize = (type == .rightMouseDown)
                    let requiredAttr = isResize ? kAXSizeAttribute : kAXPositionAttribute
                    guard axIsSettable(w, requiredAttr as CFString) else { return false }

                    let resizeDir = ResizeDirection.from(point: p, in: r)
                    dragSessionID &+= 1
                    mode = isResize ? .resize : .move
                    axWorker.startDrag(ActiveAXDrag(
                        sessionID: dragSessionID,
                        window: w,
                        mode: mode,
                        initialFrame: r,
                        initialMouse: p,
                        resizeDir: resizeDir
                    ))
                    return true
                }
            }

            let scrollFlags = flags(PrefKey.scrollFlags)
            if type == .leftMouseDown, scrollFlags != CGEventFlags(), f == scrollFlags {
                if let bid = targetAppBundleID(at: p), disabled.contains(bid) { return false }
                mode = .scroll
                savedDown = e.copy()
                return true
            }
            return false
        }

        guard mode != .none else { return false }

        if (type == .leftMouseUp && mode != .resize) || (type == .rightMouseUp && mode == .resize) {
            if mode == .scroll {
                if !dragged, !cancelled, let down = savedDown, let up = e.copy() {
                    up.location = anchor
                    for ev in [down, up] {
                        ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
                        ev.post(tap: .cghidEventTap)
                    }
                }
                resetSession(cancelWorker: false)
                return true
            }
            let session = dragSessionID
            axWorker.finishDrag(finalPoint: cancelled ? nil : p, sessionID: session)
            resetSession(cancelWorker: false)
            return true
        }

        guard type == .leftMouseDragged || type == .rightMouseDragged else { return false }
        if cancelled { return true }

        if mode == .scroll {
            if !dragged && hypot(p.x - anchor.x, p.y - anchor.y) < 3 { return true }
            dragged = true
            scrollAccumX += (p.x - lastScrollPoint.x)
            scrollAccumY += (p.y - lastScrollPoint.y)
            lastScrollPoint = p
            let ix = Int32(trunc(scrollAccumX))
            let iy = Int32(trunc(scrollAccumY))
            scrollAccumX -= CGFloat(ix)
            scrollAccumY -= CGFloat(iy)
            if ix != 0 || iy != 0,
               let scroll = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: iy,
                wheel2: ix,
                wheel3: 0
               ) {
                scroll.flags = []
                scroll.location = anchor
                scroll.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
                scroll.post(tap: .cghidEventTap)
            }
            return true
        }

        axWorker.enqueueDragMouse(p, sessionID: dragSessionID)
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        refreshTapState()

        if let current = NSWorkspace.shared.frontmostApplication, current.processIdentifier != getpid() {
            lastApp = current
        }

        @discardableResult
        func add(_ title: String, _ action: Selector? = nil, key: String = "", targetMenu: NSMenu = menu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.isEnabled = (action != nil)
            targetMenu.addItem(item)
            return item
        }

        let trusted = AXIsProcessTrusted()
        let conflict = hasConflictingTool()

        if trusted {
            let statusTitle = tap != nil ? "EasyControl · 运行中" : "EasyControl · 等待接管"
            add(statusTitle)
            add("辅助功能权限：已开启")
            if conflict {
                add("冲突提示：请退出旧 Easy Move+Resize / Hammerspoon")
            } else if tap == nil {
                add("输入监控权限：未开启或未生效")
                add("打开输入监控设置…", #selector(openInputMonitoring))
            }
        } else {
            add("EasyControl · 未就绪")
            add("辅助功能权限：未开启")
            add("打开权限设置…", #selector(openAccessibility))
        }

        menu.addItem(.separator())

        if let app = lastApp, let id = app.bundleIdentifier {
            let name = app.localizedName ?? id
            let toggle = add("在「\(name)」中禁用", #selector(toggleApp(_:)))
            toggle.representedObject = ["id": id, "name": name]
            toggle.state = disabled.contains(id) ? .on : .off
        }

        if !disabled.isEmpty {
            let disabledParent = add("已禁用应用")
            disabledParent.isEnabled = true
            let sub = NSMenu(); sub.autoenablesItems = false
            disabledParent.submenu = sub
            let names = disabledNames
            for id in disabled {
                let label = names[id] ?? id
                let item = add("恢复「\(label)」", #selector(enableApp(_:)), targetMenu: sub)
                item.representedObject = id
            }
        }

        menu.addItem(.separator())

        let modifierChoices: [(String, CGEventFlags)] = [
            ("⌃", .maskControl),
            ("⌥", .maskAlternate),
            ("⇧", .maskShift),
            ("⌘", .maskCommand)
        ]

        for (label, key) in [("窗口修饰键", PrefKey.windowFlags), ("抓手滚动修饰键", PrefKey.scrollFlags)] {
            let currentStr = formatModifiers(flags(key))
            let parentTitle = currentStr.isEmpty ? label : "\(label)（\(currentStr)）"
            let parent = add(parentTitle)
            parent.isEnabled = true
            let sub = NSMenu(); sub.autoenablesItems = false
            parent.submenu = sub
            for bits in 1..<16 {
                var value = CGEventFlags()
                var title = ""
                for j in 0..<4 where bits & (1 << j) != 0 {
                    value.formUnion(modifierChoices[j].1)
                    title += modifierChoices[j].0
                }
                let item = add(title, #selector(setFlags(_:)), targetMenu: sub)
                item.representedObject = ["key": key, "value": String(value.rawValue)]
                item.state = (value == flags(key)) ? .on : .off
            }
        }

        let trackpadParent = add("触控板选项")
        trackpadParent.isEnabled = true
        let trackpadSub = NSMenu(); trackpadSub.autoenablesItems = false
        trackpadParent.submenu = trackpadSub

        let twoFinger = add("双指滚动调整大小", #selector(toggleTouchResize), targetMenu: trackpadSub)
        twoFinger.isEnabled = true
        twoFinger.state = defaults.bool(forKey: PrefKey.touchResize) ? .on : .off

        let threeFinger = add("三指平移拖移窗口", #selector(toggleThreeFingerDrag), targetMenu: trackpadSub)
        threeFinger.isEnabled = true
        threeFinger.state = defaults.bool(forKey: PrefKey.threeFingerDragEnabled) ? .on : .off

        menu.addItem(.separator())

        add("恢复默认设置", #selector(resetDefaults))
        add("退出 EasyControl", #selector(quit), key: "q")
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let id = info["id"] else { return }
        var list = disabled
        var names = disabledNames
        if list.contains(id) {
            list.removeAll { $0 == id }
            names.removeValue(forKey: id)
        } else {
            list.append(id)
            if let n = info["name"] { names[id] = n }
        }
        disabled = list
        disabledNames = names
    }

    @objc private func enableApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var list = disabled
        list.removeAll { $0 == id }
        disabled = list
        var names = disabledNames
        names.removeValue(forKey: id)
        disabledNames = names
    }

    @objc private func setFlags(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: String],
              let key = dict["key"],
              let valStr = dict["value"],
              let val = Int(valStr) else { return }
        defaults.set(val, forKey: key)
        resetSession(cancelWorker: true)
    }

    @objc private func toggleTouchResize() {
        defaults.set(!defaults.bool(forKey: PrefKey.touchResize), forKey: PrefKey.touchResize)
    }

    @objc private func toggleThreeFingerDrag() {
        defaults.set(!defaults.bool(forKey: PrefKey.threeFingerDragEnabled), forKey: PrefKey.threeFingerDragEnabled)
    }

    @objc private func resetDefaults() {
        defaults.set(Int(CGEventFlags([.maskControl, .maskCommand]).rawValue), forKey: PrefKey.windowFlags)
        defaults.set(Int(CGEventFlags.maskControl.rawValue), forKey: PrefKey.scrollFlags)
        defaults.set(false, forKey: PrefKey.touchResize)
        defaults.set(true, forKey: PrefKey.threeFingerDragEnabled)
        defaults.removeObject(forKey: PrefKey.disabled)
        defaults.removeObject(forKey: PrefKey.disabledNames)
        resetSession(cancelWorker: true)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.delegate = controller
app.run()
