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

/// An extra question a shape can also ask, behind a checkbox.
///
/// There is nowhere to store "this box is ticked": a template is a lens and a
/// card carries nothing but its own words. So the sentence being in the front
/// *is* the checkbox -- ticking appends it, unticking takes it away, and the
/// box works out its own state by looking. That is what makes a checkbox work
/// on a card written before the option existed, and it is why `question` is a
/// fixed phrase rather than something you word per card.
struct TemplateOption: Codable, Identifiable, Equatable {
    var key: String
    /// The checkbox's label.
    var label: String
    /// Appended to the front, exactly, when on.
    var question: String
    /// Appended to the back when on. May carry blanks of its own.
    var answer: String = ""
    var blanks: [TemplateBlank] = []
    var defaultOn: Bool = false

    var id: String { key }
}

/// A question shape with named blanks, authored in the Template Editor.
///
/// A template is a *lens*, not a card format. Nothing about it is written into a
/// question file: a question built from one is an ordinary Basic card whose
/// front and back hold the finished text, and the template's only job is to
/// recognise that text again -- to put the card in its own tab and to offer the
/// blanks back as fields you can type in. That is why deleting a template can
/// never damage a card. The card was never pointing at it.
struct Template: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var front: String
    var back: String
    var blanks: [TemplateBlank]
    var slides: TemplateSlides
    /// Tags every question made under this template is born with. A template is
    /// a kind of question you write over and over, and the tags that go with it
    /// are part of that shape -- "pharm", "high-yield" -- so they belong here
    /// rather than being re-ticked on every card.
    var tags: [String]
    /// Which kind of card this shape makes. A template is a way of writing a
    /// card, and occlusion and cloze cards are written over and over too -- the
    /// wording above the image, the sentence you keep clozing the same way.
    /// Never `.template`: that was the old scheme, where a template was a card
    /// type rather than a way of writing one.
    var kind: QuestionKind
    /// Off means you stop *making* cards with it. It still recognises the ones
    /// you already made: a lecture holding its cards still shows its tab, read
    /// only, so old work stays legible in the shape it was written in. Turning
    /// a template off is not the same as being finished with it.
    var enabled: Bool
    /// Extra questions this shape can also ask, each behind a checkbox.
    var options: [TemplateOption] = []

    init(id: String = ULID.generate(), name: String, front: String = "", back: String = "",
         blanks: [TemplateBlank] = [], slides: TemplateSlides = .back, tags: [String] = [],
         kind: QuestionKind = .basic, enabled: Bool = true,
         options: [TemplateOption] = []) {
        self.id = id
        self.name = name
        self.front = front
        self.back = back
        self.blanks = blanks
        self.slides = slides
        self.tags = tags
        self.kind = kind == .template ? .basic : kind
        self.enabled = enabled
        self.options = options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        front = try c.decodeIfPresent(String.self, forKey: .front) ?? ""
        back = try c.decodeIfPresent(String.self, forKey: .back) ?? ""
        blanks = try c.decodeIfPresent([TemplateBlank].self, forKey: .blanks) ?? []
        slides = try c.decodeIfPresent(TemplateSlides.self, forKey: .slides) ?? .back
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        let storedKind = (try? c.decodeIfPresent(QuestionKind.self, forKey: .kind)).flatMap { $0 }
        kind = (storedKind == .template ? nil : storedKind) ?? .basic
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        options = try c.decodeIfPresent([TemplateOption].self, forKey: .options) ?? []
    }

    /// One of the shapes the app ships with. These can be edited and turned off
    /// but not deleted -- a starting point you can get back to is worth more
    /// than the one click it costs to hide one you do not want.
    var isBuiltIn: Bool { id.hasPrefix(Template.builtInPrefix) }
    static let builtInPrefix = "ankiflow."

    /// Cards a template writes carry their slides where the shape says, except
    /// for the two kinds that have only one place to put them.
    var effectiveSlides: TemplateSlides {
        kind == .occlusion || kind == .cloze ? .back : slides
    }

    /// Only still consulted by questions written before templates became a
    /// viewer-side lens, which store a `templateId` and are converted the first
    /// time their lecture is opened. Nothing written today feeds it.
    var fingerprint: String {
        "\(id)|\(front)|\(back)|\(slides.rawValue)|" + blanks.map(\.key).joined(separator: ",")
    }

    /// Substitute `{{key}}` placeholders. Unfilled blanks collapse to an empty
    /// string rather than leaving the placeholder visible on a card.
    /// An unfilled optional blank leaves the blank line that was there to
    /// separate it. Nobody typed that, so it does not belong on the card -- and
    /// leaving it would mean the card no longer reads back as this shape.
    static func tidy(_ text: String) -> String {
        var out = text
        while out.contains("\n\n\n") {
            out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Driven by the keys the text actually contains, not by the `blanks` array.
    /// The two can disagree -- a template edited by hand, a blank renamed -- and
    /// a leftover `{{key}}` visible on a card is the worst of the two failures.
    private func substitute(_ text: String, _ values: [String: String]) -> String {
        var out = text
        for key in Template.keys(in: text) {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: values[key] ?? "")
        }
        return out
    }

    /// Blank keys actually referenced by the text, in order of appearance.
    static func keys(in text: String) -> [String] {
        Template.pieces(text)
            .compactMap { piece -> String? in
                if case .blank(let key) = piece { return key }
                return nil
            }
            .reduce(into: [String]()) { out, key in
                if !out.contains(key) { out.append(key) }
            }
    }
}

// MARK: - Reading a rendered card back into blanks

extension Template {
    /// A template string decomposed into the parts that have to line up.
    enum Piece: Equatable {
        case literal(String)
        case blank(String)
    }

    /// Split `"What supplies {{structure}}?"` into literal, blank, literal.
    ///
    /// A `{{}}` with nothing in it is not a blank -- it stays literal text, so a
    /// template that happens to contain braces still round-trips.
    static func pieces(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var literal = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{"),
              let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            literal += rest[rest.startIndex..<open.lowerBound]
            let key = String(rest[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            // Anki's cloze markup wears the same braces: `{{c1::answer}}`, and
            // `{{cloze:Text}}` in a note type. Neither is a blank, and reading
            // one as a blank named "c1::answer" would make a cloze template
            // impossible to write. A colon pair is the tell.
            if key.isEmpty || key.contains("::") || key.contains(":") {
                literal += rest[open.lowerBound..<close.upperBound]
            } else {
                if !literal.isEmpty {
                    out.append(.literal(literal))
                    literal = ""
                }
                out.append(.blank(key))
            }
            rest = rest[close.upperBound...]
        }
        literal += rest
        if !literal.isEmpty { out.append(.literal(literal)) }
        return out
    }

    /// The inverse of `render`: given the finished text, work out what was typed
    /// into each blank. `nil` means this text cannot have come from this shape.
    ///
    /// Two rules make this predictable rather than clever. The literals bracket
    /// the values -- the first must be a prefix and the last a suffix -- so a
    /// value containing the closing punctuation still parses: "What is {{x}}?"
    /// filled with "why?" reads back as "why?" rather than as a failure. And two
    /// blanks with nothing between them are unreadable by construction, because
    /// nothing says where the first one ended; a shape like that simply never
    /// claims a question.
    static func recover(_ text: String, from pieces: [Piece]) -> [String: String]? {
        var values: [String: String] = [:]
        // A key used twice was substituted with the same value twice, so two
        // different readings mean this text did not come from this template.
        func note(_ key: String, _ value: String) -> Bool {
            if let existing = values[key] { return existing == value }
            values[key] = value
            return true
        }

        var rest = Substring(text)
        var index = 0
        while index < pieces.count {
            switch pieces[index] {
            case .literal(let literal):
                guard rest.hasPrefix(literal) else { return nil }
                rest = rest.dropFirst(literal.count)
                index += 1

            case .blank(let key):
                guard index + 1 < pieces.count else {
                    guard note(key, String(rest)) else { return nil }
                    rest = rest[rest.endIndex...]
                    index += 1
                    continue
                }
                guard case .literal(let next) = pieces[index + 1] else { return nil }
                let found: Range<Substring.Index>?
                if index + 2 == pieces.count {
                    guard rest.count >= next.count, rest.hasSuffix(next) else { return nil }
                    found = rest.index(rest.endIndex, offsetBy: -next.count)..<rest.endIndex
                } else {
                    found = rest.range(of: next)
                }
                guard let hit = found else { return nil }
                guard note(key, String(rest[rest.startIndex..<hit.lowerBound])) else { return nil }
                rest = rest[hit.upperBound...]
                index += 2
            }
        }
        return rest.isEmpty ? values : nil
    }

    /// Adjacent literals joined, so a pattern with a blank taken out of the
    /// middle reads as one run of text rather than two that happen to touch.
    static func merged(_ pieces: [Piece]) -> [Piece] {
        var out: [Piece] = []
        for piece in pieces {
            if case .literal(let text) = piece, case .literal(let previous)? = out.last {
                out[out.count - 1] = .literal(previous + text)
            } else {
                out.append(piece)
            }
        }
        return out
    }

    /// Whitespace at the two ends of a pattern, gone -- because it is gone from
    /// the card too. `tidy` trims what it renders, so a pattern that still
    /// insists on a trailing blank line could never match its own output.
    static func trimmedEnds(_ pieces: [Piece]) -> [Piece] {
        var out = pieces
        if case .literal(let text)? = out.first {
            let trimmed = String(text.drop(while: { $0.isWhitespace }))
            if trimmed.isEmpty { out.removeFirst() } else { out[0] = .literal(trimmed) }
        }
        if case .literal(let text)? = out.last {
            var trimmed = text
            while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
            if trimmed.isEmpty { out.removeLast() } else { out[out.count - 1] = .literal(trimmed) }
        }
        return out
    }

    /// The ways this pattern can legitimately have been filled in.
    ///
    /// Two: everything present, and the optional blanks left out along with the
    /// whitespace that was only there to separate them. "How does {{disease}}
    /// present?" with an optional details blank after it has to recognise both
    /// the card that has details and the one that does not, and those are two
    /// different shapes.
    static func readings(of text: String, dropping optional: Set<String>) -> [[Piece]] {
        let full = trimmedEnds(merged(pieces(text)))
        guard !optional.isEmpty else { return [full] }
        let reduced = trimmedEnds(merged(pieces(text).filter { piece in
            if case .blank(let key) = piece { return !optional.contains(key) }
            return true
        }))
        return reduced == full ? [full] : [full, reduced]
    }

    /// How much fixed text this shape pins down. A template that is mostly
    /// blanks describes almost every card ever written, so specificity is what
    /// decides which template claims a question when several could.
    ///
    /// The front only, because the front is what is matched: a template is
    /// recognised by the wording of its question, not by what its answer
    /// happens to say.
    var specificity: Int {
        Template.pieces(front)
            .compactMap { piece -> String? in
                if case .literal(let text) = piece { return text }
                return nil
            }
            .joined()
            .filter { !$0.isWhitespace }
            .count
    }

    /// A shape with next to no fixed text would swallow the whole Basic tab, so
    /// it is allowed to exist and simply never matches anything.
    var isMatchable: Bool { specificity >= 3 }

    /// Read a whole question back.
    ///
    /// The wording of the question decides, and nothing else. Whatever is in the
    /// answer, and whatever the card is tagged, are things you change freely
    /// after writing it -- if either could take a card out of its own tab, the
    /// tab would move about under you. So the front has to read back; the back
    /// is then read too, but only for the values it can hand over, and a back
    /// that does not fit costs nothing.
    /// Whether this shape can read a card.
    func matches(front questionFront: String, back questionBack: String) -> Bool {
        recover(front: questionFront, back: questionBack) != nil
    }

    /// Which optional questions a card's front is asking.
    ///
    /// By looking, because there is nowhere else to look. See `TemplateOption`.
    func selectedOptions(inFront questionFront: String) -> Set<String> {
        let text = Template.tidy(questionFront)
        return Set(options.filter { !$0.question.isEmpty && text.contains($0.question) }
            .map(\.key))
    }

    /// This shape's text with the ticked options folded in, which is what a
    /// card made from it actually reads.
    func composed(options on: Set<String>) -> (front: String, back: String) {
        var composedFront = front
        var composedBack = back
        for option in options where on.contains(option.key) {
            if !option.question.isEmpty {
                composedFront += composedFront.isEmpty ? option.question : " " + option.question
            }
            if !option.answer.isEmpty {
                composedBack += composedBack.isEmpty ? option.answer : "\n\n" + option.answer
            }
        }
        return (composedFront, composedBack)
    }

    /// Every blank in play for a given set of ticked options.
    func blanks(options on: Set<String>) -> [TemplateBlank] {
        var out = blanks
        for option in options where on.contains(option.key) {
            for blank in option.blanks where !out.contains(where: { $0.key == blank.key }) {
                out.append(blank)
            }
        }
        return out
    }

    func render(blanks values: [String: String]) -> (front: String, back: String) {
        render(blanks: values, options: Set(options.filter(\.defaultOn).map(\.key)))
    }

    func render(blanks values: [String: String],
                options on: Set<String>) -> (front: String, back: String) {
        let text = composed(options: on)
        return (Template.tidy(substitute(text.front, values)),
                Template.tidy(substitute(text.back, values)))
    }

    func recover(front questionFront: String, back questionBack: String) -> [String: String]? {
        guard isMatchable else { return nil }
        let on = selectedOptions(inFront: questionFront)
        let shape = composed(options: on)
        let optional = Set(blanks(options: on).filter(\.optional).map(\.key))
        let text = Template.tidy(questionFront)

        var found: [String: String]?
        for reading in Template.readings(of: shape.front, dropping: optional) {
            if let values = Template.recover(text, from: reading) {
                found = values
                break
            }
        }
        guard var values = found else { return nil }
        for key in optional where values[key] == nil { values[key] = "" }

        guard !shape.back.isEmpty else { return values }
        let answer = Template.tidy(questionBack)
        for reading in Template.readings(of: shape.back, dropping: optional) {
            guard let fromBack = Template.recover(answer, from: reading) else { continue }
            for (key, value) in fromBack where (values[key] ?? "").isEmpty {
                values[key] = value
            }
            break
        }
        return values
    }

    /// Which template a question's text belongs to, if any.
    ///
    /// The most specific shape wins, so "What artery supplies {{x}}?" beats a
    /// bare "{{x}}?" for a question about an artery. Ties break on id, which is
    /// arbitrary but stable -- the tab a card sits in must not depend on the
    /// order the templates happened to load in.
    static func bestMatch(front: String, back: String, kind: QuestionKind,
                          in templates: [Template]) -> Template? {
        var best: Template?
        // Enabled or not. A template you have switched off still recognises the
        // cards you made with it -- that is what gives them a tab to be read in.
        // What being off costs is the ability to make more.
        for template in templates where template.kind == kind && template.isMatchable {
            guard template.matches(front: front, back: back) else { continue }
            guard let current = best else {
                best = template
                continue
            }
            if template.specificity > current.specificity
                || (template.specificity == current.specificity && template.id < current.id) {
                best = template
            }
        }
        return best
    }
}

// MARK: - Store

/// Templates live outside any one library so they follow you between courses.
///
/// One file, not a folder of them. There are never many, they are edited
/// together in one window, and a folder meant a delete could half-succeed --
/// leaving a template on disk that the app had already stopped listing.
@MainActor
final class TemplateStore: ObservableObject {
    @Published private(set) var templates: [Template] = []

    /// The single file everything lives in.
    let fileURL: URL

    private struct Wrapper: Codable {
        var templates: [Template]
    }

    init(directory: URL? = nil) {
        let root: URL
        if let directory {
            root = directory
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support")
            root = support.appendingPathComponent(AnkiIdentity.appName, isDirectory: true)
        }
        self.fileURL = root.appendingPathComponent("Templates.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        adoptOldFolder(under: root)
        reload()
        // Write them down once, so the file is the whole truth and a built-in
        // you turn off stays off.
        if !FileManager.default.fileExists(atPath: fileURL.path) { write(templates) }
    }

    /// Earlier versions wrote one JSON per template into a `Templates` folder.
    /// Fold them into the single file once, then take the folder out of the way
    /// so a template deleted afterwards does not come back on the next launch.
    private func adoptOldFolder(under root: URL) {
        let folder = root.appendingPathComponent("Templates", isDirectory: true)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        let decoder = JSONDecoder()
        var found: [Template] = (try? Data(contentsOf: fileURL))
            .flatMap { try? decoder.decode(Wrapper.self, from: $0) }?.templates ?? []
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let template = try? decoder.decode(Template.self, from: data),
                  !found.contains(where: { $0.id == template.id }) else { continue }
            found.append(template)
        }
        guard !found.isEmpty, write(found) else { return }

        // Renamed rather than deleted: this is the only copy of work someone may
        // have spent an evening on, and keeping it costs one folder.
        let retired = root.appendingPathComponent("Templates (migrated)", isDirectory: true)
        if fm.fileExists(atPath: retired.path) { try? fm.removeItem(at: retired) }
        try? fm.moveItem(at: folder, to: retired)
    }

    func template(id: String?) -> Template? {
        guard let id else { return nil }
        return templates.first { $0.id == id }
    }

    /// The shapes the app ships with.
    ///
    /// Clinical correlations, because that is the one kind of card whose wording
    /// really is the same every time -- the vignette is on the slide and the
    /// question above it never changes. Fixed ids, so editing one is editing
    /// *that* one rather than making a second copy of it.
    ///
    /// The trailing optional blank is how "and anything else you want to ask"
    /// works without leaving a blank line on cards that do not use it.
    static let builtIns: [Template] = [
        Template(
            id: Template.builtInPrefix + "cc-disease",
            name: "CC — disease",
            front: "What disease is this patient presenting with?",
            back: "{{disease}}",
            blanks: [TemplateBlank(key: "disease", label: "Disease"),
                     TemplateBlank(key: "details", label: "More details",
                                   multiline: true, optional: true)],
            slides: .front,
            tags: ["clinical-correlation"],
            options: TemplateStore.clinicalOptions
        ),
        Template(
            id: Template.builtInPrefix + "cc-presentation",
            name: "CC — presentation",
            front: "How does {{disease}} present?\n\n{{details}}",
            blanks: [TemplateBlank(key: "disease", label: "Disease"),
                     TemplateBlank(key: "details", label: "More details",
                                   multiline: true, optional: true)],
            slides: .back,
            tags: ["clinical-correlation"],
            options: TemplateStore.clinicalOptions
        )
    ]

    /// The two questions both clinical shapes can also ask.
    ///
    /// Fixed phrases, because the checkbox has nowhere but the card's own words
    /// to keep its state -- see `TemplateOption`. Editing them here changes
    /// what the boxes write and look for; editing a card's front afterwards is
    /// yours to do, and simply leaves the box unticked.
    static let clinicalOptions: [TemplateOption] = [
        TemplateOption(key: "cause", label: "What causes it?",
                       question: "What causes it?",
                       answer: "{{cause}}",
                       blanks: [TemplateBlank(key: "cause", label: "Cause",
                                              multiline: true)]),
        TemplateOption(key: "treat", label: "How do you treat it?",
                       question: "How do you treat it?",
                       answer: "Tx: {{tx}}\nRx: {{rx}}",
                       blanks: [TemplateBlank(key: "tx", label: "Tx", multiline: true),
                                TemplateBlank(key: "rx", label: "Rx", multiline: true)])
    ]

    func reload() {
        let stored = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(Wrapper.self, from: $0) }?.templates ?? []
        // Built-ins are always present. A stored copy wins -- that is your
        // edited version, or the one you turned off -- and anything the file has
        // never heard of is added back, which is also what makes them
        // undeletable without a rule saying so anywhere else.
        var list = stored
        for builtIn in Self.builtIns where !list.contains(where: { $0.id == builtIn.id }) {
            list.append(builtIn)
        }
        templates = list
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The tabs: enabled templates only. Turning one off leaves it in the list
    /// in Settings and takes it out of everywhere else.
    var active: [Template] { templates.filter(\.enabled) }

    func setEnabled(_ enabled: Bool, for template: Template) {
        var copy = template
        copy.enabled = enabled
        save(copy)
    }

    @discardableResult
    private func write(_ list: [Template]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Wrapper(templates: list)) else { return false }
        do {
            try AtomicWrite.write(data, to: fileURL)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func save(_ template: Template) -> Bool {
        var list = templates
        if let index = list.firstIndex(where: { $0.id == template.id }) {
            list[index] = template
        } else {
            list.append(template)
        }
        guard write(list) else { return false }
        reload()
        return true
    }

    /// Built-ins are turned off, not deleted -- `reload` would put one back on
    /// the next launch anyway, and a delete that quietly undoes itself is worse
    /// than one that says no.
    @discardableResult
    func delete(_ template: Template) -> Bool {
        guard !template.isBuiltIn else { return false }
        write(templates.filter { $0.id != template.id })
        reload()
        return true
    }
}
