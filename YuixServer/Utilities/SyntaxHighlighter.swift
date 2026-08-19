import UIKit

/// 基于正则的轻量语法高亮器。
///
/// 着色原则（修复旧版「满屏乱色」的根因）：
///  1. 词法有优先级：注释 > 字符串 > 关键字/标签 > 数字；
///  2. 高优先级命中的区间不再被低优先级覆盖 ——
///     旧版按规则顺序逐个 addAttribute，后面的规则会把字符串里的关键字、
///     URL 里的 `//` 重新染色，看起来五颜六色；
///  3. HTML 不再用 `\b(p|a)\b` 这类词边界匹配标签名（会把正文里单个字母 a/p 染紫），
///     只匹配真正的标签形态 `</?tag`。
enum SyntaxHighlighter {

    private struct Token {
        let range: NSRange
        let color: UIColor
        let priority: Int   // 越小越优先
    }

    static func highlight(_ text: String, language: Language) -> NSAttributedString {
        let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: UIColor.label]
        )
        let ns = text as NSString
        guard ns.length > 0 else { return result }

        var tokens: [Token] = []
        for (pattern, color, priority) in rules(for: language) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                tokens.append(Token(range: match.range, color: color, priority: priority))
            }
        }

        // 先按优先级、再按位置排序；跳过与已占用区间重叠的命中
        tokens.sort { lhs, rhs in
            lhs.priority != rhs.priority ? lhs.priority < rhs.priority : lhs.range.location < rhs.range.location
        }
        var taken: [NSRange] = []
        for token in tokens where !taken.contains(where: { overlaps($0, token.range) }) {
            result.addAttribute(.foregroundColor, value: token.color, range: token.range)
            taken.append(token.range)
        }
        return result
    }

    // MARK: - 规则

    private static func rules(for language: Language) -> [(String, UIColor, Int)] {
        var rules: [(String, UIColor, Int)] = [
            (#""(?:\\.|[^"\\\n])*""#, .systemGreen, 1),   // 双引号字符串
            (#"'(?:\\.|[^'\\\n])*'"#, .systemGreen, 1)    // 单引号字符串
        ]

        // 注释（最高优先级）
        switch language {
        case .python:
            rules.append((#"#[^\n]*"#, .systemGray, 0))
        case .php, .node:
            rules.append((#"//[^\n]*"#, .systemGray, 0))
            rules.append((#"/\*[\s\S]*?\*/"#, .systemGray, 0))
        case .html:
            rules.append((#"<!--[\s\S]*?-->"#, .systemGray, 0))
        }

        // 关键字 / 标签
        let keywords = keywords(for: language)
        if !keywords.isEmpty {
            let pattern = #"\b(\#(keywords.joined(separator: "|")))\b"#
            rules.append((pattern, .systemPurple, 2))
        }
        if language == .html {
            // HTML：只染真正的标签形态，避免把正文里的 a/p 染色
            rules.append((#"</?[A-Za-z][A-Za-z0-9-]*"#, .systemPurple, 2))
        }

        // 数字
        rules.append((#"\b\d+(\.\d+)?\b"#, .systemOrange, 3))
        return rules
    }

    private static func keywords(for language: Language) -> [String] {
        switch language {
        case .python:
            return ["def", "class", "return", "if", "elif", "else", "for", "while", "import", "from", "as", "try", "except", "finally", "with", "lambda", "True", "False", "None", "pass", "break", "continue"]
        case .php:
            return ["function", "return", "if", "else", "elseif", "foreach", "for", "while", "echo", "class", "new", "public", "private", "protected", "static", "require", "include", "true", "false", "null"]
        case .node:
            return ["const", "let", "var", "function", "return", "if", "else", "for", "while", "require", "module", "exports", "new", "class", "typeof", "true", "false", "null", "undefined", "async", "await"]
        case .html:
            return []   // 标签已由专用规则处理
        }
    }

    // MARK: - 工具

    private static func overlaps(_ a: NSRange, _ b: NSRange) -> Bool {
        a.location < b.location + b.length && b.location < a.location + a.length
    }
}
