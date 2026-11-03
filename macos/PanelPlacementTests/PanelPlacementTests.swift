import XCTest

final class PanelPlacementTests: XCTestCase {
    // AppKit coordinates: a 1512x949 laptop below/left of a 2560x1415 external display.
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 949)
    private let external = CGRect(x: 1512, y: 200, width: 2560, height: 1415)

    func testRoundTripIsExactOnTheSameScreen() {
        let frame = CGRect(x: 300, y: 600, width: 250, height: 95)
        let anchor = PanelPlacement.anchor(for: frame, in: laptop)
        let origin = PanelPlacement.origin(for: frame.size, at: anchor, in: laptop)
        XCTAssertEqual(origin.x, frame.minX, accuracy: 1e-9)
        XCTAssertEqual(origin.y, frame.minY, accuracy: 1e-9)
    }

    func testRepeatedShowWithDifferentHeightsDoesNotDrift() {
        let anchor = PanelPlacement.anchor(for: CGRect(x: 300, y: 600, width: 250, height: 95), in: laptop)
        // The top edge and center stay fixed whatever the panel height is.
        for height in [95, 63, 96, 94, 62] as [CGFloat] {
            let origin = PanelPlacement.origin(for: CGSize(width: 250, height: height), at: anchor, in: laptop)
            XCTAssertEqual(origin.y + height, 695, accuracy: 0.0001)
            XCTAssertEqual(origin.x + 125, 425, accuracy: 0.0001)
        }
    }

    func testProportionalPlacementOnAnotherScreen() {
        // Centered horizontally, top edge 10% below the top of the visible frame.
        let anchor = PanelAnchor(x: 0.5, y: 0.1)
        let size = CGSize(width: 250, height: 95)
        let onLaptop = PanelPlacement.origin(for: size, at: anchor, in: laptop)
        let onExternal = PanelPlacement.origin(for: size, at: anchor, in: external)
        XCTAssertEqual(onLaptop.x + 125, laptop.midX, accuracy: 0.0001)
        XCTAssertEqual(laptop.maxY - (onLaptop.y + 95), 94.9, accuracy: 0.0001)
        XCTAssertEqual(onExternal.x + 125, external.midX, accuracy: 0.0001)
        XCTAssertEqual(external.maxY - (onExternal.y + 95), 141.5, accuracy: 0.0001)
        // Showing on the other screen does not change the anchor (it is only saved after a drag).
        XCTAssertEqual(PanelPlacement.anchor(for: CGRect(origin: onExternal, size: size), in: external).x, 0.5, accuracy: 0.0001)
    }

    func testPanelIsKeptInsideTheScreen() {
        let size = CGSize(width: 250, height: 95)
        let corner = PanelPlacement.origin(for: size, at: PanelAnchor(x: 1.0, y: -0.2), in: laptop)
        XCTAssertEqual(corner.x, laptop.maxX - 250)
        XCTAssertEqual(corner.y, laptop.maxY - 95)
        let bottomLeft = PanelPlacement.origin(for: size, at: PanelAnchor(x: 0, y: 1.2), in: external)
        XCTAssertEqual(bottomLeft.x, external.minX)
        XCTAssertEqual(bottomLeft.y, external.minY)
    }

    func testLegacyOffsetsKeepThePanelWhereItWas() {
        let frame = CGRect(x: 600, y: 700, width: 250, height: 95)
        let legacyX = Double((frame.midX - laptop.midX) / laptop.width)
        let legacyY = Double((frame.midY - laptop.midY) / laptop.height)
        let anchor = PanelPlacement.anchor(legacyOffsetX: legacyX, legacyOffsetY: legacyY, panelHeight: 95, in: laptop)
        let origin = PanelPlacement.origin(for: frame.size, at: anchor, in: laptop)
        XCTAssertEqual(origin.x, frame.minX, accuracy: 0.0001)
        XCTAssertEqual(origin.y, frame.minY, accuracy: 0.0001)
    }

    func testStoreMigratesLegacyKeysOnceAndSavesAnchor() {
        let defaults = UserDefaults(suiteName: "PanelPlacementTests-\(UUID())")!
        XCTAssertNil(PanelPositionStore.load(panelHeight: 95, visible: laptop, defaults: defaults))

        defaults.set(0.1, forKey: "panelOffsetX")
        defaults.set(0.2, forKey: "panelOffsetY")
        defaults.set(true, forKey: "panelPositionSaved")
        let migrated = PanelPositionStore.load(panelHeight: 95, visible: laptop, defaults: defaults)
        XCTAssertEqual(migrated?.x ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertNil(defaults.object(forKey: "panelOffsetX"))
        // Later loads use the stored anchor, independent of panel height or screen.
        XCTAssertEqual(PanelPositionStore.load(panelHeight: 63, visible: external, defaults: defaults), migrated)

        PanelPositionStore.save(PanelAnchor(x: 0.25, y: 0.75), defaults: defaults)
        XCTAssertEqual(PanelPositionStore.load(panelHeight: 95, visible: laptop, defaults: defaults), PanelAnchor(x: 0.25, y: 0.75))
    }
}
