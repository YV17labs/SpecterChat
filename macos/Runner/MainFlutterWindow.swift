import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// Double-click title bar → maximize height only (keep current width & x).
  override func zoom(_ sender: Any?) {
    guard let screen = self.screen else {
      super.zoom(sender)
      return
    }

    let visibleFrame = screen.visibleFrame
    let currentFrame = self.frame

    // If already at full height, restore to previous frame.
    if abs(currentFrame.height - visibleFrame.height) < 2
        && abs(currentFrame.origin.y - visibleFrame.origin.y) < 2 {
      super.zoom(sender)
      return
    }

    let newFrame = NSRect(
      x: currentFrame.origin.x,
      y: visibleFrame.origin.y,
      width: currentFrame.width,
      height: visibleFrame.height
    )
    self.setFrame(newFrame, display: true, animate: true)
  }
}
