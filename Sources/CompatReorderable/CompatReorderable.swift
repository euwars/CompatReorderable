//
//  CompatReorderable.swift
//  CompatReorderable
//
//  Drag-to-reorder for any SwiftUI container, mirroring the native API
//  introduced in the 2027 OS releases — iOS 27, iPadOS 27, macOS 27,
//  watchOS 27, and visionOS 27 (`reorderable()` /
//  `reorderContainer(for:move:)` / `ReorderDifference`) — on earlier OS
//  versions. When your deployment targets reach the 27 releases, delete
//  this dependency and drop the `compat` prefixes at the call sites.
//

import SwiftUI

/// Mirror of the native `ReorderDifference` (iOS 27, macOS 27, watchOS 27,
/// visionOS 27): describes one move as the items being moved plus the
/// destination they land at.
public struct CompatReorderDifference<ItemID: Hashable> {
    /// The identifiers of the items being moved, in order.
    public var sources: [ItemID]

    /// Where the moved items land.
    public var destination: Destination

    public init(sources: [ItemID], destination: Destination) {
        self.sources = sources
        self.destination = destination
    }

    public struct Destination {
        public enum Position {
            /// Insert the sources before this item.
            case before(ItemID)
            /// Append the sources to the end.
            case end
        }

        public var position: Position

        public init(position: Position) {
            self.position = position
        }
    }
}

extension CompatReorderDifference {
    /// Applies the move to an array, mirroring the `ReorderDifference.apply`
    /// pattern used with the native API:
    ///
    ///     .compatReorderContainer(for: Item.self) { difference in
    ///         difference.apply(to: &items)
    ///     }
    public func apply<Item>(to items: inout [Item]) where Item: Identifiable, Item.ID == ItemID {
        // Moving an item "before itself" is a no-op, not a move-to-end.
        if let beforeID, sources.contains(beforeID) { return }
        CompatReorderEngine.move(items: &items, sourceIDs: sources, before: beforeID)
    }

    private var beforeID: ItemID? {
        switch destination.position {
        case .before(let destinationID):
            destinationID
        case .end:
            nil
        }
    }
}

extension ForEach where Content: View, Data.Element: Identifiable, ID == Data.Element.ID {
    /// The compat counterpart of the native `reorderable()` (iOS 27,
    /// macOS 27, watchOS 27, visionOS 27): enables the views of this content
    /// to be reordered when used within the scope of a
    /// ``SwiftUICore/View/compatReorderContainer(for:isEnabled:move:)``
    /// modifier.
    ///
    /// Works in any vertical container — `LazyVStack`, `LazyVGrid`, plain
    /// stacks, or custom `Layout`s:
    ///
    ///     ScrollView {
    ///         LazyVGrid(columns: columns) {
    ///             ForEach(items) { item in
    ///                 ItemView(item)
    ///             }
    ///             .compatReorderable()
    ///         }
    ///         .compatReorderContainer(for: Item.self) { difference in
    ///             difference.apply(to: &items)
    ///         }
    ///     }
    public func compatReorderable() -> some View {
        CompatReorderableForEach(data, content: content)
    }
}

/// The animations a reorder container uses, overridable via
/// ``SwiftUICore/View/compatReorderAnimations(_:)``. Defaults are tuned per
/// platform: the system-drag backend (iOS/visionOS) animates its own lift,
/// glide, and drop, so only `gapReflow` applies there; `lift` and `settle`
/// drive the self-rendered fallback backend (watchOS/macOS), which defaults
/// to slightly slower, calmer curves.
public struct CompatReorderAnimations: Sendable {
    /// Cells reflowing around the gap as the drag retargets.
    public var gapReflow: Animation

    /// The cell lifting at drag start (watchOS/macOS backend only).
    public var lift: Animation

    /// The dragged item gliding into its slot on release (watchOS/macOS
    /// backend only).
    public var settle: Animation

    public init() {
        #if os(watchOS) || os(macOS)
        gapReflow = .spring(response: 0.5, dampingFraction: 0.8)
        #else
        gapReflow = .spring(response: 0.35, dampingFraction: 0.8)
        #endif
        lift = .snappy(duration: 0.3)
        settle = .spring(response: 0.5, dampingFraction: 0.85)
    }
}

extension View {
    /// Overrides the animations used by compat reorder containers in this
    /// hierarchy. See ``CompatReorderAnimations`` for what each one drives.
    public func compatReorderAnimations(_ animations: CompatReorderAnimations) -> some View {
        environment(\.compatReorderAnimations, animations)
    }

    /// The corner radius of the system hover shadow under lifted items
    /// (iOS/visionOS). Defaults to 12; match it to your cells' shape — with
    /// a blurred shadow, a close value is indistinguishable.
    public func compatReorderPreviewCornerRadius(_ radius: CGFloat) -> some View {
        environment(\.compatReorderPreviewCornerRadius, radius)
    }

    /// The compat counterpart of the native
    /// `reorderContainer(for:isEnabled:move:)` (iOS 27, macOS 27,
    /// watchOS 27, visionOS 27). Apply to the container that holds a
    /// ``SwiftUICore/ForEach/compatReorderable()``.
    ///
    /// Behavior on iOS/iPadOS/Catalyst/visionOS, mirroring the native
    /// implementation:
    /// - Built on the system drag-and-drop interactions, so lift, drag,
    ///   cancel, and drop animations are the system's own, a second finger
    ///   can scroll during a drag, and reorders never leave the app.
    /// - Your data is never mutated during the drag; a same-size gap follows
    ///   the finger and `move` fires once, on drop.
    /// - Context menus coexist the way Apple's apps behave: holding still
    ///   presents the menu; dragging — including out of a presented menu —
    ///   dismisses it and starts the reorder.
    /// - Dragging near the scroll view's top/bottom edge auto-scrolls.
    ///
    /// On watchOS and macOS a SwiftUI gesture backend drives the same model
    /// with self-rendered previews — no system lift, menu integration, or
    /// edge auto-scroll there. One reorder container per scroll view; two
    /// containers sharing one scroll view is unsupported.
    ///
    /// - Parameters:
    ///   - item: The element type of the reorderable collection.
    ///   - isEnabled: Whether reordering is active. Defaults to `true`.
    ///   - move: Called once per completed drag with the proposed move;
    ///     apply it to your data (see ``CompatReorderDifference/apply(to:)``).
    public func compatReorderContainer<Item: Identifiable>(
        for item: Item.Type,
        isEnabled: Bool = true,
        move: @escaping (_ difference: CompatReorderDifference<Item.ID>) -> Void
    ) -> some View {
        modifier(CompatReorderContainerModifier<Item>(isEnabled: isEnabled, move: move))
    }
}

/// Implementation behind `compatReorderable()`: renders the items in their
/// proposed order during a drag, hides the lifted item's cell (the gap), and
/// reports cell frames to the enclosing container.
struct CompatReorderableForEach<Data: RandomAccessCollection, Content: View>: View
    where Data.Element: Identifiable {
    @Environment(\.compatReorderCoordinator) private var anyCoordinator

    private let data: Data
    private let content: (Data.Element) -> Content

    init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    // Concrete-ID coordinator: keeps frame tracking, retarget scans, and
    // order diffing free of AnyHashable boxing — it matters at hundreds of
    // items.
    private var coordinator: CompatReorderCoordinator<Data.Element.ID>? {
        anyCoordinator as? CompatReorderCoordinator<Data.Element.ID>
    }

    var body: some View {
        let coordinator = coordinator
        ForEach(displayData(coordinator)) { element in
            cell(for: element, coordinator: coordinator)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(CompatReorder.coordinateSpaceName))
                } action: { frame in
                    coordinator?.frames[element.id] = frame
                }
        }
    }

    @ViewBuilder
    private func cell(
        for element: Data.Element,
        coordinator: CompatReorderCoordinator<Data.Element.ID>?
    ) -> some View {
        #if os(watchOS) || os(macOS)
        // No drag interactions on these platforms: the cell itself is the
        // floating preview, driven by a SwiftUI gesture.
        content(element)
            .modifier(CompatReorderFallbackCellModifier(coordinator: coordinator, itemID: element.id))
        #else
        // The system drag preview represents the dragged item; its hidden
        // cell is the gap.
        content(element)
            .opacity(coordinator?.draggedID == element.id ? 0 : 1)
        #endif
    }

    private func displayData(
        _ coordinator: CompatReorderCoordinator<Data.Element.ID>?
    ) -> [Data.Element] {
        guard let coordinator else { return Array(data) }

        // Registration side channel; this is unobserved on the coordinator,
        // so writing it here cannot invalidate the view. Skip the store when
        // unchanged to avoid churn on unrelated re-renders.
        let ids = data.map(\.id)
        if coordinator.sourceIDs != ids {
            coordinator.sourceIDs = ids
            // Prune frames of deleted items: ghost frames would otherwise
            // cover regions the survivors reflowed into, intermittently
            // hijacking retargets and lifting nonexistent items.
            let valid = Set(ids)
            if coordinator.frames.count != valid.count {
                coordinator.frames = coordinator.frames.filter { valid.contains($0.key) }
            }
        }

        // Used by the fallback backends for the dragged overlay, and by the
        // iOS drop animation as a live (never stale) copy of the cell.
        coordinator.previewContentProvider = { id in
            data.first { $0.id == id }.map { AnyView(content($0)) }
        }

        guard let order = coordinator.displayIDs else { return Array(data) }
        // uniquingKeysWith: duplicate IDs are a caller bug, but degrade to a
        // ForEach warning instead of trapping mid-drag.
        let lookup = Dictionary(data.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var display = order.compactMap { lookup[$0] }
        // Items inserted mid-drag aren't in the pinned order; show them at
        // the end rather than blinking them out for the drag's duration.
        if display.count != data.count {
            let pinned = Set(order)
            display.append(contentsOf: data.filter { !pinned.contains($0.id) })
        }
        return display
    }
}

struct CompatReorderContainerModifier<Item: Identifiable>: ViewModifier {
    let isEnabled: Bool
    let move: (CompatReorderDifference<Item.ID>) -> Void

    @Environment(\.compatReorderAnimations) private var animations
    @Environment(\.compatReorderPreviewCornerRadius) private var previewCornerRadius
    @State private var coordinator = CompatReorderCoordinator<Item.ID>()

    func body(content: Content) -> some View {
        // Refreshed every render (unobserved, so non-invalidating): a stale
        // `move` captured once in onAppear would commit against whatever its
        // captures held at first appearance.
        coordinator.isReorderEnabled = isEnabled
        coordinator.animations = animations
        coordinator.previewCornerRadius = previewCornerRadius
        coordinator.commitMove = { [move] sources, before in
            move(
                CompatReorderDifference(
                    sources: sources,
                    destination: .init(position: before.map { .before($0) } ?? .end)
                )
            )
        }

        return content
            .environment(\.compatReorderCoordinator, coordinator)
            .coordinateSpace(name: CompatReorder.coordinateSpaceName)
        #if os(iOS) || os(visionOS)
            .background {
                CompatReorderGestureHost(isEnabled: isEnabled, coordinator: coordinator)
            }
        #endif
        #if os(watchOS) || os(macOS)
            .overlay(alignment: .topLeading) {
                CompatReorderFallbackPreviewHost(coordinator: coordinator)
            }
        #endif
        #if !os(macOS)
            .sensoryFeedback(.impact(weight: .light), trigger: coordinator.moveCount)
            .sensoryFeedback(trigger: coordinator.draggedID) { _, lifted in
                lifted != nil ? .impact(weight: .medium) : .impact(weight: .light)
            }
        #endif
    }
}

/// Shared move algorithm used by `CompatReorderDifference.apply(to:)`.
enum CompatReorderEngine {
    static func move<Item: Identifiable>(
        items: inout [Item],
        sourceIDs: [Item.ID],
        before destinationID: Item.ID?
    ) {
        let uniqueSourceIDs = sourceIDs.reduce(into: [Item.ID]()) { result, id in
            if !result.contains(id) {
                result.append(id)
            }
        }
        let movedItems = uniqueSourceIDs.compactMap { id in
            items.first { $0.id == id }
        }

        guard !movedItems.isEmpty else { return }

        var reorderedItems = items.filter { item in
            !uniqueSourceIDs.contains(item.id)
        }

        if let destinationID,
           let destinationIndex = reorderedItems.firstIndex(where: { $0.id == destinationID }) {
            reorderedItems.insert(contentsOf: movedItems, at: destinationIndex)
        } else {
            reorderedItems.append(contentsOf: movedItems)
        }

        guard reorderedItems.map(\.id) != items.map(\.id) else { return }

        items = reorderedItems
    }
}
