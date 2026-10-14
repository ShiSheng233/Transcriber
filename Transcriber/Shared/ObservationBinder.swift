import Observation

/// Re-runs `render` whenever an observable property it read changes, so a
/// view controller can draw from its view model without manual notifications.
final class ObservationBinder {
    private let render: () -> Void
    private var isActive = true

    init(render: @escaping () -> Void) {
        self.render = render
        observe()
    }

    func invalidate() {
        isActive = false
    }

    private func observe() {
        guard isActive else {
            return
        }
        withObservationTracking(render) { [weak self] in
            // onChange runs before the new value is stored; render on the next turn.
            Task { @MainActor in self?.observe() }
        }
    }
}
