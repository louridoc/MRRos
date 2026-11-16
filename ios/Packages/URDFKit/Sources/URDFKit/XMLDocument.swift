import Foundation

/// Tiny DOM built on Foundation's SAX `XMLParser` (available on iOS and macOS without libxml
/// bindings). URDF files are small, so holding the whole tree is fine.
public final class XMLElement: @unchecked Sendable {
    public let name: String
    public let attributes: [String: String]
    public private(set) var children: [XMLElement] = []
    public private(set) var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    fileprivate func append(_ child: XMLElement) {
        children.append(child)
    }

    fileprivate func append(text: String) {
        self.text += text
    }

    public func first(_ name: String) -> XMLElement? {
        children.first { $0.name == name }
    }

    public func all(_ name: String) -> [XMLElement] {
        children.filter { $0.name == name }
    }

    public subscript(attr: String) -> String? {
        attributes[attr]
    }
}

enum XMLDocument {
    static func parse(_ data: Data) throws -> XMLElement {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse(), let root = builder.root else {
            let line = parser.lineNumber
            let reason = parser.parserError?.localizedDescription ?? builder.error ?? "unknown"
            throw URDFError.malformedXML(line: line, reason: reason)
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLElement?
        var error: String?
        private var stack: [XMLElement] = []

        func parser(
            _: XMLParser, didStartElement name: String, namespaceURI _: String?,
            qualifiedName _: String?, attributes: [String: String]
        ) {
            let el = XMLElement(name: name, attributes: attributes)
            if let parent = stack.last {
                parent.append(el)
            } else if root == nil {
                root = el
            }
            stack.append(el)
        }

        func parser(
            _: XMLParser,
            didEndElement _: String,
            namespaceURI _: String?,
            qualifiedName _: String?
        ) {
            _ = stack.popLast()
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            stack.last?.append(text: string)
        }

        func parser(_: XMLParser, parseErrorOccurred parseError: Error) {
            error = parseError.localizedDescription
        }
    }
}
