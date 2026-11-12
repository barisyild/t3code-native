import AppKit
import Testing
@testable import T3Code

@MainActor
struct ComposerKeyboardTests {
    @Test(arguments: [UInt16(36), UInt16(76)])
    func returnSendsTheDraftWithoutInsertingANewline(_ keyCode: UInt16) throws {
        let (window, composer, editor) = try composerWindow()
        var sent: [String] = []
        composer.onSend = { sent.append($0.text) }

        editor.keyDown(with: try returnEvent(window: window, keyCode: keyCode))
        editor.keyDown(with: try returnEvent(window: window, keyCode: keyCode, isRepeat: true))

        #expect(sent == ["A draft"])
        #expect(editor.string == "A draft")
    }

    @Test func shiftReturnInsertsANewlineWithoutSending() throws {
        let (window, composer, editor) = try composerWindow()
        var sent: [String] = []
        composer.onSend = { sent.append($0.text) }

        editor.keyDown(with: try returnEvent(window: window, modifiers: .shift))

        #expect(sent.isEmpty)
        #expect(editor.string.hasPrefix("A draft"))
        #expect(editor.string.last?.isNewline == true)
    }

    @Test func mixedClipboardAttachmentsArePreparedBeforeReturnCanSend() async throws {
        let (window, composer, editor) = try composerWindow()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("notes.txt")
        try Data("Clipboard file".utf8).write(to: note)

        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixel = try #require(bitmap.bitmapData)
        pixel[0] = 255
        pixel[1] = 0
        pixel[2] = 0
        pixel[3] = 255
        let tiff = try #require(bitmap.tiffRepresentation)
        let file = NSPasteboardItem()
        file.setString(note.absoluteString, forType: .fileURL)
        file.setString("Clipboard caption", forType: .string)
        file.setData(tiff, forType: .tiff)
        let image = NSPasteboardItem()
        image.setData(tiff, forType: .tiff)
        let pasteboard = NSPasteboard(name: .init("T3ClipboardTest-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        try #require(pasteboard.writeObjects([file, image]))

        var inputs: [AttachmentInput] = []
        composer.onReadAttachment = { [weak composer] board in
            inputs = AttachmentInput.read(board)
            composer?.setPreparingAttachments(true)
            return !inputs.isEmpty
        }
        var sent: [ComposerView.Draft] = []
        composer.onSend = { sent.append($0) }

        #expect(editor.readSelection(from: pasteboard, type: .string))
        #expect(editor.string == "A draftClipboard caption")
        #expect(inputs.isEmpty)
        editor.insertText("A draft", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try #require(editor.readSelection(from: pasteboard))
        #expect(inputs.count == 2)
        #expect(editor.string == "A draft")
        editor.keyDown(with: try returnEvent(window: window))
        #expect(sent.isEmpty)

        let additions = try await AttachmentInput.prepare(inputs)
        try composer.addAttachments(additions)
        composer.setPreparingAttachments(false)
        editor.keyDown(with: try returnEvent(window: window))

        try #require(sent.count == 1)
        #expect(sent[0].text == "A draft")
        #expect(sent[0].attachments.map(\.name) == ["notes.txt", "Pasted Image.png"])
        #expect(sent[0].attachments.first?.url == note)
        let pasted = try #require(sent[0].attachments.last)
        #expect(pasted.metadata["mimeType"]?.string == "image/png")
        #expect(try Data(contentsOf: pasted.url).starts(with: [0x89, 0x50, 0x4e, 0x47]))
    }

    @Test func returnDuringMarkedTextDoesNotSend() throws {
        let (window, composer, editor) = try composerWindow()
        var sent: [String] = []
        composer.onSend = { sent.append($0.text) }
        editor.setMarkedText("候補", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(editor.hasMarkedText())

        editor.keyDown(with: try returnEvent(window: window))

        #expect(sent.isEmpty)
    }

    @Test func optionUpEditsTheQueueAtTheBeginningOfTheDraft() throws {
        let (window, composer, editor) = try composerWindow()
        var edits = 0
        composer.onEditQueued = { edits += 1; return true }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "\u{f700}",
                                                 charactersIgnoringModifiers: "\u{f700}", isARepeat: false, keyCode: 126))
        editor.keyDown(with: event)
        #expect(edits == 0)

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.keyDown(with: event)
        #expect(edits == 1)
        #expect(editor.string == "A draft")
    }

    @Test func returnInsertsACommandBeforeItCanSendTheMessage() throws {
        let (window, composer, editor) = try composerWindow()
        let provider = try #require(Provider(.object([
            "instanceId": .string("codex"), "driver": .string("codex"), "enabled": .bool(true),
            "slashCommands": .array([.object(["name": .string("status")])]),
        ])))
        composer.render(providers: [provider], defaultModel: .null, thread: nil, checkout: .root(),
                        projectAvailable: true, canOperate: true, sending: false)
        var sent: [String] = []
        composer.onSend = { sent.append($0.text) }
        editor.insertText("/sta", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))

        editor.keyDown(with: try returnEvent(window: window))
        #expect(editor.string == "/status ")
        #expect(sent.isEmpty)
        editor.keyDown(with: try returnEvent(window: window))
        #expect(sent == ["/status "])
    }

    @Test func clearArmsFreshContextForTheNextMessage() throws {
        let (window, composer, editor) = try composerWindow()
        composer.setCommandContext(connection: nil, cwd: nil, freshSession: true)
        var sent: [ComposerView.Draft] = []
        composer.onSend = { sent.append($0) }
        editor.insertText("/clear", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))

        editor.keyDown(with: try returnEvent(window: window))
        #expect(editor.string.isEmpty)
        #expect(sent.isEmpty)
        editor.insertText("A fresh prompt", replacementRange: NSRange(location: 0, length: 0))
        editor.keyDown(with: try returnEvent(window: window))
        #expect(sent.first?.text == "A fresh prompt")
        #expect(sent.first?.freshContext == true)
    }

    @Test func returnSavesAnEditedQueuePromptThatLooksLikeALocalCommand() throws {
        let (window, composer, editor) = try composerWindow()
        composer.setCommandContext(connection: nil, cwd: nil, freshSession: true)
        composer.renderQueueEdit(.editing)
        var sent: [String] = []
        var saved: [String] = []
        composer.onSend = { sent.append($0.text) }
        composer.onSaveQueuedEdit = { saved.append($0.text) }
        editor.insertText("/clear", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))

        editor.keyDown(with: try returnEvent(window: window))

        #expect(saved == ["/clear"])
        #expect(sent.isEmpty)
        #expect(editor.string == "/clear")
        #expect(!composer.currentDraft.freshContext)
    }

    private func composerWindow() throws -> (NSWindow, ComposerView, NSTextView) {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 630, height: 150)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let composer = ComposerView(frame: frame)
        let selection: Wire = .object(["instanceId": .string("codex"), "model": .string("test")])
        composer.load(.init(text: "A draft", model: selection))
        composer.render(providers: [], defaultModel: .null, thread: nil, checkout: .root(),
                        projectAvailable: true, canOperate: true, sending: false)
        window.contentView = composer
        composer.focus()
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        return (window, composer, editor)
    }

    private func returnEvent(window: NSWindow, keyCode: UInt16 = 36,
                             modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) throws -> NSEvent {
        let characters = keyCode == 76 ? "\u{3}" : "\r"
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: keyCode))
    }
}
