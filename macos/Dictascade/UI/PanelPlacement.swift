import CoreGraphics
import Foundation

/// Where the recording overlay sits on a screen, independent of the screen's size
/// and of the panel's current height.
///
/// `x` is the panel's horizontal center and `y` the distance of its top edge from
/// the top, both as fractions of the screen's visible frame. Anchoring the top edge
/// keeps the pill still when the panel grows or shrinks (e.g. the mode pill below it
/// hides while transcribing), and fractions place it proportionally on other screens.
struct PanelAnchor: Equatable {
    var x: Double
    var y: Double
}

enum PanelPlacement {
    /// Anchor of a panel frame within a visible frame (AppKit coordinates).
    static func anchor(for frame: CGRect, in visible: CGRect) -> PanelAnchor {
        PanelAnchor(
            x: Double((frame.midX - visible.minX) / visible.width),
            y: Double((visible.maxY - frame.maxY) / visible.height)
        )
    }

    /// Origin that puts a panel of `size` at `anchor`, kept fully inside `visible`.
    static func origin(for size: CGSize, at anchor: PanelAnchor, in visible: CGRect) -> CGPoint {
        let x = visible.minX + CGFloat(anchor.x) * visible.width - size.width / 2
        let top = visible.maxY - CGFloat(anchor.y) * visible.height
        return CGPoint(
            x: min(max(x, visible.minX), visible.maxX - size.width),
            y: min(max(top - size.height, visible.minY), visible.maxY - size.height)
        )
    }

    /// The anchor used before any position was saved: centered, 80 pt below the top.
    static func defaultAnchor(in visible: CGRect) -> PanelAnchor {
        PanelAnchor(x: 0.5, y: Double(80 / visible.height))
    }

    /// Converts the pre-1.5.3 format (panel center relative to the screen center).
    static func anchor(legacyOffsetX: Double, legacyOffsetY: Double, panelHeight: CGFloat, in visible: CGRect) -> PanelAnchor {
        PanelAnchor(
            x: 0.5 + legacyOffsetX,
            y: 0.5 - legacyOffsetY - Double(panelHeight / 2 / visible.height)
        )
    }
}

/// Persists the anchor. It is written only when the user finishes dragging the
/// panel, never when it hides, so repeated show/hide cycles cannot drift.
enum PanelPositionStore {
    private static let xKey = "panelAnchorX"
    private static let yKey = "panelAnchorY"
    private static let legacyXKey = "panelOffsetX"
    private static let legacyYKey = "panelOffsetY"
    private static let legacySavedKey = "panelPositionSaved"

    static func load(panelHeight: CGFloat, visible: CGRect, defaults: UserDefaults = .standard) -> PanelAnchor? {
        if defaults.object(forKey: xKey) != nil, defaults.object(forKey: yKey) != nil {
            return PanelAnchor(x: defaults.double(forKey: xKey), y: defaults.double(forKey: yKey))
        }
        guard defaults.bool(forKey: legacySavedKey) else { return nil }
        let anchor = PanelPlacement.anchor(
            legacyOffsetX: defaults.double(forKey: legacyXKey),
            legacyOffsetY: defaults.double(forKey: legacyYKey),
            panelHeight: panelHeight,
            in: visible
        )
        save(anchor, defaults: defaults)
        return anchor
    }

    static func save(_ anchor: PanelAnchor, defaults: UserDefaults = .standard) {
        defaults.set(anchor.x, forKey: xKey)
        defaults.set(anchor.y, forKey: yKey)
        for key in [legacyXKey, legacyYKey, legacySavedKey] { defaults.removeObject(forKey: key) }
    }
}
