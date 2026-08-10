import AppKit
import CoreGraphics

struct DetectedWindow {
    let frame: CGRect
    let ownerName: String
    let windowNumber: Int

    var appKitFrame: CGRect {
        // CGWindowList 的坐标原点在「主屏」（screens.first，带 menu bar 那块）左上角。
        // 多显示器时必须用主屏高度做翻转；NSScreen.main 是 key window 所在屏，会算错。
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: frame.origin.x,
            y: primaryScreenHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}

@MainActor
final class WindowDetector {
    /// 检测当前屏幕上可见的窗口
    /// excludingWindowNumbers: 要排除的窗口号（VitaPet 自己的窗口）
    func detectWindows(excludingWindowNumbers: Set<Int> = []) -> [DetectedWindow] {
        guard
            let windowInfoList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return []
        }

        var detectedWindows: [DetectedWindow] = []
        detectedWindows.reserveCapacity(windowInfoList.count)

        for windowInfo in windowInfoList {
            guard
                let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                let ownerName = windowInfo[kCGWindowOwnerName as String] as? String,
                let windowNumber = windowInfo[kCGWindowNumber as String] as? Int,
                let windowLayer = windowInfo[kCGWindowLayer as String] as? Int
            else {
                continue
            }

            guard windowLayer == 0 else { continue }
            guard !ownerName.contains("VitaPet") else { continue }
            guard !excludingWindowNumbers.contains(windowNumber) else { continue }

            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDictionary, &bounds) else {
                continue
            }

            guard bounds.width >= 100, bounds.height >= 100 else { continue }

            detectedWindows.append(
                DetectedWindow(
                    frame: bounds,
                    ownerName: ownerName,
                    windowNumber: windowNumber
                )
            )
        }

        return detectedWindows
    }
}
