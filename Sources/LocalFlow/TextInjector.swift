import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Injects text at the cursor of the frontmost app via pasteboard-paste:
/// save the user's clipboard → put our text on it → synthesize ⌘V → restore.
/// This is the most reliable strategy across arbitrary macOS apps: synthesizing
/// per-character key events breaks on non-ASCII text and IME-driven input.
enum TextInjector {
    private static let log = Logger(subsystem: "ai.xdlab.LocalFlow", category: "inject")

    static func promptForAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Opens the Accessibility pane so the user can (re-)grant us.
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Returns false when Accessibility is not granted — CGEvent posting
    /// would silently no-op, so the caller should surface that instead.
    @discardableResult
    static func inject(_ text: String) -> Bool {
        let trusted = AXIsProcessTrusted()
        log.notice("inject: AXIsProcessTrusted=\(trusted), chars=\(text.count)")
        guard trusted else { return false }
        let pasteboard = NSPasteboard.general

        // Snapshot the user's clipboard before we clobber it. Items must be
        // deep-copied: clearContents() invalidates the originals.
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy[type] = data
                }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        synthesizeCmdV()
        log.notice("inject: Cmd-V posted")

        // Give the target app time to service the paste before restoring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pasteboard.clearContents()
            let items = saved.map { entry in
                let item = NSPasteboardItem()
                for (type, data) in entry {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !items.isEmpty {
                pasteboard.writeObjects(items)
            }
        }
        return true
    }

    private static func synthesizeCmdV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey = CGKeyCode(kVK_ANSI_V)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
