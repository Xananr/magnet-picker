import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设计常量（扁平：只用一层底色、1px 分隔线、统一 6pt 圆角）

enum Metrics {
    static let pad: CGFloat = 16
    static let rowHeight: CGFloat = 30
    static let headerHeight: CGFloat = 26
    static let colGap: CGFloat = 8
    static let radius: CGFloat = 6

    static let index: CGFloat = 22
    static let score: CGFloat = 42
    static let seeds: CGFloat = 44
    static let resolution: CGFloat = 50
    static let source: CGFloat = 58
    static let size: CGFloat = 66
}

extension Color {
    static let line = Color(nsColor: .separatorColor)
    static let surface = Color(nsColor: .textBackgroundColor)
    static let subtle = Color.primary.opacity(0.04)
}

// MARK: - 主界面

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var isDropping = false
    @State private var inputExpanded = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    inputStrip
                    hairline
                    filterStrip
                    hairline
                    table
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                }
                if model.showInspector, let item = model.selectedItem {
                    hairline.frame(width: 1, height: nil)
                    InspectorSide(item: item, model: model)
                        .frame(width: 268)
                        .transition(.opacity)
                }
            }
            hairline
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 1040, minHeight: 640)
        .onDrop(of: [UTType.fileURL.identifier, UTType.plainText.identifier], isTargeted: $isDropping) { providers in
            handleDrop(providers)
        }
        .overlay { if isDropping { DropHint() } }
    }

    private var hairline: some View {
        Rectangle().fill(Color.line.opacity(0.55)).frame(height: 1)
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 0) {
                Text("磁力筛选器")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("批量粘贴 · 真实做种数 · 分段优选 · 直送 aria2")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if model.isProbing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(model.progressDone)/\(max(model.progressTotal, 1))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("共 \(model.items.count) 条")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                if model.aliveCount > 0 {
                    Text("有做种 \(model.aliveCount)")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.green)
                }
            }

            flatIcon("slider.horizontal.3", help: "探测参数") { model.showSettings = true }
            flatIcon("trash", help: "清空列表") { model.clearAll() }

            ariaMenu

            if model.isProbing {
                Button("停止") { model.stopProbe() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .frame(width: 62)
            } else {
                Button {
                    model.startProbe()
                } label: {
                    Text("开始探测").font(.system(size: 12, weight: .medium))
                        .frame(width: 74)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(model.items.isEmpty)
            }
        }
        .padding(.horizontal, Metrics.pad)
        .frame(height: 50)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func flatIcon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var ariaMenu: some View {
        Menu {
            Section("发送到 aria2") {
                Button("发送当前选中") { model.sendToAria(.selected) }
                    .disabled(model.selectedItem == nil)
                Button("发送前 5 条") { model.sendToAria(.top(5)) }
                Button("发送全部优选（\(model.recommendedItems.count) 条）") { model.sendToAria(.all) }
            }
            Divider()
            Button("连接设置…") { model.showAriaSettings = true }
            Button("重新检测连接") { Task { await model.checkAria() } }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.ariaVersion == nil ? Color.secondary.opacity(0.5) : Color.green)
                    .frame(width: 6, height: 6)
                Text("Aria")
                    .font(.system(size: 11.5))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.subtle))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(model.ariaBusy)
        .popover(isPresented: $model.showAriaSettings, arrowEdge: .bottom) {
            AriaSettingsView(model: model)
        }
        .popover(isPresented: $model.showSettings, arrowEdge: .bottom) {
            ProbeSettingsView(model: model)
        }
    }

    // MARK: 输入区（扁平、单层）

    private var inputStrip: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.rawInput)
                    .font(.system(size: 11.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .focused($inputFocused)
                if model.rawInput.isEmpty {
                    Text("粘贴 magnet / ed2k，或整页 HTML")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: inputExpanded ? 150 : 52)
            .background(Color.surface)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(inputFocused ? Color.accentColor.opacity(0.6) : Color.line.opacity(0.7), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .animation(.easeInOut(duration: 0.16), value: inputExpanded)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField("网页地址 https://…", text: $model.pageAddress)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11.5))
                        .onSubmit { Task { await model.fetchPage() } }
                    Button {
                        Task { await model.fetchPage() }
                    } label: {
                        if model.isFetchingPage {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("抓取").font(.system(size: 11))
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 46)
                    .disabled(model.isFetchingPage || model.pageAddress.isEmpty)
                }
                HStack(spacing: 6) {
                    Button("导入文件") { model.importFile() }.controlSize(.small).font(.system(size: 11))
                    Button("读剪贴板") { model.pasteFromClipboard() }.controlSize(.small).font(.system(size: 11))
                    Spacer(minLength: 0)
                    Button {
                        inputExpanded.toggle()
                    } label: {
                        Image(systemName: inputExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help(inputExpanded ? "收起粘贴区" : "展开粘贴区")
                }
            }
            .frame(width: 288, alignment: .leading)
            .frame(height: 52, alignment: .top)
        }
        .padding(.horizontal, Metrics.pad)
        .padding(.vertical, 9)
    }

    // MARK: 筛选栏（一条线，无卡片底）

    private var filterStrip: some View {
        HStack(spacing: 9) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("搜片名", text: $model.filters.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .frame(width: 72)
                if !model.filters.search.isEmpty {
                    Button { model.filters.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(Color.surface)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.line.opacity(0.7), lineWidth: 1))
            .fixedSize()

            dropdown(title: "分辨率", current: model.filters.resolutionCap.shortLabel, width: 62,
                     options: ResolutionCap.allCases, label: { $0.shortLabel }) { cap in
                model.filters.resolutionCap = cap
            }

            dropdown(title: "分组", current: model.filters.segment.shortLabel, width: 62,
                     options: SegmentMode.allCases, label: { $0.shortLabel }) { mode in
                model.filters.segment = mode
            }

            Toggle("去枪版", isOn: $model.filters.excludeCam)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .fixedSize()

            HStack(spacing: 4) {
                Text("做种≥")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                TextField("", value: $model.filters.minSeeders, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11).monospacedDigit())
                    .frame(width: 32)
                    .multilineTextAlignment(.center)
            }
            .fixedSize()

            Spacer(minLength: 8)

            Menu {
                Button("复制全部优选（\(model.recommendedItems.count) 条）") { model.copy(scope: .all) }
                Button("复制前 5 条") { model.copy(scope: .top(5)) }
                Button("复制前 10 条") { model.copy(scope: .top(10)) }
                Divider()
                Button("仅复制当前选中") { model.copy(scope: .selectedOnly) }
                    .disabled(model.selectedID == nil)
                Divider()
                Button("复制全部（带标题注释）") { model.copy(scope: .all, withTitles: true) }
            } label: {
                menuLabel("复制")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(model.recommendedItems.isEmpty)

            Menu {
                Button("导出 txt") { model.exportTxt() }
                Button("导出 JSON") { model.exportJSON() }
            } label: {
                menuLabel("导出")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(model.recommendedItems.isEmpty)
        }
        .padding(.horizontal, Metrics.pad)
        .frame(height: 38)
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 11.5))
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 2)
    }

    private func dropdown<Value: Hashable>(
        title: String,
        current: String,
        width: CGFloat,
        options: [Value],
        label: @escaping (Value) -> String,
        onSelect: @escaping (Value) -> Void
    ) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(label(option)) { onSelect(option) }
                }
            } label: {
                HStack(spacing: 0) {
                    Text(current)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 7)
                .padding(.trailing, 18)
                .frame(width: width, height: 24)
                .background(Color.surface)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 6)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.line.opacity(0.7), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .fixedSize()
    }

    // MARK: 表格

    private var table: some View {
        VStack(spacing: 0) {
            if !model.visibleItems.isEmpty {
                tableHeader
                hairline
            }
            if model.visibleItems.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.segments) { segment in
                            if model.filters.segment != .flat, !segment.title.isEmpty {
                                SegmentHeader(segment: segment) { model.copySegment(segment) }
                            }
                            ForEach(Array(segment.items.enumerated()), id: \.element.id) { offset, item in
                                ItemRow(item: item,
                                        ordinal: offset + 1,
                                        isSelected: model.selectedID == item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.selectedID = model.selectedID == item.id ? nil : item.id
                                    }
                                    .contextMenu {
                                        Button("复制这条链接") {
                                            model.selectedID = item.id
                                            model.copy(scope: .selectedOnly)
                                        }
                                        Button("发送这条到 Aria") {
                                            model.selectedID = item.id
                                            model.sendToAria(.selected)
                                        }
                                        Button("只看这个片名") { model.filters.search = item.movieLabel }
                                        Divider()
                                        Button("复制完整文件名") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(item.name, forType: .string)
                                        }
                                    }
                                Rectangle().fill(Color.line.opacity(0.4))
                                    .frame(height: 1)
                                    .padding(.leading, Metrics.pad)
                            }
                            if model.filters.segment != .flat {
                                Color.clear.frame(height: 6)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tableHeader: some View {
        HStack(spacing: Metrics.colGap) {
            cell("#", width: Metrics.index, alignment: .trailing, header: true)
            cell("分数", width: Metrics.score, alignment: .trailing, header: true)
            cell("做种", width: Metrics.seeds, alignment: .trailing, header: true)
            cell("分辨率", width: Metrics.resolution, alignment: .leading, header: true)
            cell("来源", width: Metrics.source, alignment: .leading, header: true)
            cell("体积", width: Metrics.size, alignment: .trailing, header: true)
            Text("版本（文件名去掉片名）")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.pad)
        .frame(height: Metrics.headerHeight)
    }

    private func cell(_ text: String, width: CGFloat, alignment: Alignment, header: Bool) -> some View {
        Text(text)
            .font(.system(size: header ? 10.5 : 11).monospacedDigit())
            .foregroundStyle(header ? Color.secondary : Color.primary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.items.isEmpty ? "把磁力链接粘到上面，或拖入 txt / html 文件" : "当前筛选条件下没有结果")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if model.items.isEmpty {
                Text("也可以填网页地址点「抓取」，自动提取页面里的所有种子")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 状态栏

    private var statusBar: some View {
        HStack(spacing: 10) {
            ProgressTrack(fraction: model.progressTotal > 0
                          ? Double(model.progressDone) / Double(model.progressTotal) : 0,
                          active: model.isProbing)
                .frame(width: 84, height: 2)

            Text(model.statusLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if !model.ariaMessage.isEmpty {
                Text(model.ariaMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(model.ariaVersion == nil ? Color.secondary : Color.green)
                    .lineLimit(1)
            }
            Text("显示 \(model.visibleItems.count) / 共 \(model.items.count) 条")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
            Button(model.showInspector ? "收起详情" : "查看详情") {
                model.showInspector.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .disabled(model.selectedItem == nil)
        }
        .padding(.horizontal, Metrics.pad)
        .frame(height: 28)
    }

    // MARK: 拖拽

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    guard let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in model.loadFile(url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
                    guard let data = data as? Data, let text = String(data: data, encoding: .utf8) else { return }
                    Task { @MainActor in
                        var parsed = LinkParser.extract(from: text)
                        LinkParser.enrichSizes(html: text, items: &parsed)
                        model.mergeIn(parsed)
                    }
                }
            }
        }
        return handled
    }
}

// MARK: - 行

struct ItemRow: View {
    let item: ResultItem
    let ordinal: Int
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Metrics.colGap) {
            Text("\(ordinal)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: Metrics.index, alignment: .trailing)

            Text(item.probed ? Format.score(item.score) : "—")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(scoreColor)
                .frame(width: Metrics.score, alignment: .trailing)

            HStack(spacing: 4) {
                Circle().fill(seedColor).frame(width: 5, height: 5)
                Text(item.seedersText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(item.seeders == nil ? Color.secondary.opacity(0.7) : Color.primary)
            }
            .frame(width: Metrics.seeds, alignment: .trailing)

            Text(item.resolutionLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(item.resolutionLabel == "2160p" ? Color.primary : Color.secondary)
                .frame(width: Metrics.resolution, alignment: .leading)

            Text(item.sourceLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: Metrics.source, alignment: .leading)
                .lineLimit(1)

            Text(item.sizeText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Metrics.size, alignment: .trailing)

            HStack(spacing: 5) {
                if item.kind == .ed2k {
                    Text("ed2k")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text(item.shortVersion)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = item.note {
                    Text(note)
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(noteColor.opacity(0.12)))
                        .foregroundStyle(noteColor)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.pad)
        .frame(height: Metrics.rowHeight)
        .background(background)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(width: 2)
            }
        }
        .onHover { hovering = $0 }
    }

    private var noteColor: Color {
        guard let note = item.note else { return .secondary }
        if note.contains("枪版") { return .red }
        if note.contains("无做种") { return .secondary }
        if note.contains("eD2K") { return .secondary }
        return .orange
    }

    private var seedColor: Color {
        guard let seeds = item.seeders else { return Color.secondary.opacity(0.4) }
        if seeds >= 10 { return .green }
        if seeds >= 3 { return .orange }
        if seeds > 0 { return .red.opacity(0.75) }
        return Color.secondary.opacity(0.4)
    }

    private var scoreColor: Color {
        if item.score >= 85 { return .green }
        if item.score >= 70 { return .accentColor }
        if item.score >= 55 { return .orange }
        return .secondary
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.09) }
        return hovering ? Color.subtle : .clear
    }
}

// MARK: - 分段标题

struct SegmentHeader: View {
    let segment: AppModel.Segment
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(segment.title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
            Text(segment.subtitle)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Button(action: onCopy) {
                Text("复制本段").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.45)
        }
        .padding(.horizontal, Metrics.pad)
        .frame(height: 26)
        .background(Color.subtle)
        .onHover { hovering = $0 }
    }
}

// MARK: - 右侧详情

struct InspectorSide: View {
    let item: ResultItem
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("详情")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { model.showInspector = false } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.movieLabel)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.shortVersion)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    tag(item.resolutionLabel, tint: .accentColor)
                    tag(item.sourceLabel, tint: .secondary)
                    if let codec = item.qualityDetail["编码"] { tag(codec, tint: .secondary) }
                }
                HStack(spacing: 4) {
                    tag(item.audioLabel, tint: .secondary)
                    tag(item.sizeText, tint: .secondary)
                }
            }

            HStack(spacing: 0) {
                stat("综合", Format.score(item.score), color: item.score >= 85 ? .green : .primary)
                stat("可用性", item.availability.map { String(format: "%.0f", $0) } ?? "—", color: .primary)
                stat("质量", String(format: "%.0f", item.quality), color: .primary)
                stat("做种", item.seedersText, color: .primary)
            }
            .padding(.vertical, 6)
            .background(Color.subtle)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            HStack(spacing: 6) {
                Text("TRACKER")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("\(item.trackerOK) 通 / \(item.trackerFail) 断")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(item.trackerHits) { hit in
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: hit.ok ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.system(size: 8))
                                .foregroundStyle(hit.ok ? Color.green : Color.secondary.opacity(0.6))
                                .padding(.top, 1.5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.shortTracker)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(hit.ok ? "做种 \(hit.seeders ?? 0) · 下载 \(hit.leechers ?? 0)" : (hit.message ?? "无响应"))
                                    .font(.system(size: 9).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if item.trackerHits.isEmpty {
                        Text("这条还没有探测结果")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button {
                    model.copy(scope: .selectedOnly)
                } label: {
                    Text("复制").font(.system(size: 11)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    model.sendToAria(.selected)
                } label: {
                    Text("发送到 Aria").font(.system(size: 11)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(item.kind == .ed2k)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(0.12)))
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .fixedSize()
    }

    private func stat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
    }
}

// MARK: - 探测参数

struct ProbeSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("探测参数")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.showSettings = false } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }

            Toggle("DHT 兜底（tracker 全无响应时）", isOn: $model.settings.useDHT)
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            Toggle("补全公共 tracker", isOn: $model.settings.useDefaultTrackers)
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))

            slider("并发数", value: Binding(get: { Double(model.settings.workers) },
                                        set: { model.settings.workers = Int($0) }),
                   range: 4...32, step: 4, text: "\(model.settings.workers)")
            slider("单条超时", value: $model.settings.trackerTimeout,
                   range: 3...10, step: 1, text: "\(Int(model.settings.trackerTimeout))s")
            slider("可用性权重", value: Binding(get: { model.settings.weightAvailability },
                                           set: { model.settings.weightAvailability = $0 }),
                   range: 0.3...0.8, step: 0.05, text: String(format: "%.2f", model.settings.weightAvailability))

            Text("权重越大越看重「下不下得动」，越小越看重片源本身。")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(width: 288)
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, step: Double, text: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 10.5)).frame(width: 62, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(text)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

// MARK: - aria2 连接设置

struct AriaSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft = AriaConfig()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("发送到 aria2")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.showAriaSettings = false } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }

            field("RPC 地址", text: $draft.rpcURL, hint: "http://127.0.0.1:6800/jsonrpc")
            field("RPC 密钥", text: $draft.secret, hint: "aria2 的 --rpc-secret，留空表示不鉴权")
            field("保存目录", text: $draft.savePath, hint: "留空用 aria2 自己的默认目录")

            Text(model.ariaMessage)
                .font(.system(size: 10))
                .foregroundStyle(model.ariaVersion == nil ? Color.secondary : Color.green)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                Button("测试连接") {
                    model.ariaConfig = draft
                    Task { await model.checkAria() }
                }
                .controlSize(.small)
                Button("保存") {
                    model.ariaConfig = draft
                    model.showAriaSettings = false
                    Task { await model.checkAria() }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(13)
        .frame(width: 320)
        .onAppear { draft = model.ariaConfig }
    }

    private func field(_ title: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
            TextField(hint, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}

// MARK: - 小组件

struct ProgressTrack: View {
    let fraction: Double
    let active: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.10))
                Rectangle()
                    .fill(active ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: 2)
    }
}

struct DropHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(.system(size: 22))
            Text("松手导入 txt / html").font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.accentColor.opacity(0.06))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                .padding(8)
        }
        .allowsHitTesting(false)
    }
}
