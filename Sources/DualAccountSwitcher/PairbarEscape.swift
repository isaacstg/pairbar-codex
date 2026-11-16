import AppKit

/// The AppKit key event monitor is the sole Escape dispatcher for the real popover.
enum PairbarEscapeDisposition: Equatable {
    case closeActions
    case closePopover
    case passThrough

    static func decide(popoverShown: Bool, popoverReceivesEvent: Bool,
                       actionsOpen: Bool, modalActive: Bool) -> Self {
        guard popoverShown, popoverReceivesEvent, !modalActive else { return .passThrough }
        return actionsOpen ? .closeActions : .closePopover
    }
}

@MainActor
enum PairbarEscapeHandler {
    @discardableResult
    static func handle(_ disposition: PairbarEscapeDisposition, model: PairbarPanelModel,
                       closePopover: () -> Void) -> Bool {
        switch disposition {
        case .closeActions:
            model.closeActions()
            return true
        case .closePopover:
            closePopover()
            return true
        case .passThrough:
            return false
        }
    }
}
