import SwiftUI

/// Hosts the template editor in its own window.
///
/// It used to be a sheet, which meant opening it from Settings put it *behind*
/// the Settings window — a sheet attaches to the main window, and Settings is a
/// separate one. A window comes to the front where you can see it.
struct TemplateEditorWindow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TemplateEditor(template: state.editingTemplate ?? Template(name: "New Template"))
            .environmentObject(state)
            // Re-seed the editor's local state when a different template is
            // chosen while the window is already open.
            .id(state.editingTemplate?.id ?? "new-template")
            .frame(minWidth: 720, minHeight: 560)
    }
}
