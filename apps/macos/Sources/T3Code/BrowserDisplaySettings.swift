import Foundation

struct BrowserViewportSize: Equatable, Sendable {
    static let dimensions = 240...3_840
    static let maximumArea = 3_840 * 2_160
    static let customDefault = Self(validWidth: 1_024, height: 768)

    let width: Int
    let height: Int

    init?(width: Int, height: Int) {
        guard Self.dimensions.contains(width), Self.dimensions.contains(height),
              width * height <= Self.maximumArea else { return nil }
        self.init(validWidth: width, height: height)
    }

    private init(validWidth: Int, height: Int) {
        width = validWidth
        self.height = height
    }

    var title: String { "\(width) × \(height)" }
    var rotated: Self { Self(validWidth: height, height: width) }
}

struct BrowserViewportPreset: Sendable {
    enum Group: String, CaseIterable, Sendable {
        case phone = "Phones", tablet = "Tablets and Displays"
    }

    let id: String
    let name: String
    let group: Group
    let size: BrowserViewportSize

    private init?(_ id: String, _ name: String, _ group: Group, _ width: Int, _ height: Int) {
        guard let size = BrowserViewportSize(width: width, height: height) else { return nil }
        self.id = id
        self.name = name
        self.group = group
        self.size = size
    }

    var setting: BrowserViewportSetting { .fixed(size, presetID: id) }

    // CSS viewport sizes from packages/shared/src/previewViewport.ts.
    static let all = ([
        .init("iphone-se", "iPhone SE", .phone, 375, 667),
        .init("iphone-xr", "iPhone XR", .phone, 414, 896),
        .init("iphone-12-pro", "iPhone 12 Pro", .phone, 390, 844),
        .init("iphone-14-pro-max", "iPhone 14 Pro Max", .phone, 430, 932),
        .init("pixel-7", "Pixel 7", .phone, 412, 915),
        .init("samsung-galaxy-s8-plus", "Samsung Galaxy S8+", .phone, 360, 740),
        .init("samsung-galaxy-s20-ultra", "Samsung Galaxy S20 Ultra", .phone, 412, 915),
        .init("ipad-mini", "iPad Mini", .tablet, 768, 1_024),
        .init("ipad-air", "iPad Air", .tablet, 820, 1_180),
        .init("ipad-pro", "iPad Pro", .tablet, 1_024, 1_366),
        .init("surface-pro-7", "Surface Pro 7", .tablet, 912, 1_368),
        .init("surface-duo", "Surface Duo", .phone, 540, 720),
        .init("galaxy-z-fold-5", "Galaxy Z Fold 5", .phone, 344, 882),
        .init("asus-zenbook-fold", "Asus Zenbook Fold", .tablet, 853, 1_280),
        .init("samsung-galaxy-a51-71", "Samsung Galaxy A51/71", .phone, 412, 914),
        .init("nest-hub", "Nest Hub", .tablet, 1_024, 600),
        .init("nest-hub-max", "Nest Hub Max", .tablet, 1_280, 800),
    ] as [Self?]).compactMap { $0 }

    private static let storedNames = [
        "desktop-1920x1080": "Desktop", "desktop-1440x900": "Desktop",
        "laptop-1366x768": "Laptop", "laptop-1280x800": "Laptop",
        "ipad-pro-11": "iPad Pro 11", "iphone-15-pro": "iPhone 15 Pro",
        "pixel-8": "Pixel 8", "galaxy-s24": "Galaxy S24",
    ]

    static func name(for id: String) -> String? {
        all.first { $0.id == id }?.name ?? storedNames[id]
    }
}

enum BrowserViewportSetting: Equatable, Sendable {
    case fill
    case fixed(BrowserViewportSize, presetID: String?)

    init(_ value: Wire) {
        guard let tag = value["_tag"].string, tag == "preset" || tag == "freeform",
              let width = value["width"].int, let height = value["height"].int,
              let size = BrowserViewportSize(width: width, height: height) else {
            self = .fill
            return
        }
        let preset = tag == "preset" ? value["presetId"].string : nil
        self = .fixed(size, presetID: preset.flatMap { BrowserViewportPreset.name(for: $0) == nil ? nil : $0 })
    }

    var size: BrowserViewportSize? {
        if case .fixed(let size, _) = self { return size }
        return nil
    }

    var presetID: String? {
        if case .fixed(_, let id) = self { return id }
        return nil
    }

    var title: String {
        guard let size else { return "Fill Panel" }
        return presetID.flatMap(BrowserViewportPreset.name(for:)).map { "\($0) · \(size.title)" } ?? size.title
    }

    var rotated: Self? {
        guard case .fixed(let size, let id) = self, size.width != size.height else { return nil }
        return .fixed(size.rotated, presetID: id)
    }

    var wire: Wire {
        switch self {
        case .fill:
            return .object(["_tag": .string("fill")])
        case .fixed(let size, let id):
            var fields: Payload = ["_tag": .string(id == nil ? "freeform" : "preset"),
                                   "width": .int(size.width), "height": .int(size.height)]
            fields["presetId"] = id.map(Wire.string)
            return .object(fields)
        }
    }
}

struct BrowserZoom: Equatable, Sendable {
    enum Direction { case increase, decrease, actualSize }

    private static let factors = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0]
    static let levels = factors.map(Self.init(validFactor:))
    static let actualSize = Self(validFactor: 1)

    let factor: Double

    init?(_ factor: Double?) {
        guard let factor, Self.factors.contains(factor) else { return nil }
        self.init(validFactor: factor)
    }

    private init(validFactor: Double) { factor = validFactor }

    var title: String { "\(Int((factor * 100).rounded()))%" }

    func step(_ direction: Direction) -> Self? {
        switch direction {
        case .increase: Self.levels.first { $0.factor > factor }
        case .decrease: Self.levels.last { $0.factor < factor }
        case .actualSize: self == .actualSize ? nil : .actualSize
        }
    }
}

enum BrowserPageAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    var title: String { rawValue.capitalized }
}

struct BrowserDisplaySettings: Equatable, Sendable {
    var viewport: BrowserViewportSetting
    var zoom: BrowserZoom
    var appearance: BrowserPageAppearance

    init(_ value: Wire = .null) {
        viewport = BrowserViewportSetting(value["viewport"])
        zoom = BrowserZoom(value["zoomFactor"].double) ?? .actualSize
        appearance = value["colorScheme"].string.flatMap(BrowserPageAppearance.init(rawValue:)) ?? .system
    }

    var wire: Wire {
        .object(["viewport": viewport.wire, "zoomFactor": .double(zoom.factor), "colorScheme": .string(appearance.rawValue)])
    }

    var newTabAdjustments: Payload {
        var fields: Payload = [:]
        if zoom != .actualSize { fields["zoomFactor"] = .double(zoom.factor) }
        if appearance != .system { fields["colorScheme"] = .string(appearance.rawValue) }
        return fields
    }
}
