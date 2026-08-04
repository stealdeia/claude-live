import SwiftUI

/// Which displays carry a notch, and how big it is on each.
///
/// Laid out like System Settings → Displays because it answers the same question,
/// and because a picture of the screen with the bar drawn on it to scale says more
/// than two numbers: the point of the sliders is what the bar looks like *on that
/// display*, and a 170pt bar is a different thing on a 1512pt laptop panel than on
/// a 1920pt monitor.
struct NotchScreensView: View {
    @ObservedObject var settings: Settings
    @StateObject private var screens = ScreenCatalog()
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    screenRow
                    selectionHint
                    Divider()
                    sizeModeSection
                    sizeControls
                }
                .padding(20)
            }

            Divider()
            HStack {
                Button("Ripristina dimensioni") {
                    settings.notchWidth = NotchGeometry.defaultNotchSize.width
                    settings.notchHeight = NotchGeometry.defaultNotchSize.height
                    settings.notchSizeByScreen = [:]
                }
                Spacer()
                Button("Fine", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 660)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Schermi e dimensioni notch")
                .font(.headline)
            Text("Clicca uno schermo per mettervi il notch o togliervelo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: - Screens

    /// Horizontally scrollable so a fourth display does not squeeze the others into
    /// illegibility.
    private var screenRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(screens.screens) { screen in
                    ScreenNotchPreview(
                        screen: screen,
                        notchSize: settings.notchSize(forScreen: screen.id),
                        isActive: activeScreenIDs.contains(screen.id),
                        onToggle: { toggle(screen.id) }
                    )
                }
            }
            .padding(.vertical, 4)
            .frame(minWidth: 520, alignment: .center)
        }
    }

    @ViewBuilder
    private var selectionHint: some View {
        switch settings.notchScreenSelection {
        case .automatic:
            Label(
                "Automatico: il notch segue lo schermo che ne ha uno fisico. Cliccane uno per scegliere a mano.",
                systemImage: "wand.and.stars"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case .all:
            HStack(spacing: 8) {
                Label("Tutti gli schermi, anche quelli che collegherai.", systemImage: "rectangle.3.group")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Torna all'automatico") { setAutomatic() }
                    .controlSize(.small)
            }
        case .chosen:
            HStack(spacing: 8) {
                Label(
                    settings.notchScreenIDs.count == 1
                        ? "Uno schermo scelto a mano."
                        : "\(settings.notchScreenIDs.count) schermi scelti a mano.",
                    systemImage: "hand.point.up.left"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Tutti") {
                    settings.notchScreenSelection = .all
                }
                .controlSize(.small)
                Button("Automatico") { setAutomatic() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Size mode

    private var sizeModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Dimensioni", selection: $settings.usePerScreenNotchSize) {
                Text("Uguali su tutti gli schermi").tag(false)
                Text("Diverse per ogni schermo").tag(true)
            }
            .pickerStyle(.radioGroup)

            Text("La larghezza è quella del tratto centrale: la barra completa aggiunge i due contatori ai lati.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One group per active display when sizes are separate, one shared group
    /// otherwise. Only the displays that actually get a notch are listed: sliders
    /// for a screen with nothing on it would do nothing visible.
    @ViewBuilder
    private var sizeControls: some View {
        if settings.usePerScreenNotchSize {
            let active = screens.screens.filter { activeScreenIDs.contains($0.id) }
            if active.isEmpty {
                Text("Nessuno schermo attivo: scegline uno sopra.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(active) { screen in
                        sizeGroup(
                            title: screen.name,
                            cutout: screen.cutoutSize,
                            width: binding(for: screen.id, isWidth: true),
                            height: binding(for: screen.id, isWidth: false)
                        )
                    }
                }
            }
        } else {
            sizeGroup(
                title: "Tutti gli schermi",
                cutout: sharedCutoutFloor,
                width: $settings.notchWidth,
                height: $settings.notchHeight
            )
        }
    }

    private func sizeGroup(
        title: String,
        cutout: CGSize?,
        width: Binding<Double>,
        height: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.medium))
                if let cutout {
                    Text("minimo \(Int(cutout.width))×\(Int(cutout.height))")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }

            slider(label: "Larghezza", value: width, range: NotchGeometry.widthRange, floor: cutout?.width)
            slider(label: "Altezza", value: height, range: NotchGeometry.heightRange, floor: cutout?.height)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    /// Shows the value the hardware raises it to (`170 → 185 pt`), so the lower half
    /// of the slider does not look broken on a screen with a cutout.
    private func slider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        floor: CGFloat?
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .frame(width: 74, alignment: .leading)
            Slider(value: value, in: range)
            Text(sizeLabel(requested: value.wrappedValue, floor: floor))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .trailing)
        }
    }

    private func sizeLabel(requested: Double, floor: CGFloat?) -> String {
        guard let floor, Double(floor) > requested + 0.5 else { return "\(Int(requested)) pt" }
        return "\(Int(requested)) → \(Int(floor)) pt"
    }

    // MARK: - State

    /// The displays that currently get a notch, whatever the selection mode — so the
    /// ticks always show what is on screen rather than what was configured.
    private var activeScreenIDs: Set<String> {
        Set(
            NotchGeometry.geometries(
                selection: settings.notchScreenSelection,
                chosenIDs: settings.notchScreenIDs
            ).map(\.screenID)
        )
    }

    /// In shared mode the floor is the largest cutout among the active displays:
    /// that is the one that will visibly raise the value.
    private var sharedCutoutFloor: CGSize? {
        let cutouts = screens.screens
            .filter { activeScreenIDs.contains($0.id) }
            .compactMap(\.cutoutSize)
        guard let widest = cutouts.map(\.width).max(),
              let tallest = cutouts.map(\.height).max()
        else { return nil }
        return CGSize(width: widest, height: tallest)
    }

    private func binding(for id: String, isWidth: Bool) -> Binding<Double> {
        Binding(
            get: {
                let size = settings.notchSize(forScreen: id)
                return isWidth ? size.width : size.height
            },
            set: { newValue in
                var size = settings.notchSize(forScreen: id)
                if isWidth { size.width = newValue } else { size.height = newValue }
                settings.setNotchSize(size, forScreen: id)
            }
        )
    }

    /// Same rule as the menu: any click makes the choice explicit, and unticking the
    /// last display returns to automatic rather than leaving nothing selected.
    private func toggle(_ id: String) {
        var wanted = settings.notchScreenSelection == .chosen
            ? Set(settings.notchScreenIDs)
            : activeScreenIDs

        if wanted.contains(id) { wanted.remove(id) } else { wanted.insert(id) }

        guard !wanted.isEmpty else {
            setAutomatic()
            return
        }

        // Connected displays first, in AppKit's order, then remembered identifiers
        // that are not attached right now — so unplugging and replugging a monitor
        // restores its notch.
        let connected = screens.screens.map(\.id)
        settings.notchScreenIDs = connected.filter(wanted.contains) + wanted.subtracting(connected).sorted()
        settings.notchScreenSelection = .chosen
    }

    private func setAutomatic() {
        settings.notchScreenSelection = .automatic
        settings.notchScreenIDs = []
    }
}

/// A small picture of one display with the notch drawn on it to scale.
///
/// The bar is drawn with `NotchShape` at the real proportions, so the preview is the
/// thing itself scaled down rather than an illustration of it — including the point
/// where the hardware raises the size on a screen that has a cutout.
struct ScreenNotchPreview: View {
    let screen: ScreenOption
    let notchSize: CGSize
    let isActive: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    private static let previewWidth: CGFloat = 152

    private var previewHeight: CGFloat {
        guard screen.pointSize.width > 0 else { return 92 }
        return Self.previewWidth * screen.pointSize.height / screen.pointSize.width
    }

    /// Scale from screen points to preview points.
    private var scale: CGFloat {
        guard screen.pointSize.width > 0 else { return 1 }
        return Self.previewWidth / screen.pointSize.width
    }

    /// Size of the drawn bar in preview points.
    ///
    /// The **width** is honest: it is the whole bar — cutout plus the two counter
    /// strips — scaled by the same factor as the screen, because "how much of the top
    /// edge does this take up" is the question the sliders answer.
    ///
    /// The **height** is not, and deliberately: 32pt of a 1512pt-wide screen is 3
    /// preview points, a hairline that reads as a rendering artefact rather than a
    /// bar. It is drawn at a legible minimum instead, and still grows with the
    /// setting.
    private var drawnNotch: CGSize {
        let effective = screen.effectiveNotchSize(requested: notchSize)
        let barWidth = effective.width + (NotchGeometry.stripChromeWidth + NotchGeometry.baseRingDiameter) * 2
        return CGSize(
            // Only a floor against the degenerate case: at 152 preview points even a
            // 60pt bar is 5 points wide and still legible, and a larger floor would
            // make the bar on a 1920pt monitor look proportionally wider than it is —
            // destroying the one comparison this preview exists to make.
            width: max(barWidth * scale, 12),
            height: max(effective.height * scale * 2.2, 7)
        )
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 17)

            Button(action: onToggle) {
                screenBody
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }

            VStack(spacing: 1) {
                Text(screen.name)
                    .font(.caption.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                Text(screen.hasPhysicalNotch ? "notch fisico" : "\(Int(screen.pixelSize.width))×\(Int(screen.pixelSize.height))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: Self.previewWidth)
        }
    }

    private var screenBody: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.30, green: 0.55, blue: 0.78),
                             Color(red: 0.16, green: 0.33, blue: 0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: Self.previewWidth, height: previewHeight)
            .overlay(alignment: .top) {
                NotchShape(
                    // Scaled down too, otherwise the flare would dominate a 6pt-tall
                    // bar and the preview would look nothing like the real surface.
                    topFlareRadius: max(NotchGeometry.flareRadius * scale, 1.5),
                    bottomCornerRadius: max(NotchGeometry.collapsedCornerRadius * scale, 1.5)
                )
                .fill(Color.black)
                .frame(width: drawnNotch.width, height: drawnNotch.height)
                .opacity(isActive ? 1 : 0.28)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isActive ? Color.accentColor : Color.secondary.opacity(isHovering ? 0.55 : 0.25),
                        lineWidth: isActive ? 3 : 1.5
                    )
            }
            .contentShape(Rectangle())
    }
}
