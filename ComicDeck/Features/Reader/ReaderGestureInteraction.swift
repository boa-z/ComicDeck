import SwiftUI

enum ReaderGestureAction {
    case previous
    case next
    case toggleControls
    case none
}

struct ReaderTapZone {
    let rect: CGRect
    let action: ReaderGestureAction
}

enum ReaderTapZoneResolver {
    static func zones(
        preset: TapZonePreset,
        readerMode: ReaderMode,
        tapTurnMargin: CGFloat = 0.30
    ) -> [ReaderTapZone] {
        switch preset {
        case .edgeBiased:
            return edgeBiasedZones(readerMode: readerMode, tapTurnMargin: tapTurnMargin)
        default:
            return []
        }
    }

    static func action(
        for point: CGPoint,
        zones: [ReaderTapZone],
        invertTapZones: Bool
    ) -> ReaderGestureAction {
        guard let zone = zones.first(where: { $0.rect.contains(point) }) else {
            return .toggleControls
        }

        switch zone.action {
        case .previous:
            return invertTapZones ? .next : .previous
        case .next:
            return invertTapZones ? .previous : .next
        case .toggleControls, .none:
            return zone.action
        }
    }

    private static func edgeBiasedZones(readerMode: ReaderMode, tapTurnMargin: CGFloat) -> [ReaderTapZone] {
        switch readerMode {
        case .vertical:
            let edgeWidth: CGFloat = 0.10
            return [
                ReaderTapZone(rect: CGRect(x: 0, y: 0, width: edgeWidth, height: 1), action: .toggleControls),
                ReaderTapZone(rect: CGRect(x: 1 - edgeWidth, y: 0, width: edgeWidth, height: 1), action: .toggleControls),
                ReaderTapZone(rect: CGRect(x: edgeWidth, y: 0, width: 1 - edgeWidth * 2, height: 1), action: .toggleControls)
            ]
        case .ltr, .rtl:
            let edgeWidth = min(max(tapTurnMargin, 0.20), 0.45)
            let leftEdge = CGRect(x: 0, y: 0, width: edgeWidth, height: 1)
            let center = CGRect(x: edgeWidth, y: 0, width: 1 - edgeWidth * 2, height: 1)
            let rightEdge = CGRect(x: 1 - edgeWidth, y: 0, width: edgeWidth, height: 1)

            if readerMode == .rtl {
                return [
                    ReaderTapZone(rect: leftEdge, action: .next),
                    ReaderTapZone(rect: center, action: .toggleControls),
                    ReaderTapZone(rect: rightEdge, action: .previous)
                ]
            } else {
                return [
                    ReaderTapZone(rect: leftEdge, action: .previous),
                    ReaderTapZone(rect: center, action: .toggleControls),
                    ReaderTapZone(rect: rightEdge, action: .next)
                ]
            }
        }
    }
}

struct ReaderGestureInteractionConfiguration {
    let readerMode: ReaderMode
    let tapZonePreset: TapZonePreset
    let invertTapZones: Bool
    let isZoomed: Bool
    let isInteractingWithControls: Bool
    let controlsVisible: Bool
    let onSingleTap: (CGPoint, CGSize) -> Void
}

struct ReaderGestureInteractionModifier: ViewModifier {
    let configuration: ReaderGestureInteractionConfiguration

    @State private var pendingSingleTapWorkItem: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(doubleTapGesture)
            .gesture(singleTapGesture)
    }

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { _ in
                pendingSingleTapWorkItem?.cancel()
            }
    }

    private var singleTapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                pendingSingleTapWorkItem?.cancel()

                let location = value.location

                // When controls are visible, any tap dismisses them immediately
                if configuration.controlsVisible {
                    configuration.onSingleTap(location, .zero)
                    return
                }

                let workItem = DispatchWorkItem {
                    guard !configuration.isZoomed,
                          !configuration.isInteractingWithControls else {
                        return
                    }

                    configuration.onSingleTap(location, .zero)
                }

                pendingSingleTapWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
            }
    }
}

extension View {
    func readerGestureInteraction(_ configuration: ReaderGestureInteractionConfiguration) -> some View {
        modifier(ReaderGestureInteractionModifier(configuration: configuration))
    }
}
