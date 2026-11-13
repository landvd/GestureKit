import Cocoa

// 截图衣架：存取与上限、固定、持久化、布局、热区、动作接线（临时文件夹，不碰真实衣架、不弹窗）。
extension SelfTest {
    static func clotheslineChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("gk-clothesline-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }

        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.blue.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let png = Capture.png(ctx.makeImage()!, scale: 2)!
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // MARK: store
        do {
            let s = ClotheslineStore(dir: dir)
            check("line: empty folder → empty line", s.items.isEmpty)
            let first = s.add(png: png, pixelWidth: 64, pixelHeight: 32, scale: 2, date: t0)!
            check("line: hanging writes the PNG", fm.fileExists(atPath: s.url(first).path))
            check("line: point size uses the scale", first.pointSize == CGSize(width: 32, height: 16))
            s.setPinned(first.id, true)
            var ids: [String] = []
            for i in 1...22 {
                ids.append(s.add(png: png, pixelWidth: 64, pixelHeight: 32, scale: 2, date: t0 + Double(i))!.id)
            }
            check("line: keeps the latest 20 (+ pinned)", s.items.count == 21, "\(s.items.count)")
            check("line: the oldest fall off and their files are deleted",
                  !s.items.contains { $0.id == ids[0] || $0.id == ids[1] }
                    && (try? fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.count) == 21)
            check("line: pinned stays even though it is the oldest", s.items.contains { $0.id == first.id })
            let order = s.ordered.map(\.id)
            check("line: pinned hang on the left, then old → new", order.first == first.id && order.last == ids[21]
                  && order[1] == ids[2])

            let reopened = ClotheslineStore(dir: dir)
            check("line: survives a restart", reopened.ordered.map(\.id) == order && reopened.items.first { $0.id == first.id }?.pinned == true)

            s.setPinned(first.id, false)
            check("line: unpinning over the limit drops the oldest (the unpinned one)",
                  s.items.count == 20 && !s.items.contains { $0.id == first.id })

            let victim = s.ordered[3]
            let drag = ClotheslineActions.dragFile(victim, store: s)
            check("line: dragged copy has a readable name in its own folder",
                  drag?.lastPathComponent.hasSuffix(".png") == true && drag?.lastPathComponent.contains(victim.id) == false
                    && drag?.deletingLastPathComponent().lastPathComponent == victim.id,
                  drag?.path ?? "nil")
            check("line: two shots in the same second get different drag files",
                  ClotheslineActions.dragFile(s.ordered[4], store: s) != drag)
            s.remove(victim.id)
            check("line: taking one off deletes its file and drag copy",
                  !fm.fileExists(atPath: s.url(victim).path) && !fm.fileExists(atPath: s.dragDir(victim).path)
                    && s.items.count == 19)

            let thumb = s.thumbnail(s.ordered[0], maxPixels: 40)
            check("line: thumbnails are small", (thumb?.width ?? 999) <= 40, "\(thumb?.width ?? -1)")

            try? fm.removeItem(at: s.url(s.ordered[0]))
            check("line: an entry whose file is gone is dropped on load", ClotheslineStore(dir: dir).items.count == 18)

            // 一键清空（保留固定的）+ 撤销
            s.remove(s.ordered[0].id)           // 上面那条测试故意删了它的文件，先取下
            let keep = s.ordered.last!
            s.setPinned(keep.id, true)
            let before = s.ordered.map(\.id)
            let gone = s.clearUnpinned()
            check("line: one-click clear keeps only pinned shots",
                  s.items.map(\.id) == [keep.id] && gone.count == before.count - 1
                    && fm.fileExists(atPath: s.url(keep).path) && !fm.fileExists(atPath: s.url(gone[0]).path))
            check("line: cleared shots wait in the undo folder",
                  fm.fileExists(atPath: s.undoDir.appendingPathComponent(gone[0].file).path))
            s.restore(gone)
            check("line: undo puts every shot back in order",
                  s.ordered.map(\.id) == before && fm.fileExists(atPath: s.url(gone[0]).path)
                    && !fm.fileExists(atPath: s.undoDir.path))
            let gone2 = s.clearUnpinned()
            s.discardUndo()
            check("line: after the undo window the files are really gone",
                  !fm.fileExists(atPath: s.undoDir.path) && !gone2.isEmpty && s.items.count == 1)
            check("line: clearing with only pinned shots does nothing", s.clearUnpinned().isEmpty && s.items.count == 1)
            _ = s.add(png: png, pixelWidth: 64, pixelHeight: 32, scale: 2, date: t0 + 100)
            _ = s.clearUnpinned()
            check("line: leftovers in the undo folder are deleted on the next launch",
                  fm.fileExists(atPath: s.undoDir.path) && { _ = ClotheslineStore(dir: dir); return !fm.fileExists(atPath: s.undoDir.path) }())

            s.removeAll()
            check("line: clearing removes everything", s.items.isEmpty && ClotheslineStore(dir: dir).items.isEmpty)
        }

        // MARK: layout
        do {
            typealias L = ClotheslineLayout
            check("line: rope ends high, sags in the middle",
                  L.lineY(at: 0, width: 800) == L.lineY && L.lineY(at: 400, width: 800) == L.lineY + L.sag)
            let few = L.frames(aspects: [1.5, 1, 0.5], width: 1000)
            check("line: few cards are centred at full size",
                  few.count == 3 && abs((few[0].minX + few[2].maxX) / 2 - 500) < 1
                    && few.allSatisfy { $0.height <= L.maxCardHeight && $0.width <= L.maxCardWidth })
            check("line: cards do not overlap", zip(few, few.dropFirst()).allSatisfy { $0.maxX + L.gap - 0.01 <= $1.minX })
            check("line: cards hang just below the rope",
                  few.allSatisfy { abs($0.minY - (L.lineY(at: $0.midX, width: 1000) + L.clipDrop)) < 0.01 })
            let many = L.frames(aspects: Array(repeating: 1.6, count: 21), width: 1400)
            check("line: many cards shrink to fit", many.last!.maxX <= 1400 - L.margin + 0.5 && many[0].height < L.maxCardHeight,
                  "\(many.last!.maxX) h=\(many[0].height)")
            check("line: odd shapes are tamed", L.frames(aspects: [20], width: 800)[0].width <= L.maxCardWidth)
            check("line: panel width 60% … 90% of the screen",
                  L.panelWidth(screenWidth: 1920, count: 0) == 1152 && L.panelWidth(screenWidth: 1920, count: 40) == 1728)
            let zone = ClotheslineTrigger.zone(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                               visible: CGRect(x: 0, y: 0, width: 1920, height: 1055))
            check("line: hover zone is the middle of the menu bar",
                  zone == CGRect(x: 880, y: 1055, width: 160, height: 25), "\(zone)")
            let hidden = ClotheslineTrigger.zone(screen: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                                                 visible: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            check("line: auto-hidden menu bar still has a zone", hidden.height == 24 && hidden.midX == 2880)
        }

        // MARK: styles
        do {
            check("style: unknown / missing config → wooden pegs",
                  ClotheslineStyle(config: nil) == .wood && ClotheslineStyle(config: "nope") == .wood
                    && ClotheslineStyle(config: "tape") == .tape)
            let titles = ClotheslineStyle.allCases.map(\.title)
            check("style: 5 styles with distinct names", titles.count == 5 && Set(titles).count == 5)
            let saved = L10n.override
            L10n.override = "en"
            let en = ClotheslineStyle.allCases.map(\.title)
            L10n.override = saved
            check("style: names are translated", Set(en).isDisjoint(with: titles), en.joined(separator: ", "))
            let wire = ClotheslineLayout.frames(aspects: [1, 1, 1], width: 900, sag: ClotheslineStyle.binder.sag)
            check("style: binder wire is straight", Set(wire.map(\.minY)).count == 1
                  && ClotheslineLayout.lineY(at: 450, width: 900, sag: 0) == ClotheslineLayout.lineY)
            check("style: polaroid cards are taller than the photo",
                  ClotheslineStyle.polaroid.outerAspect(1.5) < 1.5 && ClotheslineStyle.tape.outerAspect(1.5) == 1.5)
            check("style: candy colours are stable per shot",
                  ClotheslineStyle.candyIndex("abc") == ClotheslineStyle.candyIndex("abc")
                    && (0..<ClotheslineStyle.candy.count).contains(ClotheslineStyle.candyIndex("xyz")))
            let item = ClotheslineStore.Item(id: "id-1", file: "x.png", created: Date(), pinned: false,
                                             pixelWidth: 100, pixelHeight: 60, scale: 1)
            for st in ClotheslineStyle.allCases {
                let f = CALayer()
                ClotheslineCard.drawFastener(f, style: st, item: item, cardSize: CGSize(width: 100, height: 60))
                ClotheslineCard.drawFastener(f, style: st, item: item, cardSize: CGSize(width: 100, height: 60))
                let tops = (f.sublayers ?? []).map { $0.frame.maxY }
                let reaches = (f.sublayers ?? []).contains { $0.frame.maxY >= 60 + ClotheslineLayout.clipDrop - 1 }
                    || (f.sublayers ?? []).contains { ($0 as? CAShapeLayer)?.path?.boundingBox.maxY ?? 0 >= 60 + ClotheslineLayout.clipDrop - 1 }
                check("style: \(st.rawValue) fastener reaches the line and redraws cleanly",
                      !(f.sublayers ?? []).isEmpty && (f.sublayers ?? []).count <= 2 && reaches, "\(tops)")
            }
            var cfg = Config.defaultConfig
            cfg.clotheslineStyle = "polaroid"
            let back = (try? JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg)))?.clotheslineStyle
            check("style: choice survives a save", back == "polaroid")
        }

        // MARK: wiring
        do {
            let savedDry = Actions.dryRun, savedObserver = Actions.observer, savedPresenter = Actions.presenter
            Actions.dryRun = false; Actions.observer = nil; Actions.presenter = nil
            let fx = RecordingActionEffects()
            let actions = Actions()
            actions.effects = fx
            actions.perform(ActionSpec(type: "system", keyCode: nil, modifiers: nil, label: nil, op: "toggleClothesline", delta: nil))
            Actions.dryRun = savedDry; Actions.observer = savedObserver; Actions.presenter = savedPresenter
            let posted: Bool = { if case .notification(let n)? = fx.calls.first { return n == ClotheslineController.toggleNotification }; return false }()
            check("line: the 显示/隐藏截图衣架 action toggles the line", posted)
            check("line: ⌃⌥T", ClotheslineController.hotkeyKeyCode == 17)
            var cfg = Config.defaultConfig
            check("line: on by default", cfg.clotheslineEnabled ?? true)
            cfg.clotheslineEnabled = false
            let back = (try? JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg)))?.clotheslineEnabled
            check("line: turning it off survives a save", back == false)
        }
        return out
    }
}
