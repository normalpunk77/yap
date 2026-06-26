import XCTest
@testable import YapCore

final class HotKeyShortcutTests: XCTestCase {
    func testDefaultIsOptionS() {
        let s = HotKeyShortcut.defaultShortcut
        XCTAssertEqual(s.keyCode, 0x01)
        XCTAssertEqual(s.modifiers, HotKeyShortcut.optionKey)
        XCTAssertEqual(s.display, "⌥S")
        XCTAssertTrue(s.hasModifier)
    }

    func testDisplayUsesCanonicalModifierOrder() {
        // Order must always be ⌃⌥⇧⌘ regardless of how the bits combine.
        let all = HotKeyShortcut(
            keyCode: 0x31, // Space
            modifiers: HotKeyShortcut.cmdKey | HotKeyShortcut.controlKey
                | HotKeyShortcut.shiftKey | HotKeyShortcut.optionKey,
            keyLabel: "Space")
        XCTAssertEqual(all.display, "⌃⌥⇧⌘Space")
    }

    func testDisplaySingleModifiers() {
        XCTAssertEqual(HotKeyShortcut(keyCode: 0, modifiers: HotKeyShortcut.cmdKey, keyLabel: "K").display, "⌘K")
        XCTAssertEqual(HotKeyShortcut(keyCode: 0, modifiers: HotKeyShortcut.controlKey, keyLabel: "F5").display, "⌃F5")
    }

    func testHasModifierFalseWhenNoModifiers() {
        let bare = HotKeyShortcut(keyCode: 0x01, modifiers: 0, keyLabel: "S")
        XCTAssertFalse(bare.hasModifier)
        XCTAssertEqual(bare.display, "S")
    }
}
