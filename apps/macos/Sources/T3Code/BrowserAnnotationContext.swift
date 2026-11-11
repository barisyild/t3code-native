import Foundation

struct BrowserRegionAnnotation: Equatable, Sendable {
    static let maximumCommentLength = 8_000

    let id = UUID().uuidString.lowercased()
    let pageURL: String
    let pageTitle: String
    let comment: String

    init(address: String?, pageTitle: String, comment: String) {
        var components = address.flatMap { URLComponents(string: $0) }
        components?.user = nil
        components?.password = nil
        pageURL = Self.bounded(components?.url?.absoluteString ?? "about:blank", length: 2_048)
        self.pageTitle = Self.bounded(pageTitle, length: 2_048)
        self.comment = Self.bounded(comment.trimmingCharacters(in: .whitespacesAndNewlines), length: Self.maximumCommentLength)
    }

    var fileName: String { "preview-annotation-\(id).png" }

    func records(for attachment: Wire) -> [Wire] {
        guard attachment["type"].string == "image",
              let attachmentID = attachment["id"].string, let name = attachment["name"].string,
              let mimeType = attachment["mimeType"].string, let bytes = attachment["sizeBytes"].int else { return [] }
        let screenshotID = "image_\(id)"
        return [
            .object(["version": .int(1), "contextId": .string("preview-annotation_\(id)"),
                     "kind": .string("preview-annotation"), "label": .string("Browser Region"),
                     "annotationId": .string(id), "pageUrl": .string(pageURL), "pageTitle": .string(pageTitle),
                     "comment": .string(comment), "targetSummary": .string("1 marked region"),
                     "styleChanges": .array([]), "regionCount": .int(1), "screenshotContextId": .string(screenshotID)]),
            .object(["version": .int(1), "contextId": .string(screenshotID), "kind": .string("image"),
                     "label": .string("Browser Region"), "attachmentId": .string(attachmentID),
                     "name": .string(name), "mimeType": .string(mimeType), "sizeBytes": .int(bytes)]),
        ]
    }

    private static func bounded(_ text: String, length: Int) -> String {
        String(decoding: text.utf16.prefix(length), as: UTF16.self)
    }
}

enum BrowserAnnotationContext {
    private struct Reference: Hashable {
        let kind: String
        let id: String

        var markdown: String {
            let prefix = kind == "image" ? "!" : ""
            let label = kind == "image" ? "Cropped screenshot" : "Browser Region"
            return "\(prefix)[\(label)](t3-context://v1/\(kind)/\(id))"
        }
    }

    private static let link = try! NSRegularExpression(
        pattern: #"!?\[[^\]\n]{0,512}\]\(t3-context://v1/(preview-annotation|image)/([a-zA-Z0-9_-]{1,128})\)"#
    )

    static func attachmentLabel(_ name: String) -> String {
        name.hasPrefix("preview-annotation-") && name.hasSuffix(".png") ? "Browser Region" : name
    }

    static func messageContext(_ records: [Wire]) -> Wire {
        .object(["version": .int(1), "records": .array(records)])
    }

    static func retaining(_ records: [Wire], attachments: [Wire]) -> [Wire] {
        let attachmentIDs = Set(attachments.compactMap { $0["id"].string })
        let attached = records.filter { record in
            guard ["image", "file"].contains(record["kind"].string ?? "") else { return true }
            return record["attachmentId"].string.map(attachmentIDs.contains) == true
        }
        let images = Set(attached.compactMap { record in
            record["kind"].string == "image" ? record["contextId"].string : nil
        })
        return attached.filter { record in
            guard record["kind"].string == "preview-annotation",
                  let screenshot = record["screenshotContextId"].string else { return true }
            return images.contains(screenshot)
        }
    }

    static func linkedRecords(in context: Wire, attachments: [Wire]) -> [Wire] {
        linkedRecords(retaining(context["records"].array, attachments: attachments))
    }

    private static func linkedRecords(_ records: [Wire]) -> [Wire] {
        let images = records.filter { $0["kind"].string == "image" }
        let imageIDs = Set(images.compactMap { $0["contextId"].string })
        let annotations = records.filter {
            $0["kind"].string == "preview-annotation" && $0["screenshotContextId"].string.map(imageIDs.contains) == true
        }
        let screenshots = Set(annotations.compactMap { $0["screenshotContextId"].string })
        return annotations + images.filter { $0["contextId"].string.map(screenshots.contains) == true }
    }

    // The server projects context records only when the message references them.
    static func addingReferences(to text: String, records: [Wire]) -> String {
        let references = references(in: records)
        guard !references.isEmpty else { return text }
        var present = Set(occurrences(in: text).map(\.reference))
        let appended = references.filter { present.insert($0).inserted }.map(\.markdown).joined(separator: " ")
        guard !appended.isEmpty else { return text }
        let prompt = QueuedMessage.recallableText(text)
        return prompt.isEmpty ? appended : prompt + "\n\n" + appended
    }

    static func removingReferences(from text: String, context: Wire) -> String {
        let occurrences = occurrences(in: text)
        guard !occurrences.isEmpty else { return text }
        let references = Set(references(in: context["records"].array))
        let removed = occurrences.filter { references.contains($0.reference) }
        guard !removed.isEmpty else { return text }
        let remaining = NSMutableString(string: text)
        for occurrence in removed.reversed() { remaining.deleteCharacters(in: occurrence.range) }
        return (remaining as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func references(in records: [Wire]) -> [Reference] {
        linkedRecords(records).compactMap { record in
            guard let kind = record["kind"].string, let id = record["contextId"].string,
                  id.range(of: #"\A[a-zA-Z0-9_-]{1,128}\z"#, options: .regularExpression) != nil else { return nil }
            return Reference(kind: kind, id: id)
        }
    }

    private static func occurrences(in text: String) -> [(reference: Reference, range: NSRange)] {
        guard text.contains("](t3-context://v1/") else { return [] }
        let source = text as NSString
        return link.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            let kind = source.substring(with: match.range(at: 1))
            let id = source.substring(with: match.range(at: 2))
            return (Reference(kind: kind, id: id), match.range)
        }
    }

    static func comments(in context: Wire) -> [String] {
        context["records"].array.compactMap { record in
            guard record["kind"].string == "preview-annotation",
                  let comment = record["comment"].string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !comment.isEmpty else { return nil }
            return comment
        }
    }
}
