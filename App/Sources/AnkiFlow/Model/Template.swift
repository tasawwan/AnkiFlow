import Foundation

struct TemplateBlank: Codable, Identifiable, Equatable {
    var key: String
    var label: String
    var multiline: Bool
    var optional: Bool

    var id: String { key }

    init(key: String, label: String? = nil, multiline: Bool = false, optional: Bool = false) {
        self.key = key
        self.label = label ?? key.capitalized
        self.multiline = multiline
        self.optional = optional
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? key.capitalized
        multiline = try c.decodeIfPresent(Bool.self, forKey: .multiline) ?? false
        optional = try c.decodeIfPresent(Bool.self, forKey: .optional) ?? false
    }
}

/// A question shape with named blanks. Stored as JSON, but authored in the
/// Template Editor -- the JSON is the save format, not the interface.
/// Where a template's cards carry their slides.
///
/// This is part of the question's *shape*, which is what a template is: "name
/// this structure" wants the slide on the front, "explain this pathway" wants it
/// on the back, and a few want both. Left to each question it would be a
/// decision you make over and over; on the template you make it once.
enum TemplateSlides: String, Codable, CaseIterable, Identifiable {
    case back, front, both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .back:  return "Back"
        case .front: return "Front"
        case .both:  return "Both"
        }
    }

    var showsFront: Bool { self != .back }
    var showsBack: Bool { self != .front }
}

struct Template: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var front: String
    var back: String
    var blanks: [TemplateBlank]
    var slides: TemplateSlides

    init(id: String = ULID.generate(), name: String, front: String = "", back: String = "",
         blanks: [TemplateBlank] = [], slides: TemplateSlides = .back) {
        self.id = id
        self.name = name
        self.front = front
        self.back = back
        self.blanks = blanks
        self.slides = slides
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        front = try c.decodeIfPresent(String.self, forKey: .front) ?? ""
        back = try c.decodeIfPresent(String.self, forKey: .back) ?? ""
        blanks = try c.decodeIfPresent([TemplateBlank].self, forKey: .blanks) ?? []
        slides = try c.decodeIfPresent(TemplateSlides.self, forKey: .slides) ?? .back
    }

    /// Changes to a template change every card built from it, so it feeds the
    /// content hash of each question that uses it.
    var fingerprint: String {
        "\(id)|\(front)|\(back)|\(slides.rawValue)|" + blanks.map(\.key).joined(separator: ",")
    }

    /// Substitute `{{key}}` placeholders. Unfilled blanks collapse to an empty
    /// string rather than leaving the placeholder visible on a card.
    func render(blanks values: [String: String]) -> (front: String, back: String) {
        (substitute(front, values), substitute(back, values))
    }

    private func substitute(_ text: String, _ values: [String: String]) -> String {
        var out = text
        for blank in blanks {
            out = out.replacingOccurrences(of: "{{\(blank.key)}}", with: values[blank.key] ?? "")
        }
        return out
    }

    /// Blank keys actually referenced by the text, in order of appearance.
    static func keys(in text: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        var remainder = Substring(text)
        while let open = remainder.range(of: "{{"),
              let close = remainder.range(of: "}}", range: open.upperBound..<remainder.endIndex) {
            let key = String(remainder[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, seen.insert(key).inserted { found.append(key) }
            remainder = remainder[close.upperBound...]
        }
        return found
    }
}

/// Templates live outside any one library so they follow you between courses.
@MainActor
final class TemplateStore: ObservableObject {
    @Published private(set) var templates: [Template] = []

    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directory = support
                .appendingPathComponent(AnkiIdentity.appName, isDirectory: true)
                .appendingPathComponent("Templates", isDirectory: true)
        }
        reload()
    }

    func template(id: String?) -> Template? {
        guard let id else { return nil }
        return templates.first { $0.id == id }
    }

    func reload() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        templates = urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> Template? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Template.self, from: data)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func save(_ template: Template) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(template) else { return false }
        let url = directory.appendingPathComponent("\(template.id).json")
        do {
            try AtomicWrite.write(data, to: url)
            reload()
            return true
        } catch {
            return false
        }
    }

    func delete(_ template: Template) {
        let url = directory.appendingPathComponent("\(template.id).json")
        try? FileManager.default.removeItem(at: url)
        reload()
    }
}
