import Foundation

/// Which slide images end up on each side of one produced card.
///
/// Shared by the exporter and the preview, deliberately. A preview that works
/// out the layout for itself is a preview that can disagree with the deck — and
/// the whole point of looking at a card before exporting it is that what you see
/// is what Anki will show.
enum CardComposition {
    struct ImageSpec: Hashable {
        let page: Int
        let crop: CropRect?
        let masks: PageRenderer.MaskPaint?
    }

    /// `mask` is the region a separate-mode occlusion card is asking about, and
    /// nil for everything else.
    static func images(for question: Question, mask: Mask?) -> (front: [ImageSpec], back: [ImageSpec]) {
        if question.kind == .occlusion, let page = question.occlusionPage {
            let crop = question.answerCrops[page] ?? question.questionCrops[page]
            // Front: everything hidden, with the region this card asks about in
            // the accent colour. Back: everything visible, that region boxed.
            let front = PageRenderer.MaskPaint(
                hidden: question.masks.filter { $0.id != mask?.id }.map(\.rect),
                target: mask?.rect,
                outlined: nil
            )
            let back = PageRenderer.MaskPaint(hidden: [], target: nil, outlined: mask?.rect)
            return (
                [ImageSpec(page: page, crop: crop, masks: front)],
                [ImageSpec(page: page, crop: crop, masks: back)]
            )
        }

        return (
            question.questionPages.map {
                ImageSpec(page: $0, crop: question.questionCrops[$0], masks: nil)
            },
            question.answerPages.map {
                ImageSpec(page: $0, crop: question.answerCrops[$0], masks: nil)
            }
        )
    }
}
