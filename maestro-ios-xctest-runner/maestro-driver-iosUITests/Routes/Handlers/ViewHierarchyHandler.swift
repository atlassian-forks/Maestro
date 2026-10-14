import FlyingFox
import XCTest
import os
import MaestroDriverLib

@MainActor
struct ViewHierarchyHandler: HTTPHandler {

    private let springboardApplication = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let snapshotMaxDepth = 60

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: Self.self)
    )

    func handleRequest(_ request: FlyingFox.HTTPRequest) async throws -> HTTPResponse {
        guard let requestBody = try? await JSONDecoder().decode(ViewHierarchyRequest.self, from: request.bodyData) else {
            return AppError(type: .precondition, message: "incorrect request body provided").httpResponse
        }

        do {
            let foregroundApp = RunningApp.getForegroundApp()
            guard let foregroundApp = foregroundApp else {
                NSLog("No foreground app found returning springboard app hierarchy")
                let springboardHierarchy = try elementHierarchy(xcuiElement: springboardApplication)
                let springBoardViewHierarchy = ViewHierarchy.init(axElement: springboardHierarchy, depth: springboardHierarchy.depth())
                let body = try JSONEncoder().encode(springBoardViewHierarchy)
                return HTTPResponse(statusCode: .ok, body: body)
            }
            NSLog("[Start] View hierarchy snapshot for \(foregroundApp)")
            let appViewHierarchy = try await getAppViewHierarchy(foregroundApp: foregroundApp, excludeKeyboardElements: requestBody.excludeKeyboardElements)
            let springboardHierarchy = try elementHierarchy(xcuiElement: springboardApplication)

            let combinedAXElement = AXElement(children: [springboardHierarchy, appViewHierarchy])
            let combinedViewHierarchy = ViewHierarchy(axElement: combinedAXElement, depth: combinedAXElement.depth())

            NSLog("[Done] View hierarchy snapshot for \(foregroundApp)")
            let body = try JSONEncoder().encode(combinedViewHierarchy)
            return HTTPResponse(statusCode: .ok, body: body)
        } catch let error as AppError {
            NSLog("AppError in handleRequest, Error:\(error)");
            return error.httpResponse
        } catch let error {
            NSLog("Error in handleRequest, Error:\(error)");
            return AppError(message: "Snapshot failure while getting view hierarchy. Error: \(error.localizedDescription)").httpResponse
        }
    }

    func getAppViewHierarchy(foregroundApp: XCUIApplication, excludeKeyboardElements: Bool) async throws -> AXElement {
        // On iOS 26 iPad, com.apple.DocumentManager.DockFolderViewService is reported as the
        // foreground process on the home screen, but its AX hierarchy is empty. The actual
        // home screen content lives in SpringBoard. Fall back to SpringBoard when detected.
        var foregroundApp = foregroundApp
        if foregroundApp.bundleID == "com.apple.DocumentManager.DockFolderViewService" {
            NSLog("DockFolderViewService detected as foreground, using SpringBoard hierarchy instead")
            foregroundApp = springboardApplication
        }
        let appHierarchy = try getHierarchyWithFallback(foregroundApp)
        await SystemPermissionHelper.handleSystemPermissionAlertIfNeeded(appHierarchy: appHierarchy, foregroundApp: foregroundApp)
                
        let statusBars = logger.measure(message: "Fetch status bar hierarchy") {
            fullStatusBars(springboardApplication)
        } ?? []
        
        // Fetch Safari WebView hierarchy for iOS 26+ (runs in separate SafariViewService process)
        let safariWebViewHierarchy = logger.measure(message: "Fetch Safari WebView hierarchy") {
            getSafariWebViewHierarchy()
        }

        let deviceFrame = springboardApplication.frame
        let deviceAxFrame = [
            "X": Double(deviceFrame.minX),
            "Y": Double(deviceFrame.minY),
            "Width": Double(deviceFrame.width),
            "Height": Double(deviceFrame.height)
        ]
        let appFrame = appHierarchy.frame
        
        if deviceAxFrame != appFrame {
            guard
                let deviceWidth = deviceAxFrame["Width"], deviceWidth > 0,
                let deviceHeight = deviceAxFrame["Height"], deviceHeight > 0,
                let appWidth = appFrame["Width"], appWidth > 0,
                let appHeight = appFrame["Height"], appHeight > 0
            else {
                return AXElement(children: [appHierarchy, AXElement(children: statusBars), safariWebViewHierarchy].compactMap { $0 })
            }

            // Springboard always reports its frame in portrait dimensions (e.g. 1024×1366),
            // while a landscape app reports them swapped (1366×1024). Without this guard,
            // the difference would be misinterpreted as a window offset, shifting every
            // element's coordinates by hundreds of points in the wrong direction.
            let isSameAreaDifferentOrientation =
                abs(deviceWidth * deviceHeight - appWidth * appHeight) < 1.0
                && abs(deviceWidth - appHeight) < 1.0
                && abs(deviceHeight - appWidth) < 1.0

            if isSameAreaDifferentOrientation {
                NSLog("Skipping offset adjustment: device and app frames are same size but different orientation")
                return AXElement(children: [appHierarchy, AXElement(children: statusBars), safariWebViewHierarchy].compactMap { $0 })
            }

            let offsetX = deviceWidth - appWidth
            let offsetY = deviceHeight - appHeight
            let offset = WindowOffset(offsetX: offsetX, offsetY: offsetY)

            NSLog("Adjusting view hierarchy with offset: \(offset)")

            let adjustedAppHierarchy = expandElementSizes(appHierarchy, offset: offset)

            return AXElement(children: [adjustedAppHierarchy, AXElement(children: statusBars), safariWebViewHierarchy].compactMap { $0 })
        } else {
            return AXElement(children: [appHierarchy, AXElement(children: statusBars), safariWebViewHierarchy].compactMap { $0 })
        }
    }
    
    func expandElementSizes(_ element: AXElement, offset: WindowOffset) -> AXElement {
        let adjustedFrame: AXFrame = [
            "X": (element.frame["X"] ?? 0) + offset.offsetX,
            "Y": (element.frame["Y"] ?? 0) + offset.offsetY,
            "Width": element.frame["Width"] ?? 0,
            "Height": element.frame["Height"] ?? 0
        ]
        let adjustedChildren = element.children?.map { expandElementSizes($0, offset: offset) } ?? []
        
        return AXElement(
            identifier: element.identifier,
            frame: adjustedFrame,
            value: element.value,
            title: element.title,
            label: element.label,
            elementType: element.elementType,
            enabled: element.enabled,
            horizontalSizeClass: element.horizontalSizeClass,
            verticalSizeClass: element.verticalSizeClass,
            placeholderValue: element.placeholderValue,
            selected: element.selected,
            hasFocus: element.hasFocus,
            displayID: element.displayID,
            windowContextID: element.windowContextID,
            children: adjustedChildren
        )
    }

    func getHierarchyWithFallback(_ element: XCUIElement) throws -> AXElement {
        logger.info("Starting getHierarchyWithFallback for element.")

        do {
            var hierarchy = try elementHierarchy(xcuiElement: element)
            logger.info("Successfully retrieved element hierarchy.")

            if hierarchy.depth() < snapshotMaxDepth {
                return hierarchy
            }
            let count = try element.snapshot().children.count
            var children: [AXElement] = []
            for i in 0..<count {
              let element = element.descendants(matching: .other).element(boundBy: i).firstMatch
              children.append(try getHierarchyWithFallback(element))
            }
            hierarchy.children = children
            return hierarchy
        } catch let error {
            guard isRecoverableSnapshotError(error) else {
                NSLog("Snapshot failure, cannot return view hierarchy due to \(error)")
                if (error as NSError).isXCUITestTimeout {
                    throw AppError(type: .timeout, message: error.localizedDescription)
                } else {
                    throw AppError(message: error.localizedDescription)
                }
            }

            NSLog("Snapshot failure (\(error.localizedDescription)), getting recovery element for fallback")
            AXClientSwizzler.overwriteDefaultParameters["maxDepth"] = snapshotMaxDepth
            // In apps with bigger view hierarchys, calling
            // `XCUIApplication().snapshot().dictionaryRepresentation` or `XCUIApplication().allElementsBoundByIndex`
            // throws "Error kAXErrorIllegalArgument getting snapshot for element <AXUIElementRef 0x6000025eb660>"
            // We recover by selecting the first child of the app element,
            // which should be the window, and continue from there.

            let recoveryElement = try findRecoveryElement(element.children(matching: .any).firstMatch)
            let hierarchy = try getHierarchyWithFallback(recoveryElement)

            // When the application element is skipped, try to fetch
            // the keyboard, alert and other custom element hierarchies separately.
            if let element = element as? XCUIApplication {
                let keyboard = logger.measure(message: "Fetch keyboard hierarchy") {
                    keyboardHierarchy(element)
                }

                let alerts = logger.measure(message: "Fetch alert hierarchy") {
                    fullScreenAlertHierarchy(element)
                }

                let other = try logger.measure(message: "Fetch other custom element from window") {
                    try customWindowElements(element)
                }
                return AXElement(children: [
                    other,
                    keyboard,
                    alerts,
                    hierarchy
                ].compactMap { $0 })
            }

            return hierarchy
        }
    }

    /// Transient XCTest snapshot failures that the recovery path (walk from the
    /// window child, skipping the racing app-level snapshot) can absorb. Both fire
    /// when the tree is large or changing under `snapshot()`:
    ///  - `kAXErrorIllegalArgument` — snapshotting a too-large element.
    ///  - `kAXErrorInvalidUIElement` ("Error getting element frame") — an element
    ///    went stale mid-snapshot while the UI was updating. Previously this fell
    ///    through to a fatal 500 that aborted the whole flow; the smaller recovery
    ///    subtree is far less likely to race, so route it through recovery instead.
    private func isRecoverableSnapshotError(_ error: Error) -> Bool {
        let description = error.localizedDescription
        return description.contains("Error kAXErrorIllegalArgument getting snapshot for element")
            || description.contains("kAXErrorInvalidUIElement")
    }

    private func keyboardHierarchy(_ element: XCUIApplication) -> AXElement? {
        guard element.keyboards.firstMatch.exists else {
            return nil
        }
        
        let keyboard = element.keyboards.firstMatch
        return try? elementHierarchy(xcuiElement: keyboard)
    }
    
    private func customWindowElements(_ element: XCUIApplication) throws -> AXElement? {
        let windowElement = element.children(matching: .any).firstMatch
        if try windowElement.snapshot().children.count > 1 {
            return nil
        }
        return try? elementHierarchy(xcuiElement: windowElement)
    }

    func fullScreenAlertHierarchy(_ element: XCUIApplication) -> AXElement? {
        guard element.alerts.firstMatch.exists else {
            return nil
        }
        
        let alert = element.alerts.firstMatch
        return try? elementHierarchy(xcuiElement: alert)
    }
    
    func fullStatusBars(_ element: XCUIApplication) -> [AXElement]? {
        guard element.statusBars.firstMatch.exists else {
            return nil
        }
        
        let snapshots = try? element.statusBars.allElementsBoundByIndex.compactMap{ (statusBar) in
            try elementHierarchy(xcuiElement: statusBar)
        }
        
        return snapshots
    }
    
    /// Fetches the Safari WebView hierarchy for iOS 26+ where SFSafariViewController
    /// runs in a separate process (com.apple.SafariViewService).
    /// Returns nil if not on iOS 26+, Safari service is not running, or no webviews exist.
    private func getSafariWebViewHierarchy() -> AXElement? {
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersion
        guard systemVersion.majorVersion >= 26 else {
            return nil
        }
        
        let safariWebService = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        
        let isRunning = safariWebService.state == .runningForeground || safariWebService.state == .runningBackground
        guard isRunning else {
            return nil
        }
        
        let webViewCount = safariWebService.webViews.count
        guard webViewCount > 0 else {
            return nil
        }
        
        NSLog("[Start] Fetching Safari WebView hierarchy (\(webViewCount) webview(s) detected)")
        
        do {
            AXClientSwizzler.overwriteDefaultParameters["maxDepth"] = snapshotMaxDepth
            let safariHierarchy = try elementHierarchy(xcuiElement: safariWebService)
            NSLog("[Done] Safari WebView hierarchy fetched successfully")
            return safariHierarchy
        } catch {
            NSLog("[Error] Failed to fetch Safari WebView hierarchy: \(error.localizedDescription)")
            return nil
        }
    }

    private func findRecoveryElement(_ element: XCUIElement) throws -> XCUIElement {
        if try element.snapshot().children.count > 1 {
            return element
        }
        let firstOtherElement = element.children(matching: .other).firstMatch
        if (firstOtherElement.exists) {
            return try findRecoveryElement(firstOtherElement)
        } else {
            return element
        }
    }

    private func elementHierarchy(xcuiElement: XCUIElement) throws -> AXElement {
        let snapshot = try xcuiElement.snapshot()
        return elementHierarchy(snapshot: snapshot, inheritedOffset: .zero, parentWindowContextID: nil,
                                parentFrame: nil, parentIsRemote: nil, visibleHostAnchor: nil)
    }

    /// Walks the snapshot tree (not `dictionaryRepresentation`, which is O(subtree)
    /// per call) and accumulates a coordinate offset across cross-process window
    /// boundaries so descendant frames land in screen coordinates.
    private func elementHierarchy(
        snapshot: XCUIElementSnapshot,
        inheritedOffset: CGVector,
        parentWindowContextID: Double?,
        parentFrame: AXFrame?,
        parentIsRemote: @autoclosure () -> Bool?,
        visibleHostAnchor: @autoclosure () -> VisibleHostAnchor?
    ) -> AXElement {
        let rawFrame = axFrame(from: snapshot.frame)
        let windowContextID = kvcDouble(snapshot, "windowContextID") ?? 0

        // Private snapshot getters can be expensive. Resolve them only at a remote
        // window boundary, and cache them if its host-anchor chain needs them again.
        lazy var snapshotIsRemote = remoteValue(snapshot)
        lazy var snapshotVisibleRect = visibleFrameRect(snapshot)
        lazy var snapshotVisibleFrame = visibleFrame(from: snapshotVisibleRect)
        lazy var nextAnchor = VisibleHostAnchor.advance(previous: visibleHostAnchor(), rawFrame: rawFrame,
            visibleFrame: snapshotVisibleFrame, windowContextID: windowContextID, isRemote: snapshotIsRemote)

        let boundaryOffset = CrossProcessWindowGeometry.offset(
            rawFrame: rawFrame,
            parentFrame: parentFrame,
            parentWindowContextID: parentWindowContextID,
            windowContextID: windowContextID,
            remoteSubtree: snapshotIsRemote == true || snapshot.children.contains(where: isRemote),
            parentIsRemote: parentIsRemote(),
            visibleFrame: snapshotVisibleFrame,
            allowsHostFallback: snapshotVisibleRect?.isNull == true,
            visibleHostAnchor: visibleHostAnchor()
        )
        let currentOffset = CGVector(
            dx: inheritedOffset.dx + boundaryOffset.dx,
            dy: inheritedOffset.dy + boundaryOffset.dy
        )

        let children = snapshot.children.map { child in
            elementHierarchy(
                snapshot: child,
                inheritedOffset: currentOffset,
                parentWindowContextID: windowContextID,
                parentFrame: rawFrame,
                parentIsRemote: snapshotIsRemote,
                visibleHostAnchor: nextAnchor
            )
        }

        return AXElement(
            identifier: snapshot.identifier,
            frame: offsetFrame(rawFrame, by: currentOffset),
            value: snapshot.value as? String,
            title: snapshot.title,
            label: snapshot.label,
            elementType: Int(snapshot.elementType.rawValue),
            enabled: snapshot.isEnabled,
            horizontalSizeClass: snapshot.horizontalSizeClass.rawValue,
            verticalSizeClass: snapshot.verticalSizeClass.rawValue,
            placeholderValue: snapshot.placeholderValue,
            selected: snapshot.isSelected,
            hasFocus: snapshot.hasFocus,
            displayID: kvcInt(snapshot, "displayID") ?? 0,
            windowContextID: windowContextID,
            children: children
        )
    }

    private func isRemote(_ snapshot: XCUIElementSnapshot) -> Bool {
        remoteValue(snapshot) ?? false
    }

    private func remoteValue(_ snapshot: XCUIElementSnapshot) -> Bool? {
        guard let snapshotObject = snapshot as? NSObject,
              snapshotObject.responds(to: NSSelectorFromString("isRemote")) else { return nil }
        return (snapshotObject.value(forKey: "isRemote") as? NSNumber)?.boolValue
    }

    private func visibleFrameRect(_ snapshot: XCUIElementSnapshot) -> CGRect? {
        guard let object = snapshot as? NSObject,
              object.responds(to: NSSelectorFromString("visibleFrame")),
              let value = object.value(forKey: "visibleFrame") as? NSValue else { return nil }
        return value.cgRectValue
    }

    private func visibleFrame(from rect: CGRect?) -> AXFrame? {
        guard let rect = rect else { return nil }
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite else {
            return nil
        }

        return [
            "X": Double(rect.origin.x),
            "Y": Double(rect.origin.y),
            "Width": Double(rect.size.width),
            "Height": Double(rect.size.height)
        ]
    }

    private func axFrame(from rect: CGRect) -> AXFrame {
        return [
            "X": Double(rect.origin.x),
            "Y": Double(rect.origin.y),
            "Width": Double(rect.size.width),
            "Height": Double(rect.size.height)
        ]
    }

    private func kvcDouble(_ snapshot: XCUIElementSnapshot, _ key: String) -> Double? {
        guard let object = snapshot as? NSObject,
              object.responds(to: NSSelectorFromString(key)) else {
            return nil
        }
        return (object.value(forKey: key) as? NSNumber)?.doubleValue
    }

    private func kvcInt(_ snapshot: XCUIElementSnapshot, _ key: String) -> Int? {
        guard let object = snapshot as? NSObject,
              object.responds(to: NSSelectorFromString(key)) else {
            return nil
        }
        return (object.value(forKey: key) as? NSNumber)?.intValue
    }

    private func offsetFrame(_ frame: AXFrame, by offset: CGVector) -> AXFrame {
        guard offset.dx != 0 || offset.dy != 0 else {
            return frame
        }
        return [
            "X": frame.x + Double(offset.dx),
            "Y": frame.y + Double(offset.dy),
            "Width": frame.width,
            "Height": frame.height
        ]
    }
}

/// Pure geometry for cross-process roots; `visibleFrame` has already been validated.
/// Fallback is intentionally limited to an unscaled remote root filling its host.
enum CrossProcessWindowGeometry {
    static func offset(
        rawFrame: AXFrame,
        parentFrame: AXFrame?,
        parentWindowContextID: Double?,
        windowContextID: Double,
        remoteSubtree: @autoclosure () -> Bool,
        parentIsRemote: @autoclosure () -> Bool?,
        visibleFrame: @autoclosure () -> AXFrame?,
        allowsHostFallback: @autoclosure () -> Bool,
        visibleHostAnchor: @autoclosure () -> VisibleHostAnchor?
    ) -> CGVector {
        guard let parentWindowContextID = parentWindowContextID,
              parentWindowContextID != 0, windowContextID != 0,
              parentWindowContextID != windowContextID, remoteSubtree() else {
            return .zero
        }
        if let visibleFrame = visibleFrame() {
            return CGVector(dx: visibleFrame.x - rawFrame.x, dy: visibleFrame.y - rawFrame.y)
        }
        guard allowsHostFallback(), parentWindowContextID.isFinite, windowContextID.isFinite,
              parentIsRemote() == false, let parentFrame = parentFrame,
              let anchor = visibleHostAnchor(), anchor.windowContextID == parentWindowContextID,
              anchor.frame == parentFrame,
              parentFrame.x.isFinite, parentFrame.y.isFinite,
              parentFrame.width.isFinite, parentFrame.height.isFinite,
              parentFrame.width > 0, parentFrame.height > 0,
              rawFrame.x == 0, rawFrame.y == 0,
              rawFrame.width == parentFrame.width, rawFrame.height == parentFrame.height else {
            return .zero
        }
        // Both frames are in their respective window coordinate spaces. The caller adds
        // its inherited offset exactly once; applying it here would double nested shifts.
        return CGVector(dx: parentFrame.x - rawFrame.x, dy: parentFrame.y - rawFrame.y)
    }
}

/// Tracks a confirmed visible host through the observed same-origin proxy chain.
/// A zero-size proxy may bridge the chain, but the parent must restore the full anchor
/// frame before CrossProcessWindowGeometry accepts a remote-root translation.
struct VisibleHostAnchor {
    let frame: AXFrame
    let windowContextID: Double

    static func advance(previous: @autoclosure () -> VisibleHostAnchor?, rawFrame: AXFrame,
                        visibleFrame: @autoclosure () -> AXFrame?, windowContextID: Double,
                        isRemote: @autoclosure () -> Bool?) -> VisibleHostAnchor? {
        guard isRemote() == false, windowContextID.isFinite, windowContextID != 0,
              let visibleFrame = visibleFrame() else { return nil }
        let finite = [rawFrame.x, rawFrame.y, rawFrame.width, rawFrame.height,
                      visibleFrame.x, visibleFrame.y, visibleFrame.width, visibleFrame.height].allSatisfy(\.isFinite)
        guard finite else { return nil }
        if rawFrame.width > 0, rawFrame.height > 0, rawFrame == visibleFrame {
            return VisibleHostAnchor(frame: rawFrame, windowContextID: windowContextID)
        }
        guard let previous = previous(), previous.windowContextID == windowContextID else { return nil }
        let sameOrigin = rawFrame.x == previous.frame.x && rawFrame.y == previous.frame.y
            && visibleFrame.x == previous.frame.x && visibleFrame.y == previous.frame.y
        let visibleZeroProxy = visibleFrame.width == 0 && visibleFrame.height == 0
        let rawZeroProxy = rawFrame.width == 0 && rawFrame.height == 0
        guard sameOrigin, visibleZeroProxy, rawZeroProxy || rawFrame == previous.frame else { return nil }
        return previous
    }
}
