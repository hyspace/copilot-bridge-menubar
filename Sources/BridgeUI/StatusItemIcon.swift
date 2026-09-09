import AppKit

public enum StatusItemIcon {
    public static func make() -> NSImage? {
        let image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted",
                            accessibilityDescription: "Copilot Bridge")
        // AppKit chooses the tint for the actual menu-bar background, including
        // wallpaper-dependent appearances that differ from the popover's theme.
        image?.isTemplate = true
        return image
    }
}
