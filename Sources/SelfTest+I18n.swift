import Cocoa

// P2-15 多语言 的自检。由负责该功能的人填写；不要在 main.swift 里加这部分断言。
// 会临时切换 L10n.override / setting / systemLanguages，结束时全部还原
// （SelfTest.run() 开头把 override 设成了 "zh"，其余套件依赖它）。
extension SelfTest {
    static func i18nChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }
        let saved = (L10n.override, L10n.setting, L10n.systemLanguages)
        defer {
            L10n.override = saved.0
            L10n.setting = saved.1
            L10n.systemLanguages = saved.2
        }

        /// 不合格的条目：英文下仍含中文 / 为空。
        func badEnglish(_ names: [String]) -> [String] {
            names.filter { $0.isEmpty || L10n.containsCJK($0) }
        }
        let devicePages: [PrefPage] = [.normalMouse, .hotCorners]
        let gestureIDs = ["twoKey.left", "twoKey.downRight", "twoKey.key.a", "twoKey.key.<",
                          GlyphLibrary.customPrefix + "1",
                          "corner.topLeft.up", "corner.bottomRight.down",
                          "twoKey.upThenLeft", "twoKey.downThenRight"]
        let builtin = ActionSpec(type: "brightness", keyCode: nil, modifiers: nil, label: nil,
                                 op: "builtin", delta: -0.0625)

        // MARK: 英文
        L10n.override = "en"
        check("i18n: override en", L10n.current == .en && L10n.isEnglish)

        let choices = ActionCatalog.choices
        let badChoices = badEnglish(choices.map(\.title))
        check("i18n: en action names", !choices.isEmpty && badChoices.isEmpty,
              badChoices.prefix(5).joined(separator: ", "))
        let badCats = badEnglish(choices.map(\.category))
        check("i18n: en action categories", badCats.isEmpty, badCats.prefix(5).joined(separator: ", "))
        check("i18n: en action label stays zh",
              choices.first { $0.id == "window/minimize" }.map { $0.spec.label == "窗口最小化" && $0.title == "Minimize Window" } ?? false)
        let allSpecs = Config.defaultConfig.rulesets.values.flatMap { $0.gestures.values } + [builtin]
        let badTitles = badEnglish(allSpecs.map(ActionCatalog.title(for:)))
        check("i18n: en title(for:)", badTitles.isEmpty, badTitles.joined(separator: ", "))
        let noteless = ActionSpec(type: "window", keyCode: nil, modifiers: nil, label: nil, op: "minimize", delta: nil)
        var noted = noteless; noted.note = "我的备注"
        check("i18n: en hud fallback",
              ActionCatalog.hudText(for: noteless) == "Minimize Window"
                && ActionCatalog.hudText(for: ActionSpec(type: "shortcut", keyCode: 1, modifiers: 0, label: nil,
                                                         op: nil, delta: nil)) == "Shortcut")
        check("i18n: en note not translated", ActionCatalog.hudText(for: noted) == "我的备注")
        check("i18n: en brightness names",
              ActionCatalog.title(for: builtin) == "Built-in Brightness Down"
                && ActionCatalog.title(for: Config.defaultConfig.rulesets["default"]!.gestures["corner.bottomLeft.up"]!)
                    == "External Brightness Up")

        var badGestures: [String] = []
        for p in devicePages {
            let opts = RuleDraft.gestureOptions(for: p)
            if opts.isEmpty { badGestures.append("\(p): empty") }
            badGestures += badEnglish(opts.map(\.title)).map { "\(p): \($0)" }
        }
        check("i18n: en gesture options", badGestures.isEmpty, badGestures.prefix(5).joined(separator: ", "))
        let badNames = badEnglish(gestureIDs.map(PrefModel.gestureName))
        check("i18n: en gesture names", badNames.isEmpty, badNames.joined(separator: ", "))
        check("i18n: en gesture wording",
              PrefModel.gestureName("corner.topLeft.up") == "Top-Left Corner Scroll Up"
                && PrefModel.gestureName("twoKey.key.a") == "Right Button + A"
                && PrefModel.gestureName("twoKey.upThenLeft") == "Right Button + Up-Left ↑←",
              PrefModel.gestureName("twoKey.upThenLeft"))
        let badPages = badEnglish(PrefPage.allCases.map(\.title))
        check("i18n: en page titles", badPages.isEmpty && PrefPage.hotCorners.zhTitle == "边角触发",
              badPages.joined(separator: ", "))
        let badValues = L10n.en.filter { L10n.containsCJK($0.value) || $0.value.isEmpty }.map(\.key)
        check("i18n: en table has no Chinese", badValues.isEmpty, badValues.prefix(5).joined(separator: ", "))
        check("i18n: en format",
              L("导入 %d 条规则", 3) == "Import 3 Rules"
                && L("正在等待授权…（每秒自动检测，已等待 %d 秒）", 5).contains("5 s"))
        // 缺译：回退中文（key 用变量，避免被 check-l10n.sh 当成需要翻译的字面量）
        let unknownKey = "自检专用-不存在的文案"
        check("i18n: en missing falls back to zh", L10n.tr(unknownKey) == unknownKey && !L10n.hasEnglish(unknownKey))
        check("i18n: en join", L10n.join("三指", "上滑") == "三指 上滑")

        // MARK: 中文
        L10n.override = "zh"
        check("i18n: zh action names unchanged",
              ActionCatalog.choices.allSatisfy { $0.title == $0.spec.label }
                && ActionCatalog.choices.first { $0.id == "window/minimize" }?.category == "窗口")
        check("i18n: zh title(for:)",
              ActionCatalog.title(for: noteless) == "窗口最小化" && ActionCatalog.title(for: builtin) == "调低内建屏亮度"
                && ActionCatalog.hudText(for: noteless) == "窗口最小化")
        check("i18n: zh gesture names",
              PrefModel.gestureName("corner.topLeft.up") == "左上角滚轮向上"
                && PrefModel.gestureName("twoKey.key.a") == "按住右键 + A"
                && PrefModel.gestureName("twoKey.upThenLeft") == "按住右键 + 上左 ↑←"
                && PrefModel.gestureName(GlyphLibrary.customPrefix + "2") == "按住右键 + 自定义图形 2")
        check("i18n: zh page title", PrefPage.hotCorners.title == "边角触发")
        check("i18n: zh format", L("导入 %d 条规则", 3) == "导入 3 条规则"
                && L("%@（%@）", "a", "b") == "a（b）" && L10n.join("三指", "上滑") == "三指上滑")
        // MARK: 设置值 / 回退 / 跟随系统
        L10n.override = nil
        check("i18n: normalized", L10n.normalized(nil) == "system" && L10n.normalized("system") == "system"
                && L10n.normalized("zh") == "zh" && L10n.normalized("EN") == "en"
                && L10n.normalized("fr") == "system")
        check("i18n: system language",
              L10n.systemLanguage(["zh-Hans-CN", "en-US"]) == .zh && L10n.systemLanguage(["zh-Hant"]) == .zh
                && L10n.systemLanguage(["en-US", "zh-Hans"]) == .en && L10n.systemLanguage(["ja-JP"]) == .en
                && L10n.systemLanguage([]) == .en)
        L10n.systemLanguages = { ["zh-Hans-CN"] }
        L10n.setting = nil
        let sysZh = L10n.current == .zh && L("窗口最小化") == "窗口最小化"
        L10n.setting = "fr"
        let unknownZh = L10n.current == .zh
        L10n.systemLanguages = { ["en-GB"] }
        let sysEn = L10n.current == .en && L("窗口最小化") == "Minimize Window"
        L10n.setting = "system"
        let explicitSystem = L10n.current == .en
        check("i18n: follow system (injected)", sysZh && sysEn && explicitSystem)
        check("i18n: unknown setting → system", unknownZh)
        L10n.setting = "zh"
        let settingZh = L10n.current == .zh
        L10n.override = "en"
        let overrideWins = L10n.current == .en
        L10n.override = nil
        L10n.setting = "en"
        check("i18n: setting zh/en + override wins", settingZh && overrideWins && L10n.current == .en)
        check("i18n: resolve pure",
              L10n.resolve(override: nil, setting: nil, system: ["zh-Hans"]) == .zh
                && L10n.resolve(override: nil, setting: "en", system: ["zh-Hans"]) == .en
                && L10n.resolve(override: "zh", setting: "en", system: ["en"]) == .zh
                && L10n.resolve(override: "bogus", setting: nil, system: ["en"]) == .en)

        // MARK: 配置字段
        let base = Config.defaultConfig
        var withLang = base; withLang.language = "en"
        let roundTrip = (try? JSONEncoder.pretty.encode(withLang))
            .flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
        var oldJSON: Config?
        if let data = try? JSONEncoder.pretty.encode(base),
           var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            obj["language"] = nil
            if let d = try? JSONSerialization.data(withJSONObject: obj) {
                oldJSON = try? JSONDecoder().decode(Config.self, from: d)
            }
        }
        check("i18n: config language field", roundTrip?.language == "en" && base.language == nil
                && oldJSON != nil && oldJSON?.language == nil)
        return out
    }
}
