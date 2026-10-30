/// LogViewer.swift

import Cocoa

class Logger {
    
    static var logging = false
    
    static private var logWindowController: LogWindowController?
    
    static func showLogging(sender: Any?) {
        if logWindowController == nil {
            logWindowController = LogWindowController.freshController()
        }
        NSApp.activate(ignoringOtherApps: true)
        logWindowController?.showWindow(sender)
        logging = true
    }
    
    static func log(_ string: String) {
        if logging {
            logWindowController?.append(string)
        }
    }
}

class LogWindowController: NSWindowController, NSWindowDelegate {

    @IBAction func clearClicked(_ sender: Any) {
        (contentViewController as? LogViewController)?.clear()
    }
    
    func append(_ string: String) {
        let datestamp = String(NSDate().timeIntervalSince1970)
        (contentViewController as? LogViewController)?.append(datestamp + ": " + string + "\n")
    }
    
    func windowWillClose(_ notification: Notification) {
        Logger.logging = false
        clearClicked(self)
    }
}

extension LogWindowController {
    // MARK: Storyboard instantiation
    static func freshController() -> LogWindowController {
        if Bundle.main.path(forResource: "LogViewer", ofType: "storyboardc") != nil {
            let storyboard = NSStoryboard(name: "LogViewer", bundle: nil)
            let identifier = "LogWindowController"
            if let windowController = storyboard.instantiateController(withIdentifier: identifier) as? LogWindowController {
                windowController.window?.delegate = windowController
                return windowController
            }
        }
        return makeProgrammaticController()
    }

    private static func makeProgrammaticController() -> LogWindowController {
        let logVC = LogViewController()
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))

        let scrollView = NSScrollView(frame: rootView.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true

        let textView = KeyDownTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isRichText = true
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        let clearButton = NSButton(title: String(localized: "Clear"), target: nil, action: #selector(clearClicked(_:)))
        clearButton.bezelStyle = .rounded
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(scrollView)
        rootView.addSubview(clearButton)

        NSLayoutConstraint.activate([
            clearButton.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 8),
            clearButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: clearButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        logVC.view = rootView
        logVC.textView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Rectangle Log"
        window.contentViewController = logVC
        window.center()

        let controller = LogWindowController(window: window)
        clearButton.target = controller
        window.delegate = controller
        return controller
    }
}


class LogViewController: NSViewController {
    
    @IBOutlet var textView: NSTextView!
    
    let font = NSFont(name:"Monaco", size: 10) ?? NSFont.systemFont(ofSize: 10)
    
    let textColorAttribute =
        [NSAttributedString.Key.foregroundColor: NSColor.textColor,
         NSAttributedString.Key.font: NSFont(name:"Monaco", size: 10) ?? NSFont.systemFont(ofSize: 10)]
            
            as [NSAttributedString.Key: Any]
    
    func append(_ string: String) {
        let smartScroll = self.textView.visibleRect.maxY == self.textView.bounds.maxY
        
        textView.textStorage?.append(NSAttributedString(string: string, attributes: textColorAttribute))
        
        if smartScroll{
            textView.scrollToEndOfDocument(self)
        }
    }

    func clear() {
        textView.string = ""
    }
    
    override func viewDidLoad() {
        textView.isEditable = false
    }
    
}

class KeyDownTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(NSEvent.ModifierFlags.command) {
            switch event.charactersIgnoringModifiers! {
            case "w":
                self.window?.close()
            case "h":
                self.window?.orderOut(self)
            default:
                super.keyDown(with: event)
            }
        } else {
            super.keyDown(with: event)
        }
    }
}
