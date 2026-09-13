import AppKit
import SwiftUI

/// 淡雾蓝主题。所有颜色集中在这里，换色只改这一个文件。
/// 只做浅色：App 启动时强制浅色外观，不跟随系统深色模式。
enum Theme {
    // 底色层级：窗口 → 侧栏/时间轴区 → 卡片与输入框
    static let window      = Color(hex: 0xF4F7FA)
    static let panel       = Color(hex: 0xEDF2F7)
    static let dock        = Color(hex: 0xF8FAFC)
    static let surface     = Color.white
    static let canvas      = Color(hex: 0xE6EDF3)   // 预览画布

    // 线与文字
    static let hairline    = Color(hex: 0xDFE6EE)
    static let border      = Color(hex: 0xD6DFE8)
    static let text        = Color(hex: 0x22303C)
    static let textSecondary = Color(hex: 0x6E7E8C)
    static let textMuted   = Color(hex: 0x9AA8B4)

    // 唯一的强调色：选中、选区、主按钮、无损徽标都用它
    static let accent      = Color(hex: 0x4F84B1)
    static let accentPressed = Color(hex: 0x436F95)
    static let accentSoft  = Color(hex: 0xE3EDF6)
    static let accentText  = Color(hex: 0x36648C)

    // 提示只用琥珀色；失败用低饱和的砖红
    static let warning     = Color(hex: 0xB27A3C)
    static let warningSoft = Color(hex: 0xF7EEE3)
    static let danger      = Color(hex: 0xB45454)
    static let dangerSoft  = Color(hex: 0xF6E6E6)
    static let success     = Color(hex: 0x3F8F76)

    static let radius: CGFloat = 8
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - 按钮样式

/// 主按钮：实心雾蓝。一个视图里只放一个。
struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .fill(configuration.isPressed ? Theme.accentPressed : Theme.accent)
            )
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// 次按钮：白底细边。
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius - 1)
                    .fill(configuration.isPressed ? Theme.panel : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius - 1)
                    .strokeBorder(Theme.border, lineWidth: 0.5)
            )
    }
}

/// 文字按钮：只有雾蓝字。
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(configuration.isPressed ? Theme.accentPressed : Theme.accentText)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }
}

/// 圆形图标按钮，用在时间轴区的播放与关键帧步进。
struct RoundIconButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? .white : Theme.accentText)
            .frame(width: 26, height: 26)
            .background(
                Circle().fill(prominent
                              ? (configuration.isPressed ? Theme.accentPressed : Theme.accent)
                              : (configuration.isPressed ? Theme.border : Theme.accentSoft))
            )
    }
}

// MARK: - 小组件

/// 圆角胶囊徽标。
struct Pill: View {
    let text: String
    var foreground = Theme.accentText
    var background = Theme.accentSoft

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(background))
    }
}

/// 自绘分段控件。系统 segmented Picker 的选中色跟随系统强调色，改不成雾蓝。
struct SegmentedChoice<Value: Hashable>: View {
    let options: [Value]
    let label: (Value) -> String
    let isSelected: (Value) -> Bool
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = isSelected(option)
                Button { onSelect(option) } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Color.white : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected ? Theme.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

/// 自绘复选框，勾选色用雾蓝。
struct ThemedCheckbox: View {
    let title: String
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isOn ? Theme.accent : Theme.surface)
                    .frame(width: 14, height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isOn ? Theme.accent : Theme.border, lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .opacity(isOn ? 1 : 0)
                    )
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 细边白底的时间码输入框。
struct TimecodeField: View {
    let label: String
    @Binding var text: String
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            TextField("0:00.00", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing)
                .frame(width: 66)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 0.5))
                .onChange(of: text) { _ in onChange() }
        }
    }
}

/// 侧栏里的小节标题。
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - 窗口拖动

/// 隐藏标题栏后，由自绘顶栏负责拖动窗口。
/// 不用 isMovableByWindowBackground：那会让时间轴空白处的拖动也变成挪窗口。
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}
