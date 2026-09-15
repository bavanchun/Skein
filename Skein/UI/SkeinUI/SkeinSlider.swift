//
//  SkeinSlider.swift
//  Skein
//

import CompactSlider
import SwiftUI

struct SkeinSlider<Value: BinaryFloatingPoint, ValueLabel: View, ValueLabelSelectability: TextSelectability>: View {
    private let value: Binding<Value>
    private let bounds: ClosedRange<Value>
    private let step: Value
    private let valueLabel: ValueLabel
    private let valueLabelSelectability: ValueLabelSelectability

    init(
        value: Binding<Value>,
        in bounds: ClosedRange<Value> = 0...1,
        step: Value = 0,
        valueLabelSelectability: ValueLabelSelectability = .disabled,
        @ViewBuilder valueLabel: () -> ValueLabel
    ) {
        self.value = value
        self.bounds = bounds
        self.step = step
        self.valueLabel = valueLabel()
        self.valueLabelSelectability = valueLabelSelectability
    }

    init(
        _ valueLabelKey: LocalizedStringKey,
        valueLabelSelectability: ValueLabelSelectability = .disabled,
        value: Binding<Value>,
        in bounds: ClosedRange<Value> = 0...1,
        step: Value = 0
    ) where ValueLabel == Text {
        self.init(
            value: value,
            in: bounds,
            step: step,
            valueLabelSelectability: valueLabelSelectability
        ) {
            Text(valueLabelKey)
        }
    }

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        CompactSlider(
            value: value,
            in: bounds,
            step: step
        )
        .compactSliderHandleStyle(.rectangle(visibility: .focused, width: 1))
        .compactSliderOptionsByRemoving(.enabledHapticFeedback)
        .overlay {
            HStack {
                valueLabel
                    .textSelection(valueLabelSelectability)
            }
            .padding(.horizontal, 6)
        }
        // CompactSlider 2 no longer dims when disabled or sizes itself; its
        // default style expands to fill the proposed height.
        .opacity(isEnabled ? 1 : 0.5)
        .frame(minHeight: .compactSliderMinHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension CGFloat {
    /// The minimum height of a ``SkeinSlider``, also used to align labels beside one.
    static let compactSliderMinHeight: CGFloat = 24
}
