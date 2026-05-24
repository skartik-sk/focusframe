import Foundation
import AppKit

class ClipboardHelper {
    
    static func copyToClipboard(url: URL) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        // Try to copy the file to clipboard
        let fileURLs = [url] as [NSURL]
        let success = pasteboard.writeObjects(fileURLs)
        
        if !success {
            throw ClipboardError.copyFailed
        }
    }
    
    static func copyImageToClipboard(image: NSImage) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        let success = pasteboard.setData(image.tiffRepresentation, forType: .tiff)
        
        if !success {
            throw ClipboardError.copyFailed
        }
    }
    
    static func copyTextToClipboard(text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        let success = pasteboard.setString(text, forType: .string)
        
        if !success {
            throw ClipboardError.copyFailed
        }
    }
    
    static func copyVideoToClipboard(url: URL) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        // Copy as file reference
        let fileURLs = [url] as [NSURL]
        let success = pasteboard.writeObjects(fileURLs)
        
        if !success {
            throw ClipboardError.copyFailed
        }
    }
    
    static func copyGIFToClipboard(url: URL) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        // Copy as file reference
        let fileURLs = [url] as [NSURL]
        let success = pasteboard.writeObjects(fileURLs)
        
        if !success {
            throw ClipboardError.copyFailed
        }
        
        // Also try to copy as image if the GIF is small enough
        if let image = NSImage(contentsOf: url) {
            _ = pasteboard.setData(image.tiffRepresentation, forType: .tiff)
        }
    }
    
    static func getClipboardContents() -> [NSPasteboard.PasteboardType: Any] {
        let pasteboard = NSPasteboard.general
        var contents: [NSPasteboard.PasteboardType: Any] = [:]
        
        for type in pasteboard.types ?? [] {
            if let data = pasteboard.string(forType: type) {
                contents[type] = data
            } else if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
                contents[type] = image
            }
        }
        
        return contents
    }
    
    static func clearClipboard() {
        NSPasteboard.general.clearContents()
    }
}

enum ClipboardError: Error {
    case copyFailed
    case noContent
    case unsupportedType
}
