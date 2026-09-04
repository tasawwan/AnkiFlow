import Foundation
import AppKit
import PDFKit

/// The state of an editing session on one lecture PDF: what has been changed,
/// what can be undone, and whether any of it has reached the disk yet.
///
/// The design decision this file exists to enforce: **edits are made to the
/// in-memory document and only written when you say so.** PDFKit annotations
/// live on the `PDFDocument` object, and the `PDFView` draws that object, so a
/// mark appears the instant it is added — but the file on disk is untouched
/// until `save`. That is what makes undo trustworthy: undoing an edit puts the
/// document back the way it was, and nothing has to be un-written.
///
/// Undo is a pair of stacks of closures rather than an `UndoManager`. AppKit's
/// undo manager is shared with every text field in the window, and the app's ⌘U
/// already means "undo the last thing I did to my questions"; a private stack
/// keeps the two from stealing each other's keystrokes.
@MainActor
final class PDFEditSession: ObservableObject {
    /// One reversible edit, with the label the menu shows.
    private struct Step {
        let label: String
        let undo: () -> Void
        let redo: () -> Void
    }

    let document: PDFDocument
    let url: URL

    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var undoLabel: String?
    @Published private(set) var redoLabel: String?
    /// The annotation currently selected, if any, and the page it sits on.
    @Published var selection: Selection?

    struct Selection: Equatable {
        let annotation: PDFAnnotation
        let page: PDFPage

        static func == (a: Selection, b: Selection) -> Bool {
            a.annotation === b.annotation && a.page === b.page
        }
    }

    private var undoStack: [Step] = []
    private var redoStack: [Step] = []

    /// Every page's crop box as it was when editing began.
    ///
    /// Trimming is a pending edit like any other, so the app has to be able to
    /// say at save time which pages moved and where they moved from. Deriving
    /// that by comparing against this snapshot means undo only has to put the
    /// box back -- the list of what changed recomputes itself, with no map to
    /// keep in step with the stacks.
    private let originalBoxes: [Int: CGRect]

    init(document: PDFDocument, url: URL) {
        self.document = document
        self.url = url
        var boxes: [Int: CGRect] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            boxes[index + 1] = page.bounds(for: .cropBox)
        }
        self.originalBoxes = boxes
    }

    /// The pages whose box has moved since editing began, for the save to
    /// convert crops and masks against.
    func boxChanges() -> [Int: (old: CGRect, new: CGRect)] {
        var changed: [Int: (old: CGRect, new: CGRect)] = [:]
        for (number, old) in originalBoxes {
            guard let page = document.page(at: number - 1) else { continue }
            let now = page.bounds(for: .cropBox)
            if now != old { changed[number] = (old: old, new: now) }
        }
        return changed
    }

    /// Trim a page, undoably and without touching the file.
    func trim(_ page: PDFPage, to rect: CGRect, label: String) {
        let old = page.bounds(for: .cropBox)
        guard rect != old, rect.width > 1, rect.height > 1 else { return }
        perform(label,
                undo: { page.setBounds(old, for: .cropBox) },
                redo: { page.setBounds(rect, for: .cropBox) })
    }

    // MARK: - Recording

    /// Run an edit and remember how to take it back.
    ///
    /// `perform` is called immediately and again on redo, so it must be
    /// idempotent in the sense of "doing it twice from the same starting state
    /// gives the same result" -- which is true of add, remove, move and set.
    func perform(_ label: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        redo()
        record(label, undo: undo, redo: redo)
    }

    /// Remember an edit that has *already* happened.
    ///
    /// Dragging a mark across the page applies itself as you drag, so replaying
    /// it on the way in would be wrong -- but redo still has to know how to put
    /// it back, which is why this takes both closures and calls neither.
    func record(_ label: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        undoStack.append(Step(label: label, undo: undo, redo: redo))
        redoStack.removeAll()
        dirty = true
        markChanged()
    }

    /// Take back the last step and forget it entirely -- no redo.
    ///
    /// For the one case where an edit is abandoned rather than undone: a text
    /// box you drew and then typed nothing into. Leaving it on the redo stack
    /// would let ⇧⌘U resurrect an empty, invisible annotation.
    func discardLastStep() {
        guard let step = undoStack.popLast() else { return }
        step.undo()
        // An abandoned edit is not an unsaved edit. Without this, drawing a text
        // box and typing nothing into it left Save lit and Done asking to
        // discard marks that no longer existed.
        if undoStack.isEmpty && redoStack.isEmpty { dirty = false }
        markChanged()
    }

    func undo() {
        guard let step = undoStack.popLast() else { return }
        step.undo()
        redoStack.append(step)
        dirty = true
        markChanged()
    }

    func redo() {
        guard let step = redoStack.popLast() else { return }
        step.redo()
        undoStack.append(step)
        dirty = true
        markChanged()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func markChanged() {
        undoLabel = undoStack.last?.label
        redoLabel = redoStack.last?.label
        hasUnsavedChanges = dirty
    }

    /// Set by anything that touches the document, cleared by a save. Undoing
    /// back to exactly the saved state still counts as dirty -- over-reporting
    /// leaves the Save button lit when nothing needs saving, which is the
    /// harmless direction to be wrong in.
    private var dirty = false

    // MARK: - The edits themselves

    func add(_ annotation: PDFAnnotation, to page: PDFPage, label: String) {
        perform(label,
                undo: { [weak self] in
                    annotation.shouldDisplay = false
                    page.removeAnnotation(annotation)
                    if self?.selection?.annotation === annotation { self?.selection = nil }
                },
                redo: {
                    annotation.shouldDisplay = true
                    page.addAnnotation(annotation)
                })
        selection = Selection(annotation: annotation, page: page)
    }

    func remove(_ annotation: PDFAnnotation, from page: PDFPage) {
        if selection?.annotation === annotation { selection = nil }
        perform("deleting that mark",
                undo: {
                    annotation.shouldDisplay = true
                    page.addAnnotation(annotation)
                },
                redo: {
                    annotation.shouldDisplay = false
                    page.removeAnnotation(annotation)
                })
    }

    /// Moving and resizing are the same edit: the bounds changed.
    func setBounds(_ new: CGRect, on annotation: PDFAnnotation, label: String) {
        let old = annotation.bounds
        guard old != new else { return }
        perform(label,
                undo: { annotation.bounds = old },
                redo: { annotation.bounds = new })
    }

    /// `mergeWithLast` folds the change into the step already on top of the
    /// stack, so drawing a text box and typing into it is one ⌘U rather than
    /// two -- from where you sit it was one action.
    func setContents(_ new: String, on annotation: PDFAnnotation, mergeWithLast: Bool = false) {
        let old = annotation.contents ?? ""
        guard old != new else { return }
        if mergeWithLast, let previous = undoStack.popLast() {
            annotation.contents = new
            record(previous.label,
                   undo: { annotation.contents = old; previous.undo() },
                   redo: { previous.redo(); annotation.contents = new })
            return
        }

        perform("that text",
                undo: { annotation.contents = old },
                redo: { annotation.contents = new })
    }

    func setAttributedString(_ new: NSAttributedString, on annotation: PDFAnnotation,
                             mergeWithLast: Bool = false) {
        let old = annotation.contents ?? ""
        let oldRichText = PDFEditing.richText(for: annotation)
        let fullRange = NSRange(location: 0, length: new.length)
        let font = new.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let color = new.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let uniformFont = font.map { candidate in
            var uniform = true
            new.enumerateAttribute(.font, in: fullRange) { value, _, stop in
                if (value as? NSFont) != candidate { uniform = false; stop.pointee = true }
            }
            return uniform ? candidate : nil
        } ?? nil
        let uniformColor = color.map { candidate in
            var uniform = true
            new.enumerateAttribute(.foregroundColor, in: fullRange) { value, _, stop in
                if (value as? NSColor) != candidate { uniform = false; stop.pointee = true }
            }
            return uniform ? candidate : nil
        } ?? nil
        perform("that text",
                undo: {
                    annotation.contents = old
                    if let oldRichText { PDFEditing.setRichText(oldRichText, on: annotation) }
                },
                redo: {
                    annotation.contents = new.string
                    if let uniformFont { annotation.font = uniformFont }
                    if let uniformColor { annotation.fontColor = uniformColor }
                    PDFEditing.setRichText(new, on: annotation)
                })
    }

    func setColour(_ new: NSColor, on annotation: PDFAnnotation) {
        let isText = PDFEditing.kind(of: annotation) == "FreeText"
        let old = isText ? annotation.fontColor : annotation.color
        let oldRichText = isText ? PDFEditing.richText(for: annotation) : nil
        perform("that color",
                undo: {
                    if isText {
                        annotation.fontColor = old
                        if let oldRichText { PDFEditing.setRichText(oldRichText, on: annotation) }
                    } else {
                        annotation.color = old ?? .clear
                    }
                },
                redo: {
                    if isText {
                        annotation.fontColor = new
                        if let richText = PDFEditing.richText(for: annotation) {
                            let updated = NSMutableAttributedString(attributedString: richText)
                            updated.addAttribute(.foregroundColor, value: new,
                                                 range: NSRange(location: 0, length: updated.length))
                            PDFEditing.setRichText(updated, on: annotation)
                        }
                    } else {
                        annotation.color = new
                    }
                })
    }

    func setFill(_ new: NSColor?, on annotation: PDFAnnotation) {
        let old = annotation.interiorColor
        perform("that fill",
                undo: { annotation.interiorColor = old },
                redo: { annotation.interiorColor = new })
    }

    func setLineWidth(_ new: CGFloat, on annotation: PDFAnnotation) {
        let old = annotation.border?.lineWidth ?? 0
        let border = annotation.border ?? PDFBorder()
        perform("that thickness",
                undo: {
                    border.lineWidth = old
                    annotation.border = border
                },
                redo: {
                    border.lineWidth = new
                    annotation.border = border
                })
    }

    func setFont(_ new: NSFont, on annotation: PDFAnnotation) {
        let old = annotation.font
        perform("that text style",
                undo: {
                    annotation.font = old
                },
                redo: {
                    annotation.font = new
                })
    }

    func setFontSize(_ newSize: CGFloat, on annotation: PDFAnnotation) {
        let oldFont = annotation.font
        let oldRichText = PDFEditing.richText(for: annotation)
        let updatedRichText = oldRichText.map { text -> NSAttributedString in
            let updated = NSMutableAttributedString(attributedString: text)
            updated.enumerateAttribute(.font, in: NSRange(location: 0, length: updated.length)) {
                value, range, _ in
                guard let font = value as? NSFont else { return }
                let resized = NSFont(descriptor: font.fontDescriptor, size: newSize)
                    ?? NSFont.systemFont(ofSize: newSize)
                updated.addAttribute(.font, value: resized, range: range)
            }
            return updated
        }
        let newFont = annotation.font.map {
            NSFont(descriptor: $0.fontDescriptor, size: newSize)
        } ?? NSFont.systemFont(ofSize: newSize)
        perform("that text size",
                undo: {
                    annotation.font = oldFont
                    if let oldRichText { PDFEditing.setRichText(oldRichText, on: annotation) }
                },
                redo: {
                    annotation.font = newFont
                    if let updatedRichText { PDFEditing.setRichText(updatedRichText, on: annotation) }
                })
    }

    // MARK: - Saving

    func markSaved() {
        dirty = false
        markChanged()
    }

    /// Throw the session away and put the document back the way it was on disk.
    /// Used when you leave editing without saving.
    func revertAll() {
        while !undoStack.isEmpty { undo() }
        selection = nil
        redoStack.removeAll()
        dirty = false
        markChanged()
    }
}
