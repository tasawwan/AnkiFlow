import SwiftUI

/// The palette comes out of the icon, so the app and its icon read as one object.
///
/// The rule worth enforcing: **amber means attachment and nothing else.** In the
/// icon the amber block is an attached slide; in the app it is a chip for an
/// attached page, the armed row's outline, the current-page marker, and the
/// ghost page that `E` would take. Never a button, never a warning.
enum Theme {
    static let navy      = Color(red: 0.118, green: 0.165, blue: 0.275)  // #1E2A46
    static let paper     = Color(red: 0.957, green: 0.949, blue: 0.925)  // #F4F2EC
    static let amber     = Color(red: 0.878, green: 0.627, blue: 0.227)  // #E0A03A
    static let slate     = Color(red: 0.725, green: 0.749, blue: 0.800)  // #B9BFCC

    /// Export outcomes are semantic, and deliberately not the accent.
    static let added     = Color(red: 0.243, green: 0.612, blue: 0.427)
    static let changed   = Color(red: 0.294, green: 0.478, blue: 0.749)
    static let retired   = Color(red: 0.710, green: 0.329, blue: 0.369)
}
