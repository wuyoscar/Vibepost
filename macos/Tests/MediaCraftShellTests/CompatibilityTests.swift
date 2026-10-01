import Foundation
import Testing

/// 旧 WebKit 上的退化（docs/compatibility.md）：最低的 macOS 14.0 自带 Safari 17.0，比它新的 CSS 只能写成有退路的样子。
/// 本机的 WebKit 总是新的，写错了在这里看不出来，所以直接查页面实际加载的样式表源码：
/// - `allow-discrete` 只写在 `transition-behavior` 里：写进 `transition` 简写，不认识它的 WebKit 会丢掉整条过渡
/// - 无前缀的 `backdrop-filter`（Safari 18）旁边都有 `-webkit-backdrop-filter`
/// - `linear()`（Safari 17.2）只用在动效令牌 `--ease-spring`，并且有 `@supports not` 的贝塞尔退路
/// - 用 `scrollbar-width: none`（Safari 18.2）藏滚动条的地方都有 `::-webkit-scrollbar` 退路
/// 没有进退场动画时状态照常，这一点全部测试都在查：harness 的窗口看不见，页面一直是 data-motion="paused"，过渡与动画全关。
@MainActor
struct CompatibilityTests {
    private struct Rule {
        let sheet: String
        let selector: String
        let declarations: [(property: String, value: String)]

        func has(_ property: String) -> Bool { declarations.contains { $0.property == property } }
    }

    @Test("样式表只用旧 WebKit 也认得的写法：比 Safari 17.0 新的特性都有退路")
    func stylesheetsKeepFallbacksForOlderWebKit() async throws {
        let harness = ShellHarness()
        try await harness.load()
        let sheets = try await harness.evaluate("""
            const own = [...document.styleSheets].map((sheet) => sheet.href).filter((href) => href?.startsWith(`${location.origin}/src/`));
            return Object.fromEntries(await Promise.all(own.map(async (href) => [href.slice(location.origin.length + 1), await (await fetch(href)).text()])));
        """) as? [String: String] ?? [:]
        await harness.tearDown()

        #expect(sheets.keys.contains("src/styles.css"))
        let rules = sheets.flatMap { Self.rules(in: $0.value, sheet: $0.key) }
        let describe = { (rule: Rule) in "\(rule.sheet) \(rule.selector)" }

        let discreteInShorthand = rules.filter { rule in
            rule.declarations.contains { $0.property == "transition" && $0.value.contains("allow-discrete") }
        }
        #expect(discreteInShorthand.map(describe) == [], "allow-discrete 要单独写成 transition-behavior")

        let unprefixedBackdrop = rules.filter { $0.has("backdrop-filter") && !$0.has("-webkit-backdrop-filter") }
        #expect(unprefixedBackdrop.map(describe) == [], "backdrop-filter 旁边要有 -webkit-backdrop-filter")

        let linearUses = rules.flatMap { rule in rule.declarations.filter { $0.value.contains("linear(") }.map { "\(describe(rule)) \($0.property)" } }
        #expect(linearUses.allSatisfy { $0.hasSuffix(" --ease-spring") }, "linear() 只放在 --ease-spring 令牌里：\(linearUses)")
        let springFallback = sheets.values.contains { $0.contains(#/@supports\s+not\s*\(\s*transition-timing-function\s*:\s*linear\(/#) }
            && rules.contains { rule in rule.declarations.contains { $0.property == "--ease-spring" && $0.value.hasPrefix("cubic-bezier(") } }
        #expect(springFallback, "--ease-spring 要有不认 linear() 时的贝塞尔退路")

        let hiddenScrollbars = rules.filter { rule in
            rule.declarations.contains { $0.property == "scrollbar-width" && $0.value == "none" }
        }
        let missingWebkitScrollbar = hiddenScrollbars.flatMap { rule in
            rule.selector.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { selector in
                !rules.contains { other in
                    other.selector.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "\(selector)::-webkit-scrollbar" }
                        && other.declarations.contains { $0.property == "display" && $0.value == "none" }
                }
            }
        }
        #expect(missingWebkitScrollbar == [], "scrollbar-width: none 的地方要有 ::-webkit-scrollbar { display: none }")
    }

    /// 最里层的每条规则（@supports / @media 里面的也算）：选择器与声明。注释先去掉。
    private static func rules(in source: String, sheet: String) -> [Rule] {
        let css = source.replacing(#/\/\*[\s\S]*?\*\//#, with: "")
        return css.matches(of: #/([^{}]*)\{([^{}]*)\}/#).map { match in
            let selector = match.1.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            let declarations = match.2.split(separator: ";").compactMap { declaration -> (property: String, value: String)? in
                guard let colon = declaration.firstIndex(of: ":") else { return nil }
                let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                return property.isEmpty ? nil : (property, value)
            }
            return Rule(sheet: sheet, selector: selector.trimmingCharacters(in: .whitespaces), declarations: declarations)
        }
    }
}
