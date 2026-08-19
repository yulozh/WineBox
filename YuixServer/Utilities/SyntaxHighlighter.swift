import UIKit

/// 基于正则的轻量语法高亮器。
/// 对 .py/.php/.js/.html/.json 等常见类型做关键字/字符串/注释/数字着色。
/// 说明：这里是教学级实现，适合中小文件；生产环境可替换为 Runestone / CodeMirror 等专业编辑器。
enum SyntaxHighlighter {

    static func highlight(_ text: String, language: Language) -> NSAttributedString {
        let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
        let result = NSMutableAttributedString(string: text, attributes: attr)

        // 各语言的普通注释
        var commentPatterns: [String] = []
        switch language {
        case .python: commentPatterns = [#"#[^\n]*"#]
        case .php, .node: commentPatterns = [#"//[^\n]*"#, #"/\*[\s\S]*?\*/"#]
        case .html: commentPatterns = [#"<!--[\s\S]*?-->"#, #"//[^\n]*"#, #"/\*[\s\S]*?\*/"#]
        }

        // (正则, 颜色)
        var rules: [(String, UIColor)] = [
            (#""(?:\\.|[^"\\])*""#, .systemGreen),   // 双引号字符串
            (#"'(?:\\.|[^'\\])*'"#, .systemGreen),   // 单引号字符串
            (#"\b\d+(\.\d+)?\b"#, .systemOrange)     // 数字
        ]
        rules += commentPatterns.map { ($0, UIColor.systemGray) }

        // 关键字
        let keywords = Set(keywords(for: language))
        let keywordPattern = #"\b(\#(keywords.joined(separator: "|")))\b"#
        if !keywords.isEmpty {
            rules.append((keywordPattern, .systemPurple))
        }

        for (pattern, color) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            // 命中范围加色（倒序避免 range 偏移问题——此处直接覆盖即可）
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                result.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        return result
    }

    private static func keywords(for language: Language) -> [String] {
        switch language {
        case .python:
            return ["def", "class", "return", "if", "elif", "else", "for", "while", "import", "from", "as", "try", "except", "finally", "with", "lambda", "print", "True", "False", "None", "pass", "break", "continue"]
        case .php:
            return ["<?php", "function", "return", "if", "else", "elseif", "foreach", "for", "while", "echo", "class", "new", "public", "private", "protected", "static", "require", "include", "true", "false", "null"]
        case .node:
            return ["const", "let", "var", "function", "return", "if", "else", "for", "while", "require", "module", "exports", "new", "class", "typeof", "true", "false", "null", "undefined", "async", "await", "typeof"]
        case .html:
            return ["html", "head", "body", "div", "span", "p", "a", "script", "style", "link", "meta", "title", "h1", "h2", "h3"]
        }
    }
}