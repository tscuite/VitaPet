import Foundation

public enum ClickGesturePlanner {
    public static func shouldStartDragAnimation(clickCount: Int) -> Bool {
        clickCount <= 1
    }
}
