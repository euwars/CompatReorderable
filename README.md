# CompatReorderable

Drag-to-reorder for **any SwiftUI container** — `LazyVStack`, `LazyVGrid`, plain stacks, custom `Layout`s — on **iOS 17+**, mirroring the `reorderable()` / `reorderContainer(for:move:)` API that ships natively in the 2027 OS releases (iOS 27, iPadOS 27, macOS 27, watchOS 27, visionOS 27). When your deployment targets reach the 27 releases, you delete this dependency and drop the `compat` prefixes.

<p align="center">
  <img src="https://github.com/euwars/CompatReorderable/releases/download/1.0.2/compat-demo.gif" width="560" alt="Drag-to-reorder demo across waterfall, grid, and list containers">
</p>

```swift
import CompatReorderable

struct StickerGrid: View {
    @State private var stickers: [Sticker] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns) {
                ForEach(stickers) { sticker in
                    StickerView(sticker)
                }
                .compatReorderable()                              // ≈ .reorderable()
            }
            .compatReorderContainer(for: Sticker.self) { difference in
                difference.apply(to: &stickers)                   // ≈ reorderContainer(for:move:)
            }
        }
    }
}
```

## Why

The 2027 OS releases finally bring drag-to-reorder to every container — but only there. The usual fallbacks (`onDrag`/`onDrop` with a `DropDelegate`) suffer from oscillating items, the green "+" badge, blocked scrolling, and wrong cancel animations. CompatReorderable instead reproduces how the native implementation actually works:

- **Built on the system drag-and-drop interactions** (`UIDragInteraction`/`UIDropInteraction`) — the same machinery the native `reorderable()` uses internally. Lift, drag, cancel, and drop animations are the system's own. Reorders never leave the app.
- **Your data is never mutated during the drag.** A same-size gap follows the finger and the `move` closure fires once, on drop — the exact contract of the native API. Oscillation is structurally impossible.
- **Context menus coexist** the way Apple's own apps behave: holding still presents the menu; dragging — including dragging out of a presented menu — dismisses it and starts the reorder. (As of the iOS 27.0 beta, the *native* API crashes when an item has a `.contextMenu`; the compat implementation supports it.)
- **Scrolling stays natural**: plain flicks scroll, a second finger can scroll while an item is lifted, and dragging near the container's top/bottom edge auto-scrolls.
- **Scales**: the internals are generic over your item's `ID` (no `AnyHashable` boxing on hot paths) and validated with 500-item containers.

## Requirements

| | |
|---|---|
| iOS / iPadOS / Mac Catalyst | 17.0+ (system drag backend) |
| visionOS | 1.0+ (system drag backend, compiled but lightly tested) |
| watchOS | 10.0+ (SwiftUI gesture backend, see below) |
| macOS | 14.0+ (SwiftUI gesture backend, see below) |
| Xcode | 16+ |

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/<you>/CompatReorderable.git", from: "1.0.0")
]
```

## API mapping

The native column is available on iOS 27, iPadOS 27, macOS 27, watchOS 27, and visionOS 27.

| Native (OS 27) | CompatReorderable |
|---|---|
| `ForEach { }.reorderable()` | `ForEach { }.compatReorderable()` |
| `.reorderContainer(for: Item.self) { difference in }` | `.compatReorderContainer(for: Item.self) { difference in }` |
| `reorderContainer(for:isEnabled:move:)` | `compatReorderContainer(for:isEnabled:move:)` |
| `ReorderDifference` (`sources`, `destination.position` = `.before(id)` / `.end`) | `CompatReorderDifference` (same shape) |
| `difference.apply(to: &items)` | `difference.apply(to: &items)` |

## Using both APIs side by side

If your app also runs on the 27 releases, branch on availability and share one `move` body. Add this parity extension in your app (it can't ship in the package — it references the OS 27 SDKs):

```swift
@available(iOS 27.0, macOS 27.0, watchOS 27.0, visionOS 27.0, *)
extension ReorderDifference where CollectionID == ReorderableSingleCollectionIdentifier {
    func apply<Item>(to items: inout [Item]) where Item: Identifiable, Item.ID == ItemID {
        let moving = Set(sources)
        var moved: [Item] = []
        items.removeAll { item in
            guard moving.contains(item.id) else { return false }
            moved.append(item)
            return true
        }
        switch destination.position {
        case .before(let id):
            let index = items.firstIndex { $0.id == id } ?? items.endIndex
            items.insert(contentsOf: moved, at: index)
        case .end:
            items.append(contentsOf: moved)
        }
    }
}
```

```swift
if #available(iOS 27.0, *) {
    LazyVGrid(columns: columns) {
        ForEach(items) { ItemView($0) }.reorderable()
    }
    .reorderContainer(for: Item.self) { $0.apply(to: &items) }
} else {
    LazyVGrid(columns: columns) {
        ForEach(items) { ItemView($0) }.compatReorderable()
    }
    .compatReorderContainer(for: Item.self) { $0.apply(to: &items) }
}
```

## watchOS & macOS

These platforms have no drag-and-drop interactions to build on (the native watchOS 27 API also runs without them), so CompatReorderable uses a SwiftUI gesture backend: the cell itself becomes the floating preview. On watchOS the drag starts after a 0.4s long press (touch scrolling wins until then; crown scrolling is unaffected); on macOS it starts straight from a small click-drag, matching AppKit's reorder feel — Mac scrolling doesn't claim click-drags, so there's no conflict. Differences from the iOS backend: no system lift animation, no context-menu integration, and no edge auto-scroll.

## Behavior notes & limitations

- Retargeting feel matches the native API: the gap moves once the finger is ~20% into the destination cell, the gap under the finger is a dead zone, and a short cooldown absorbs reflow animations — items cannot "dance."
- Light haptics on lift, each retarget, and drop.
- Vertical containers only (vertical auto-scroll; the retarget heuristics assume column-ish layouts).
- Single collection per container — the native `collectionID:`/sections overloads have no compat counterpart.
- Items cannot be dragged out to other apps; reorder sessions are app-restricted by design.
- The drag preview is a snapshot taken at lift; cells that animate their content will show a static image while dragged.

## How it works

A `UIDragInteraction` and `UIDropInteraction` are installed on the same hosting view that carries SwiftUI's context-menu interaction (that shared view is what makes UIKit link menu and drag). Dragged items carry an empty `NSItemProvider` with a local object — mirroring the native implementation's empty transfer representation. Cell frames are tracked in a container coordinate space via `onGeometryChange`; the drop session location drives a retargeting pass that reorders only a *display* order, never your data. On drop, the difference is reported once and the system's drop animation lands the preview on the item's slot.

## License

MIT
