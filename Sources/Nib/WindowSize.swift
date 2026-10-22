import CoreGraphics

/// Window geometry. Deliberately not named `CardSize`: the desktop-card family
/// uses that word and Nib is not one of them.
enum WindowSize {
    /// Opening size. The window is genuinely resizable, so this is a starting
    /// point rather than a contract: canvas left, controls right.
    static let width: Double = 900
    static let height: Double = 620

    /// Below this the controls column starts clipping its labels, and the house
    /// rule is that labels never wrap.
    static let minWidth: Double = 680
    static let minHeight: Double = 480

    /// Fixed-height strip above the canvas. The source name and dimensions live
    /// in it, and it is present whether or not an image is loaded, so opening
    /// one cannot shift the canvas down.
    static let aboveCanvas: CGFloat = 34

    /// Width of the controls column. Sized to fit "Nearest colour" plus its
    /// segmented picker on one line.
    static let controls: CGFloat = 260
}
