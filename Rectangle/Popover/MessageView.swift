/// MessageView.swift

import Cocoa

class MessagePopover {
    
    var messageView: MessageView
    var popover: NSPopover
    
    init() {
        popover = NSPopover()
        messageView = MessageView()
        popover.behavior = .transient
        popover.contentViewController = messageView
    }
    
    public func show(message: String, sender: NSView) {
        let positioningView = sender
        let positioningRect = NSZeroRect
        let preferredEdge: NSRectEdge = .maxX
        messageView.message = message

        popover.show(relativeTo: positioningRect, of: positioningView, preferredEdge: preferredEdge)
    }
}

class MessageView: NSViewController {
    
    @IBOutlet weak var messageField: NSTextField!
    
    var message: String?

    override func loadView() {
        if Bundle.main.path(forResource: "MessageView", ofType: "nib") != nil {
            super.loadView()
            return
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 80))
        let label = NSTextField(wrappingLabelWithString: message ?? "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = 250
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14)
        ])
        self.view = container
        self.messageField = label
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        if let message = message {
            self.messageField?.stringValue = message
        }
    }
}
