//
//  ContentView.swift
//  LotteryApp
//
//  Created by adam li on 2026/4/21.
//  modify on 2026/4/26

import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Models (模型层)

/// 参与抽签人员模型
struct Person: Identifiable, Equatable, Hashable {
    let id = UUID()
    let groupName: String
    let companyName: String
    let name: String
    let userType: String // 新增：用户类型 (如 AE, SE)
    
    /// 用于校验重复数据的唯一键 (组名-公司名-姓名-用户类型)
    var uniqueKey: String {
        return "\(groupName)-\(companyName)-\(name)-\(userType)"
    }
    
    /// 用于界面展示的名字（如果是两个字，中间加一个全角空格以便与三个字对齐，防止动画时标签跳跃）
    var displayName: String {
        // 去除可能的首尾多余空格后判断长度
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName.count == 2 {
            // 使用全角空格（U+3000）将两个字隔开，宽度正好等于一个汉字
            return trimmedName.map { String($0) }.joined(separator: "　")
        }
        return trimmedName
    }
}

/// 抽签历史记录模型
struct DrawRecord: Identifiable, Equatable {
    let id = UUID()
    let person: Person
    let drawTime: Date
}

/// 用于导出历史记录的 CSV 文件格式配置
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    var text: String
    
    init(text: String = "") {
        self.text = text
    }
    
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let str = String(data: data, encoding: .utf8) {
            text = str
        } else {
            text = ""
        }
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - ViewModel (视图模型层)

/// 处理抽签逻辑、数据读取及验证
@MainActor
class LotteryViewModel: ObservableObject {
    /// 抽签全部数据池
    @Published var dataPool: [Person] = []
    
    /// 历史抽签记录 (按抽签时间倒序排列)
    @Published var history: [DrawRecord] = []
    
    /// 是否正在进行抽签动画
    @Published var isDrawing: Bool = false
    /// 当前滚动展示的中签人员列表
    @Published var rollingWinners: [Person] = []
    
    // MARK: 抽签设置
    
    /// 是否允许重复中签（即中签后是否放回数据池）
    @Published var allowRepeat: Bool = false
    /// 单次批量抽签的人数 (1-20)
    @Published var drawCount: Int = 1
    
    /// 默认固定提供 全部、AE、SE 选项，后续可根据表格动态追加
    @Published var availableUserTypes: [String] = ["全部", "AE", "SE"]
    /// 当前选择抽签的用户类型范围
    @Published var selectedUserType: String = "全部"
    
    // MARK: 提示信息控制
    
    @Published var showMessage: Bool = false
    @Published var messageTitle: String = ""
    @Published var messageBody: String = ""
    
    /// 动画异步任务
    private var drawTask: Task<Void, Never>?
    
    // MARK: - 数据读取与处理逻辑
    
    /// 处理导入的文件 URL
    func handleImportedFile(url: URL) {
        // 请求安全范围资源访问权限（适用于 macOS 沙盒）
        guard url.startAccessingSecurityScopedResource() else {
            showError(title: "无法访问文件", message: "没有权限读取选中的文件。")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        do {
            let data = try Data(contentsOf: url)
            // 尝试使用 UTF-8 解析 CSV
            guard let content = String(data: data, encoding: .utf8) else {
                showError(title: "读取失败", message: "文件编码不是 UTF-8，无法解析。请将 CSV 文件另存为 UTF-8 编码格式。")
                return
            }
            processCSV(content: content)
        } catch {
            showError(title: "读取失败", message: "无法读取文件：\(error.localizedDescription)")
        }
    }
    
    /// 解析 CSV 内容并更新数据池
    private func processCSV(content: String) {
        let rows = parseCSVContent(content)
        guard let headers = rows.first else {
            showError(title: "数据错误", message: "导入的表格为空。")
            return
        }
        
        // 去除空格及可能存在的 BOM (Byte Order Mark)
        var normalizedHeaders = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !normalizedHeaders.isEmpty && normalizedHeaders[0].hasPrefix("\u{FEFF}") {
            normalizedHeaders[0] = String(normalizedHeaders[0].dropFirst())
        }
        
        // 自动识别对应的列索引，包含新增的“用户类型”
        guard let groupIdx = normalizedHeaders.firstIndex(of: "组名"),
              let companyIdx = normalizedHeaders.firstIndex(of: "公司名"),
              let nameIdx = normalizedHeaders.firstIndex(of: "姓名"),
              let typeIdx = normalizedHeaders.firstIndex(of: "用户类型") else {
            showError(title: "列名不匹配", message: "无法识别“组名”、“公司名”、“姓名”、“用户类型”四列。当前表头为：\(normalizedHeaders.joined(separator: ", "))\n请修改表格列名后重试。")
            return
        }
        
        var newPool: [Person] = []
        var uniqueKeys: Set<String> = []
        var typeSet: Set<String> = [] // 用于收集所有的用户类型
        var validCount = 0
        var invalidCount = 0
        
        // 遍历数据行（跳过表头）
        for i in 1..<rows.count {
            let row = rows[i]
            let maxIdx = max(groupIdx, max(companyIdx, max(nameIdx, typeIdx)))
            
            // 数据校验：行数据不完整，跳过
            if row.count <= maxIdx {
                invalidCount += 1
                continue
            }
            
            let group = row[groupIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            let company = row[companyIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = row[nameIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            let userType = row[typeIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            
            // 数据校验：过滤空值
            if group.isEmpty || company.isEmpty || name.isEmpty || userType.isEmpty {
                invalidCount += 1
                continue
            }
            
            let person = Person(groupName: group, companyName: company, name: name, userType: userType)
            
            // 数据校验：过滤重复数据
            if uniqueKeys.contains(person.uniqueKey) {
                invalidCount += 1
                continue
            }
            
            uniqueKeys.insert(person.uniqueKey)
            typeSet.insert(userType)
            newPool.append(person)
            validCount += 1
        }
        
        if validCount > 0 {
            // 支持重新导入表格覆盖原数据池
            self.dataPool = newPool
            
            // 确保固定的选项始终在最前面，动态识别出来的其他新类型排在后面
            var baseTypes = ["全部", "AE", "SE"]
            let dynamicTypes = typeSet.filter { !baseTypes.contains($0) }.sorted()
            baseTypes.append(contentsOf: dynamicTypes)
            
            self.availableUserTypes = baseTypes
            self.selectedUserType = "全部"
            showSuccess(title: "导入成功", message: "共导入 \(validCount) 条有效数据，过滤 \(invalidCount) 条无效（空值或重复）数据。")
        } else {
            showError(title: "导入失败", message: "表格中没有检测到有效数据（共过滤 \(invalidCount) 条）。")
        }
    }
    
    /// 简易 CSV 文本解析器，处理包含逗号和引号的单元格格式
    private func parseCSVContent(_ string: String) -> [[String]] {
        var result: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var insideQuotes = false
        
        for char in string {
            if char == "\"" {
                insideQuotes.toggle()
            } else if char == "," && !insideQuotes {
                currentRow.append(currentField)
                currentField = ""
            } else if (char == "\n" || char == "\r\n") && !insideQuotes {
                if currentField.hasSuffix("\r") { currentField.removeLast() }
                currentRow.append(currentField)
                result.append(currentRow)
                currentRow = []
                currentField = ""
            } else if char == "\r" && !insideQuotes {
                // 跳过单独的 \r
            } else {
                currentField.append(char)
            }
        }
        
        if !currentField.isEmpty || !currentRow.isEmpty {
            if currentField.hasSuffix("\r") { currentField.removeLast() }
            currentRow.append(currentField)
            result.append(currentRow)
        }
        
        // 过滤空行
        return result.filter { row in row.contains(where: { !$0.isEmpty }) }
    }
    
    // MARK: - 抽签核心逻辑
    
    /// 触发抽签/停止抽签状态
    func toggleDraw() {
        if isDrawing {
            stopDraw()
        } else {
            startDraw()
        }
    }
    
    /// 开始抽签：进行合法性检查并启动快速滚动动画
    private func startDraw() {
        // 先获取符合当前“用户类型”筛选条件的人员名单
        let filteredPool = selectedUserType == "全部" ? dataPool : dataPool.filter { $0.userType == selectedUserType }
        
        guard !filteredPool.isEmpty else {
            if dataPool.isEmpty {
                showError(title: "无法抽签", message: "当前数据池为空，请先导入数据表格。")
            } else {
                showError(title: "无法抽签", message: "当前筛选条件“\(selectedUserType)”下无匹配人员。")
            }
            return
        }
        
        if !allowRepeat && filteredPool.count < drawCount {
            showError(title: "无法抽签", message: "不可重复抽签模式下，当前分类剩余人数（\(filteredPool.count)）不足以抽取 \(drawCount) 人。")
            return
        }
        
        isDrawing = true
        rollingWinners = []
        
        // 使用 Swift 并发替代 Timer 以解决捕获报错并提升性能
        drawTask = Task {
            while !Task.isCancelled {
                self.rollingWinners = self.getRandomPeople(count: self.drawCount)
                // 暂停 0.08 秒 (80,000,000 纳秒)
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }
    
    /// 停止抽签：停止动画并确定最终中签名单
    private func stopDraw() {
        drawTask?.cancel()
        drawTask = nil
        
        // 1. 抽取真正的中签者并定格显示
        let finalWinners = getRandomPeople(count: drawCount)
        rollingWinners = finalWinners
        
        let now = Date()
        for winner in finalWinners {
            // 2. 自动记录到历史列表头部（倒序）
            let record = DrawRecord(person: winner, drawTime: now)
            history.insert(record, at: 0)
            
            // 3. 如果不可重复中签（不放回），从总数据池中移除中签者
            if !allowRepeat {
                if let idx = dataPool.firstIndex(where: { $0.id == winner.id }) {
                    dataPool.remove(at: idx)
                }
            }
        }
        
        isDrawing = false
    }
    
    /// 随机抽取算法逻辑：确保概率均等且单次批量不重复
    private func getRandomPeople(count: Int) -> [Person] {
        // 从筛选后的名单中抽取
        let filteredPool = selectedUserType == "全部" ? dataPool : dataPool.filter { $0.userType == selectedUserType }
        guard !filteredPool.isEmpty else { return [] }
        
        var tempPool = filteredPool
        var result: [Person] = []
        
        for _ in 0..<count {
            if tempPool.isEmpty { break }
            let randomIndex = Int.random(in: 0..<tempPool.count)
            result.append(tempPool[randomIndex])
            // 在同一批次抽签内不应抽出同一个人两次
            tempPool.remove(at: randomIndex)
        }
        return result
    }
    
    // MARK: - 历史记录管理
    
    /// 清空所有历史中签记录
    func clearHistory() {
        history.removeAll()
    }
    
    /// 将历史记录转换为适合导出的 CSV 文本
    func exportCSVText() -> String {
        var text = "序号,用户类型,组名,公司名,姓名,抽签时间\n"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        
        for (index, record) in history.enumerated() {
            let timeString = formatter.string(from: record.drawTime)
            // 使用引号包裹防止数据中出现逗号导致错位
            let uType = "\"\(record.person.userType)\""
            let group = "\"\(record.person.groupName)\""
            let company = "\"\(record.person.companyName)\""
            // 导出时仍然使用无空格的原始名字
            let name = "\"\(record.person.name)\""
            let displayIndex = history.count - index
            
            text += "\(displayIndex),\(uType),\(group),\(company),\(name),\(timeString)\n"
        }
        return text
    }
    
    // MARK: - 辅助方法
    
    func showError(title: String, message: String) {
        messageTitle = title
        messageBody = message
        showMessage = true
    }
    
    func showSuccess(title: String, message: String) {
        messageTitle = title
        messageBody = message
        showMessage = true
    }
}

// MARK: - Views (视图层)

struct ContentView: View {
    @StateObject private var viewModel = LotteryViewModel()
    @State private var showFileImporter = false
    @State private var showFileExporter = false
    @State private var showClearConfirm = false
    
    var body: some View {
        HStack(spacing: 0) {
            // 核心功能与抽签展示区
            VStack(spacing: 20) {
                headerView
                Divider()
                drawAreaView
                Divider()
                controlsView
            }
            .padding(24)
            .frame(minWidth: 500, maxWidth: .infinity, minHeight: 450, maxHeight: .infinity)
            
            Divider()
            
            // 历史抽签记录展示区
            historyView
        }
        // 全局弹窗交互反馈
        .alert(viewModel.messageTitle, isPresented: $viewModel.showMessage) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(viewModel.messageBody)
        }
        // 清空历史记录二次确认
        .confirmationDialog("确认清空历史记录？", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) {
                viewModel.clearHistory()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("清空后数据将无法恢复，确定要继续吗？")
        }
        // Excel/CSV 导入弹窗
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    viewModel.handleImportedFile(url: url)
                }
            case .failure(let error):
                viewModel.showError(title: "导入失败", message: error.localizedDescription)
            }
        }
        // 历史记录导出弹窗
        .fileExporter(
            isPresented: $showFileExporter,
            document: CSVDocument(text: viewModel.exportCSVText()),
            contentType: .commaSeparatedText,
            defaultFilename: "历史抽签记录"
        ) { result in
            switch result {
            case .success:
                break // 导出成功视情况可在此弹窗提示
            case .failure(let error):
                viewModel.showError(title: "导出失败", message: error.localizedDescription)
            }
        }
    }
    
    /// 顶部标题及导入入口区域
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("AIonMac抽签系统")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                // 动态展示当前选择类别下的人数与总人数
                let filteredCount = viewModel.selectedUserType == "全部" ? viewModel.dataPool.count : viewModel.dataPool.filter { $0.userType == viewModel.selectedUserType }.count
                Text("当前候选人数：\(filteredCount) 人 (总有效池: \(viewModel.dataPool.count) 人)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button {
                showFileImporter = true
            } label: {
                Label("导入数据 (CSV)", systemImage: "doc.badge.plus")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isDrawing)
        }
    }
    
    /// 智能阵型算法：根据总人数，分配每一行应该放几张卡片（实现绝佳的对称感）
    private func getRowCounts(for total: Int) -> [Int] {
        switch total {
        case 1: return [1]
        case 2: return [2]
        case 3: return [1, 2]
        case 4: return [2, 2]
        case 5: return [2, 3]
        case 6: return [3, 3]
        case 7: return [3, 4]
        case 8: return [4, 4]
        case 9: return [3, 3, 3]
        case 10: return [3, 3, 4]
        case 11: return [3, 4, 4]
        case 12: return [4, 4, 4]
        case 13: return [4, 4, 5]
        case 14: return [4, 5, 5]
        case 15: return [5, 5, 5]
        case 16: return [4, 4, 4, 4]
        case 17: return [4, 4, 4, 5]
        case 18: return [4, 4, 5, 5]
        case 19: return [4, 5, 5, 5]
        case 20: return [5, 5, 5, 5]
        default:
            // 超过 20 人的回退方案（动态分配最多 5 列）
            var counts: [Int] = []
            var remaining = total
            while remaining > 0 {
                let take = min(remaining, 5)
                counts.append(take)
                remaining -= take
            }
            return counts
        }
    }
    
    /// 根据分配的行数，将一维的人员数组切分成二维数组用于嵌套 HStack 渲染
    private func getChunkedWinners(winners: [Person], rowCounts: [Int]) -> [[Person]] {
        var chunks: [[Person]] = []
        var index = 0
        for rc in rowCounts {
            if index >= winners.count { break }
            let endIndex = min(index + rc, winners.count)
            chunks.append(Array(winners[index..<endIndex]))
            index = endIndex
        }
        return chunks
    }
    
    /// 核心抽签动画及结果展示区
    private var drawAreaView: some View {
        VStack {
            if viewModel.rollingWinners.isEmpty && !viewModel.isDrawing {
                // 默认/空闲占位状态
                Spacer() // 顶部推力
                VStack(spacing: 12) {
                    Image(systemName: "gift.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.gray.opacity(0.5))
                    Text(viewModel.dataPool.isEmpty ? "请先导入表格数据以开始抽签" : "准备就绪，点击下方按钮开始抽签")
                        .font(.title2)
                        .foregroundColor(.gray)
                }
                .padding(40)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
                .cornerRadius(16)
                Spacer() // 底部推力，使其垂直居中
                
            } else {
                Spacer() // 顶部推力
                
                let winners = viewModel.rollingWinners
                let count = winners.count
                
                // 1. 根据当前人数获取最佳行列分布
                let rowCounts = getRowCounts(for: count)
                // 2. 将数据切分为完美匹配的行
                let chunks = getChunkedWinners(winners: winners, rowCounts: rowCounts)
                
                // 3. 动态渲染网格。彻底抛弃绝对坐标堆叠，回归精美方阵。
                VStack(spacing: 16) {
                    ForEach(Array(chunks.enumerated()), id: \.offset) { rowIndex, chunk in
                        HStack(spacing: 16) {
                            ForEach(chunk, id: \.id) { person in
                                winnerCard(for: person)
                            }
                        }
                    }
                }
                // 智能调整最大宽度：如果一行多达5人（如15人、20人时），将容器放宽，完美利用整个宽屏。
                .frame(maxWidth: count >= 13 ? 1600 : (count >= 9 ? 1200 : 1000))
                .padding()
                
                Spacer() // 底部推力
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // 整个展示区撑满屏幕
        .animation(.default, value: viewModel.rollingWinners)
    }
    
    /// 抽签动画区 - 人员信息卡片
    private func winnerCard(for person: Person) -> some View {
        // 使用当前正在展示的人数，确保动画和实际显示匹配
        let count = viewModel.rollingWinners.count
        
        let isSingle = count == 1
        let isSmall = count >= 2 && count <= 4
        let isMedium = count >= 5 && count <= 8
        let isLarge = count >= 9 && count <= 12
        let isXLarge = count >= 13 // 13-20人档位
        
        // 动态分配字体及间距大小，人数越多字体越小，确保 20 人同屏也能完美放下
        let nameSize: CGFloat = isSingle ? 80 : (isSmall ? 56 : (isMedium ? 44 : (isLarge ? 32 : 24)))
        let typeSize: CGFloat = isSingle ? 28 : (isSmall ? 20 : (isMedium ? 16 : (isLarge ? 12 : 10)))
        let companySize: CGFloat = isSingle ? 32 : (isSmall ? 24 : (isMedium ? 20 : (isLarge ? 16 : 12)))
        let groupSize: CGFloat = isSingle ? 28 : (isSmall ? 20 : (isMedium ? 16 : (isLarge ? 14 : 11)))
        let cardPadding: CGFloat = isSingle ? 40 : (isSmall ? 28 : (isMedium ? 24 : (isLarge ? 16 : 12)))
        let minHeight: CGFloat = isSingle ? 200 : (isSmall ? 150 : (isMedium ? 120 : (isLarge ? 90 : 70)))
        
        return VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                // 使用带有全角空格格式化的 displayName 以对齐界面
                Text(person.displayName)
                    .font(.system(size: nameSize, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                
                // 展示用户类型 Badge
                Text(person.userType)
                    .font(.system(size: typeSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, isSingle ? 16 : (isMedium ? 12 : 8))
                    .padding(.vertical, isSingle ? 8 : (isMedium ? 6 : 4))
                    .background(Color.blue.opacity(0.8))
                    .cornerRadius(8)
            }
            
            Text(person.companyName)
                .font(.system(size: companySize))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            
            Text(person.groupName)
                .font(.system(size: groupSize))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(cardPadding)
        // 允许卡片撑满网格的自适应宽度
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.accentColor.opacity(0.1))
        )
        // 抽签过程中提供边界闪烁反馈
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.accentColor.opacity(viewModel.isDrawing ? 0.5 : 1.0), lineWidth: viewModel.isDrawing ? 2 : 4)
        )
    }
    
    /// 底部操作控制区（批量控制与抽取开关）
    private var controlsView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 32) {
                // 抽签范围过滤选取
                Picker("抽签范围", selection: $viewModel.selectedUserType) {
                    ForEach(viewModel.availableUserTypes, id: \.self) { type in
                        Text(type).tag(type)
                    }
                }
                .frame(maxWidth: 160)
                .disabled(viewModel.isDrawing)
                
                Toggle("允许重复中签", isOn: $viewModel.allowRepeat)
                    .disabled(viewModel.isDrawing)
                
                Stepper(value: $viewModel.drawCount, in: 1...20) {
                    Text("单次抽取: \(viewModel.drawCount) 人")
                }
                .disabled(viewModel.isDrawing)
            }
            
            Button {
                viewModel.toggleDraw()
            } label: {
                Text(viewModel.isDrawing ? "停止抽签" : "开始抽签")
                    .font(.title)
                    .fontWeight(.bold)
                    .frame(width: 240, height: 60)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isDrawing ? .red : .blue)
            // 按钮点击反馈过渡效果
            .scaleEffect(viewModel.isDrawing ? 0.98 : 1.0)
            .animation(.easeInOut, value: viewModel.isDrawing)
        }
    }
    
    /// 右侧独立管理视图：历史抽签记录
    private var historyView: some View {
        VStack(spacing: 0) {
            Text("历史抽签记录 (\(viewModel.history.count))")
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            List {
                ForEach(Array(viewModel.history.enumerated()), id: \.element.id) { index, record in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(viewModel.history.count - index).")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text(record.person.displayName)
                                .font(.headline)
                            
                            // 历史记录也展示用户类型标签
                            Text(record.person.userType)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.2))
                                .cornerRadius(4)
                        }
                        Text("\(record.person.groupName) - \(record.person.companyName)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(record.drawTime, style: .time)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.sidebar)
            
            Divider()
            
            HStack {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Text("清空")
                }
                .disabled(viewModel.history.isEmpty)
                
                Spacer()
                
                Button {
                    showFileExporter = true
                } label: {
                    Text("导出为 CSV")
                }
                .disabled(viewModel.history.isEmpty)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 280)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

#Preview {
    ContentView()
}
