import SwiftUI

/// 简易 Markdown 渲染视图（标题/加粗/列表/分隔线）
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parseLines().enumerated()), id: \.offset) { _, element in
                element
            }
        }
    }

    private func parseLines() -> [AnyView] {
        let lines = text.components(separatedBy: "\n")
        var result: [AnyView] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 分隔线
            if trimmed.hasPrefix("---") || trimmed.hasPrefix("***") {
                result.append(AnyView(
                    Divider().padding(.vertical, 4)
                ))
                continue
            }

            // 标题
            if let (level, content) = parseHeading(trimmed) {
                let font: Font = level <= 2 ? .headline : .subheadline
                result.append(AnyView(
                    renderInlineMarkdown(content)
                        .font(font)
                        .fontWeight(.bold)
                        .padding(.top, 8)
                ))
                continue
            }

            // 列表项
            if let content = parseListItem(trimmed) {
                result.append(AnyView(
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        renderInlineMarkdown(content)
                    }
                    .padding(.leading, 8)
                ))
                continue
            }

            // 有序列表
            if let (num, content) = parseOrderedListItem(trimmed) {
                result.append(AnyView(
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(num).")
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        renderInlineMarkdown(content)
                    }
                    .padding(.leading, 4)
                ))
                continue
            }

            // 空行
            if trimmed.isEmpty {
                result.append(AnyView(Spacer().frame(height: 8)))
                continue
            }

            // 普通文本
            result.append(AnyView(
                renderInlineMarkdown(trimmed)
            ))
        }

        return result
    }

    private func parseHeading(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex && line[idx] == "#" {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0 && level <= 6, idx < line.endIndex, line[idx] == " " else { return nil }
        let content = String(line[line.index(after: idx)...])
        return (level, content)
    }

    private func parseListItem(_ line: String) -> String? {
        if (line.hasPrefix("- ") || line.hasPrefix("* ")) && line.count > 2 {
            return String(line.dropFirst(2))
        }
        return nil
    }

    private func parseOrderedListItem(_ line: String) -> (Int, String)? {
        let pattern = /^(\d+)\.\s+(.+)$/
        if let match = line.firstMatch(of: pattern) {
            return (Int(match.1) ?? 0, String(match.2))
        }
        return nil
    }

    /// 行内 Markdown：**加粗** 和 *斜体*
    @ViewBuilder
    private func renderInlineMarkdown(_ text: String) -> some View {
        Text(attributedInline(text))
            .font(.body)
            .textSelection(.enabled)
    }

    private func attributedInline(_ text: String) -> AttributedString {
        var result = AttributedString()
        var remaining = text

        while !remaining.isEmpty {
            // **加粗**
            if let boldRange = remaining.range(of: "**") {
                // 找到第一个 **
                let before = String(remaining[remaining.startIndex..<boldRange.lowerBound])
                if !before.isEmpty {
                    result.append(AttributedString(before))
                }

                let afterOpen = remaining[boldRange.upperBound...]
                if let closeRange = afterOpen.range(of: "**") {
                    let boldText = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
                    var boldAttr = AttributedString(boldText)
                    boldAttr.font = .body.bold()
                    result.append(boldAttr)
                    remaining = String(afterOpen[closeRange.upperBound...])
                } else {
                    result.append(AttributedString(remaining))
                    remaining = ""
                }
            } else {
                result.append(AttributedString(remaining))
                remaining = ""
            }
        }

        return result
    }
}
