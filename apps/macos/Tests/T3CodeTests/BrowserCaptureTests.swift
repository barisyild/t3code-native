import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import T3Code

struct BrowserCaptureTests {
    @Test func screenshotKeepsViewportPixelsAndRegionUsesTopLeftCoordinates() async throws {
        let context = try #require(CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 48, width: 128, height: 48))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 48))
        let frame = try #require(context.makeImage())
        let target = BrowserTabTarget(environmentID: "fixture", connection: UUID(), threadID: "thread", tabID: "tab", title: "Page")
        let snapshot = BrowserSnapshot(image: frame, target: target, address: "https://fixture:credential@example.test/page")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t3-browser-capture-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshot = try await BrowserScreenshot.save(snapshot, in: directory)
        let image = try await screenshot.loadImage()
        #expect(image.width == 128 && image.height == 96)
        #expect(BrowserScreenshot.latest(in: directory)?.file.resolvingSymlinksInPath() == screenshot.file.resolvingSymlinksInPath())
        let attachment = try await BrowserImageCapture.region(
            snapshot, selection: CGRect(x: 0.25, y: 0.125, width: 0.5, height: 0.25), comment: "Inspect this area."
        )
        let source = try #require(CGImageSourceCreateWithURL(attachment.url as CFURL, nil))
        let cropped = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(cropped.width == 64 && cropped.height == 24)
        var sample = [UInt8](repeating: 0, count: 4)
        sample.withUnsafeMutableBytes { bytes in
            guard let pixel = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            pixel.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(sample[0] > 240 && sample[2] < 10)
        #expect(attachment.browserAnnotation?.pageURL == "https://example.test/page")
        #expect(attachment.browserAnnotation?.comment == "Inspect this area.")
        #expect(attachment.name == attachment.browserAnnotation?.fileName)
    }

    @Test func regionContextBindsTheUploadedImageAndDropsItWithTheAttachment() throws {
        let annotation = BrowserRegionAnnotation(address: nil, pageTitle: "Page", comment: "  This control is clipped.  ")
        let attachment: Wire = .object(["id": .string("pending-fixture"), "type": .string("image"),
                                        "name": .string(annotation.fileName), "mimeType": .string("image/png"), "sizeBytes": .int(400)])
        let records = annotation.records(for: attachment)
        let image = try #require(records.first { $0["kind"].string == "image" })
        let region = try #require(records.first { $0["kind"].string == "preview-annotation" })
        #expect(region["screenshotContextId"] == image["contextId"])
        #expect(image["attachmentId"] == attachment["id"])
        #expect(region["comment"].string == "This control is clipped.")
        let context = BrowserAnnotationContext.messageContext(records)
        #expect(BrowserAnnotationContext.linkedRecords(in: context, attachments: [attachment]) == records)
        #expect(BrowserAnnotationContext.comments(in: context) == ["This control is clipped."])
        let regionID = try #require(region["contextId"].string)
        let imageID = try #require(image["contextId"].string)
        let regionReference = "[Marked button](t3-context://v1/preview-annotation/\(regionID))"
        let imageReference = "![Cropped screenshot](t3-context://v1/image/\(imageID))"
        let other = "![Other screenshot](t3-context://v1/image/other)"
        let prompt = "Inspect \(other)"
        let outgoing = BrowserAnnotationContext.addingReferences(to: "\(prompt) \(regionReference)", records: records)
        #expect(outgoing == "\(prompt) \(regionReference)\n\n\(imageReference)")
        #expect(BrowserAnnotationContext.addingReferences(to: outgoing, records: records) == outgoing)
        #expect(BrowserAnnotationContext.removingReferences(from: outgoing, context: context) == prompt)
        let annotationOnly = BrowserAnnotationContext.addingReferences(to: QueuedMessage.attachmentOnlyText, records: records)
        #expect(annotationOnly == "[Browser Region](t3-context://v1/preview-annotation/\(regionID)) \(imageReference)")
        #expect(BrowserAnnotationContext.removingReferences(from: annotationOnly, context: context).isEmpty)
        let unrelated: Wire = .object(["kind": .string("terminal"), "contextId": .string("terminal-fixture")])
        let retained = BrowserAnnotationContext.retaining(records + [unrelated], attachments: [])
        #expect(retained == [unrelated])
        #expect(BrowserAnnotationContext.addingReferences(to: prompt, records: retained) == prompt)
    }
}
