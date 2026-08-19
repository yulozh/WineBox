import Foundation
import UIKit

/// 极简 VT100/xterm 转义序列解释器。
/// 支持：光标移动(CUU/CUD/CUF/CUB/CUP)、清屏(ED)、清行(EL)、
/// SGR 颜色(8/16 色 + 亮色 + 256 色忽略映射)、退格/回车/Tab。
/// 足以正确显示 shell 提示符、ls 颜色、apk/pip 进度、gcc 错误、REPL。
final class VT100 {

    struct Cell {
        var char: Character
        var fg: UInt8 = 7 // default
        var bold = false
        var inverse = false
    }

    private(set) var lines: [[Cell]] = [[Cell]]()
    private var cursorRow = 0
    private var cursorCol = 0
    private var currentFg: UInt8 = 7
    private var currentBold = false
    private var currentInverse = false
    private var savedRow = 0
    private var savedCol = 0

    /// 最大行数（滚动缓冲上限，防内存无限增长）
    private let maxLines = 2000
    private(set) var width: Int

    init(width: Int = 80) {
        self.width = max(8, min(width, 500))
        lines = [Array(repeating: Cell(char: " "), count: self.width)]
    }

    // MARK: - 输入

    /// 喂入控制台字节流（UTF-8，可分块）
    func feed(_ data: Data) {
        // 解码为字符串（跨块的 UTF-8 由 String(decoding:) 容错处理）
        let s = String(decoding: data, as: UTF8.self)
        for scalar in s.unicodeScalars {
            handleScalar(scalar)
        }
    }

    // MARK: - 渲染

    /// 输出为 NSAttributedString（等宽字体由调用方设置）
    func attributedString(baseFont: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let normal = [NSAttributedString.Key.font: baseFont,
                      NSAttributedString.Key.foregroundColor: VT100.color(7)]
        for (i, line) in lines.enumerated() {
            var runText = ""
            var runAttr = normal
            var runKey: String = "7"
            for cell in line {
                let key = "\(cell.fg)|\(cell.bold ? 1 : 0)|\(cell.inverse ? 1 : 0)"
                if key != runKey {
                    out.append(NSAttributedString(string: runText, attributes: runAttr))
                    runText = ""
                    runKey = key
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: cell.bold ? VT100.boldFont(baseFont) : baseFont,
                        .foregroundColor: cell.inverse ? VT100.color(0) : VT100.color(cell.fg),
                    ]
                    if cell.inverse {
                        attrs[.backgroundColor] = VT100.color(cell.fg)
                    }
                    runAttr = attrs
                }
                runText.append(cell.char)
            }
            out.append(NSAttributedString(string: runText, attributes: runAttr))
            if i < lines.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: normal))
            }
        }
        return out
    }

    /// 去除全部转义序列的纯文本（用于导出日志）
    var plainText: String {
        lines.map { String($0.map(\.char)) }.joined(separator: "\n")
    }

    var cursorAtBottom: Bool { cursorRow >= lines.count - 1 }

    // MARK: - 内部实现

    private func ensureRow(_ row: Int) {
        while lines.count <= row {
            lines.append(Array(repeating: Cell(char: " "), count: width))
        }
    }

    private func blankLine() -> [Cell] {
        Array(repeating: Cell(char: " "), count: width)
    }

    private func scrollIfNeeded() {
        if cursorRow >= maxLines {
            let drop = cursorRow - maxLines + 1
            lines.removeFirst(drop)
            cursorRow -= drop
        }
    }

    private func handleScalar(_ scalar: Unicode.Scalar) {
        // ---- escape sequence state machine ----
        if scalar == "\u{1B}" {
            startEscapeIfNeeded(scalar)
            return
        }
        if let handler = pendingEscape {
            handler(scalar)
            return
        }

        switch scalar {
        case "\n", "\u{0B}", "\u{0C}": // LF, VT, FF
            cursorRow += 1
            ensureRow(cursorRow)
            scrollIfNeeded()
        case "\r":
            cursorCol = 0
        case "\b":
            if cursorCol > 0 { cursorCol -= 1 }
        case "\t":
            let next = ((cursorCol / 8) + 1) * 8
            while cursorCol < min(next, width) {
                putChar(" ")
            }
        case "\u{07}": // BEL：忽略
            break
        default:
            if scalar.value >= 32 {
                putChar(Character(scalar))
            }
        }
    }

    private func putChar(_ c: Character) {
        ensureRow(cursorRow)
        var line = lines[cursorRow]
        if cursorCol >= width { // 简单软换行（xterm 的 DECAWM 默认开）
            cursorCol = 0
            cursorRow += 1
            ensureRow(cursorRow)
            scrollIfNeeded()
            line = lines[cursorRow]
        }
        var cell = line.count > cursorCol ? line[cursorCol] : Cell(char: " ")
        cell.char = c
        cell.fg = currentFg
        cell.bold = currentBold
        cell.inverse = currentInverse
        while line.count <= cursorCol { line.append(Cell(char: " ")) }
        line[cursorCol] = cell
        lines[cursorRow] = line
        cursorCol += 1
    }

    // ---- escape parsing ----

    private var pendingEscape: ((Unicode.Scalar) -> Void)?

    private func startEscapeIfNeeded(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar == "\u{1B}" else { return false }
        pendingEscape = { [weak self] next in
            guard let self else { return }
            self.pendingEscape = nil
            switch next {
            case "[":
                self.pendingEscape = self.csiHandler
            case "(" , ")": // 字符集切换：吃掉一个字符
                self.pendingEscape = { _ in self.pendingEscape = nil }
            case "7": self.savedRow = self.cursorRow; self.savedCol = self.cursorCol
            case "8": self.cursorRow = self.savedRow; self.cursorCol = self.savedCol
            default: break // =, >, M 等忽略
            }
        }
        return true
    }

    // CSI: ESC [ params letter
    private lazy var csiHandler: (Unicode.Scalar) -> Void = { [weak self] scalar in
        guard let self else { return }
        if scalar == "\u{1B}" { // 新的转义开始
            self.pendingEscape = nil
            self.startEscapeIfNeeded(scalar)
            return
        }
        if ("0"..."9").contains(scalar) || scalar == ";" || scalar == "?" || scalar == " " {
            csiBuffer.unicodeScalars.append(scalar)
            return
        }
        // 终结符
        let params = csiBuffer.split(separator: ";").compactMap { Int($0.filter(\.isNumber)) }
        csiBuffer = ""
        pendingEscape = nil

        switch scalar {
        case "A": move(-max(params.first ?? 1, 1), 0)                    // CUU
        case "B", "e": move(max(params.first ?? 1, 1), 0)                // CUD
        case "C", "a": move(0, max(params.first ?? 1, 1))                // CUF
        case "D": move(0, -max(params.first ?? 1, 1))                    // CUB
        case "E": move(max(params.first ?? 1, 1), 0); cursorCol = 0      // CNL
        case "F": move(-max(params.first ?? 1, 1), 0); cursorCol = 0     // CPL
        case "G", "`": cursorCol = clampCol((params.first ?? 1) - 1)     // CHA
        case "d": cursorRow = max(0, (params.first ?? 1) - 1); ensureRow(cursorRow) // VPA
        case "H", "f": // CUP
            let row = params.first ?? 1
            let col = params.count > 1 ? params[1] : 1
            cursorRow = max(0, row - 1)
            cursorCol = clampCol(col - 1)
            ensureRow(cursorRow)
            scrollIfNeeded()
        case "J": // ED
            let mode = params.first ?? 0
            switch mode {
            case 0: // 光标到末尾
                clearRange(row: cursorRow, from: cursorCol, toEndOfRow: true)
                if cursorRow + 1 < lines.count {
                    lines.removeSubrange((cursorRow + 1)...)
                }
            case 1: // 开头到光标
                clearRange(row: cursorRow, from: 0, toEndOfRow: false, upToCol: cursorCol)
                for r in 0..<min(cursorRow, lines.count) { lines[r] = blankLine() }
            default: // 2/3: 全屏
                lines = [blankLine()]
                cursorRow = 0
                cursorCol = 0
            }
        case "K": // EL
            let mode = params.first ?? 0
            switch mode {
            case 0: clearRange(row: cursorRow, from: cursorCol, toEndOfRow: true)
            case 1: clearRange(row: cursorRow, from: 0, toEndOfRow: false, upToCol: cursorCol)
            default: clearRange(row: cursorRow, from: 0, toEndOfRow: true)
            }
        case "m": // SGR
            applySGR(params.isEmpty ? [0] : params)
        case "s": savedRow = cursorRow; savedCol = cursorCol
        case "u": cursorRow = savedRow; cursorCol = savedCol
        case "L": // 插入行
            if cursorRow < lines.count {
                lines.insert(blankLine(), at: cursorRow)
            } else {
                ensureRow(cursorRow)
            }
        case "M": // 删除行
            if cursorRow < lines.count {
                lines.remove(at: cursorRow)
                ensureRow(cursorRow)
            }
        case "P": // 删除字符
            let n = params.first ?? 1
            if cursorRow < lines.count {
                var line = lines[cursorRow]
                for _ in 0..<n where cursorCol < line.count {
                    line.remove(at: cursorCol)
                }
                line.append(contentsOf: Array(repeating: Cell(char: " "), count: width - line.count))
                lines[cursorRow] = Array(line.prefix(width))
            }
        default:
            break // 其余（h/l 模式、X 填充等）忽略
        }
    }

    private var csiBuffer = ""

    private func move(_ dRow: Int, _ dCol: Int) {
        cursorRow = max(0, cursorRow + dRow)
        cursorCol = clampCol(cursorCol + dCol)
        ensureRow(cursorRow)
        scrollIfNeeded()
    }

    private func clampCol(_ c: Int) -> Int { max(0, min(c, width - 1)) }

    private func clearRange(row: Int, from: Int, toEndOfRow: Bool, upToCol: Int? = nil) {
        ensureRow(row)
        var line = lines[row]
        if toEndOfRow {
            for c in from..<width where c < line.count {
                line[c] = Cell(char: " ")
            }
            if from >= line.count { /* already shorter */ }
        } else if let upTo = upToCol {
            for c in from...min(upTo, width - 1) where c < line.count {
                line[c] = Cell(char: " ")
            }
        }
        lines[row] = line
    }

    private func applySGR(_ params: [Int]) {
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                currentFg = 7; currentBold = false; currentInverse = false
            case 1: currentBold = true
            case 7: currentInverse = true
            case 22: currentBold = false
            case 27: currentInverse = false
            case 30...37: currentFg = UInt8(p - 30)
            case 90...97: currentFg = UInt8(p - 90 + 8)
            case 39: currentFg = 7
            default: break
            }
            i += 1
        }
    }

    // MARK: - 颜色表（xterm 16 色，暗色终端配色）

    private static let palette: [UIColor] = [
        UIColor(red: 0.20, green: 0.20, blue: 0.23, alpha: 1), // 0 黑
        UIColor(red: 0.90, green: 0.35, blue: 0.35, alpha: 1), // 1 红
        UIColor(red: 0.45, green: 0.80, blue: 0.45, alpha: 1), // 2 绿
        UIColor(red: 0.85, green: 0.75, blue: 0.40, alpha: 1), // 3 黄
        UIColor(red: 0.45, green: 0.60, blue: 0.95, alpha: 1), // 4 蓝
        UIColor(red: 0.75, green: 0.50, blue: 0.95, alpha: 1), // 5 品
        UIColor(red: 0.40, green: 0.85, blue: 0.85, alpha: 1), // 6 青
        UIColor(red: 0.88, green: 0.89, blue: 0.91, alpha: 1), // 7 白(默认)
        UIColor(red: 0.45, green: 0.46, blue: 0.49, alpha: 1), // 8 亮黑(灰)
        UIColor(red: 0.98, green: 0.50, blue: 0.50, alpha: 1), // 9
        UIColor(red: 0.55, green: 0.95, blue: 0.55, alpha: 1), // 10
        UIColor(red: 0.98, green: 0.90, blue: 0.55, alpha: 1), // 11
        UIColor(red: 0.55, green: 0.70, blue: 1.00, alpha: 1), // 12
        UIColor(red: 0.85, green: 0.60, blue: 1.00, alpha: 1), // 13
        UIColor(red: 0.50, green: 0.95, blue: 0.95, alpha: 1), // 14
        UIColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1), // 15
    ]

    static func color(_ idx: UInt8) -> UIColor {
        palette[Int(idx) % palette.count]
    }

    /// 粗体版本字体（UIFont 没有 .bold()；用描述符派生并缓存，避免逐 run 重建）
    private static var boldFontCache: [CGFloat: UIFont] = [:]
    static func boldFont(_ font: UIFont) -> UIFont {
        if let cached = boldFontCache[font.pointSize] { return cached }
        let bold: UIFont
        if let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) {
            bold = UIFont(descriptor: descriptor, size: font.pointSize)
        } else {
            bold = UIFont.boldSystemFont(ofSize: font.pointSize)
        }
        boldFontCache[font.pointSize] = bold
        return bold
    }
}
