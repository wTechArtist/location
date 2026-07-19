import SwiftUI
import UniformTypeIdentifiers
import WlocCore

struct ProfileManagementView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFileImporter = false
    @State private var showTextImporter = false
    @State private var showImportPreview = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("导入配置文件", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        model.importedDraft = nil
                        showTextImporter = true
                    } label: {
                        Label("粘贴配置文本", systemImage: "doc.on.clipboard")
                    }
                } footer: {
                    Text("支持文件或粘贴 sing-box JSON 和 Shadowrocket .conf。导入失败不会覆盖当前可用配置，代理凭据保存于共享 Keychain。")
                }

                Section("配置") {
                    if model.profiles.isEmpty {
                        ContentUnavailableView(
                            "尚无代理配置",
                            systemImage: "doc.badge.plus",
                            description: Text("WLOC 不依赖 Shadowrocket；请导入本 App 自己使用的配置。")
                        )
                    }
                    ForEach(model.profiles) { profile in
                        profileRow(profile)
                    }
                }

                Section("系统 VPN") {
                    LabeledContent("状态", value: model.tunnel.state.label)
                    Button("安装/允许 WLOC VPN") {
                        Task {
                            do { try await model.tunnel.installIfNeeded() }
                            catch { model.alert = .init(title: "VPN 安装失败", message: error.localizedDescription) }
                        }
                    }
                    Button(model.tunnel.state == .connected ? "断开 VPN" : "连接 VPN") {
                        Task {
                            do {
                                if model.tunnel.state == .connected { try await model.tunnel.stop() }
                                else { try await model.tunnel.start() }
                            } catch {
                                model.alert = .init(title: "VPN 操作失败", message: error.localizedDescription)
                            }
                        }
                    }
                }

                Section {
                    if let diagnostics = model.tunnelDiagnostics {
                        LabeledContent("会话") {
                            Text(diagnostics.sessionID.uuidString.prefix(8))
                                .font(.system(.caption, design: .monospaced))
                        }
                        LabeledContent("开始") {
                            Text(diagnostics.startedAt, format: .dateTime.year().month().day().hour().minute().second())
                        }
                        if let stoppedAt = diagnostics.stoppedAt {
                            LabeledContent("停止") {
                                Text(stoppedAt, format: .dateTime.year().month().day().hour().minute().second())
                            }
                        }
                        if let lastPatchedAt = diagnostics.lastPatchedAt {
                            LabeledContent("最后补丁") {
                                Text(lastPatchedAt, format: .dateTime.year().month().day().hour().minute().second())
                            }
                        }
                        if let mode = diagnostics.lastTargetMode {
                            LabeledContent("最后模式", value: mode == .override ? "虚拟定位" : "真实定位透传")
                        }
                        LabeledContent("响应次数", value: "\(diagnostics.responseCount)")
                        LabeledContent(
                            "修改计数",
                            value: "定位 \(diagnostics.locations) · Wi-Fi \(diagnostics.wifiMessages) · 基站 \(diagnostics.cellMessages)"
                        )
                    } else {
                        Text("尚无 Packet Tunnel 会话记录。")
                            .foregroundStyle(.secondary)
                    }
                    Button("刷新诊断") { model.refreshTunnelDiagnostics() }
                    Button("生成无凭据诊断文件") { model.prepareDiagnosticsReport() }
                    if let url = model.diagnosticsReportURL {
                        ShareLink(item: url) {
                            Label("分享诊断文件", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("真机诊断")
                } footer: {
                    Text("仅记录隧道状态和 WLOC 补丁计数，不包含节点地址、用户名、密码或配置正文；计数不能替代真实 iPhone 的定位回读与录屏。")
                }

                Section {
                    LabeledContent("设备 CA", value: model.hasDeviceCA ? "已生成" : "未生成")
                    LabeledContent("完全信任确认", value: model.caTrustConfirmed ? "已确认" : "待确认")
                    Button(model.hasDeviceCA ? "重新导出安装描述文件" : "生成安装描述文件") {
                        model.prepareCertificateProfile()
                    }
                    if let url = model.certificateProfileURL {
                        ShareLink(item: url) {
                            Label("分享/存储描述文件", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("我已安装并完全信任") {
                        model.confirmCertificateTrust()
                    }
                    .disabled(!model.hasDeviceCA)
                } header: {
                    Text("WLOC 设备证书")
                } footer: {
                    Text("安装描述文件后，还必须到“设置 > 通用 > 关于本机 > 证书信任设置”手动开启完全信任。App 无法绕过这一步，也无法读取系统信任开关；这里的确认仅用于继续流程，最终以定位回读核验为准。")
                }
            }
            .navigationTitle("代理与 VPN")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onAppear { model.refreshTunnelDiagnostics() }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.json, .plainText, .data, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                model.importedDraft = nil
                model.previewImport(from: url)
                showImportPreview = model.importedDraft != nil
            case let .failure(error):
                model.alert = .init(title: "无法读取文件", message: error.localizedDescription)
            }
        }
        .sheet(isPresented: $showImportPreview, onDismiss: { model.importedDraft = nil }) {
            ImportPreviewView()
        }
        .sheet(
            isPresented: $showTextImporter,
            onDismiss: { showImportPreview = model.importedDraft != nil }
        ) {
            TextConfigurationImportView()
        }
    }

    private func profileRow(_ profile: ProxyProfileMetadata) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name)
                Text("\(profile.format == .shadowrocket ? "Shadowrocket 转换" : "sing-box JSON") · \(ByteCountFormatter.string(fromByteCount: Int64(profile.configurationByteCount), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.activeProfileID == profile.id {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("启用") { Task { await model.activateProfile(profile.id) } }
                    .buttonStyle(.bordered)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive) { Task { await model.deleteProfile(profile.id) } }
                .disabled(model.activeProfileID == profile.id)
        }
    }
}

private struct TextConfigurationImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(8)
                .navigationTitle("粘贴配置")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("解析") {
                            model.previewImport(data: Data(text.utf8), sourceName: "粘贴的配置.txt")
                            if model.importedDraft != nil { dismiss() }
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

private struct ImportPreviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var profileName = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Group {
                if let draft = model.importedDraft {
                    List {
                        Section("配置名称") {
                            TextField("名称", text: $profileName)
                        }
                        Section {
                            LabeledContent("格式", value: draft.format == .shadowrocket ? "Shadowrocket .conf" : "sing-box JSON")
                            LabeledContent("规范化后大小", value: ByteCountFormatter.string(fromByteCount: Int64(draft.configuration.count), countStyle: .file))
                        }
                        Section("兼容性报告") {
                            if draft.issues.isEmpty {
                                Label("未发现兼容性问题", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                            }
                            ForEach(draft.issues) { issue in
                                HStack(alignment: .top) {
                                    Image(systemName: icon(for: issue.severity))
                                        .foregroundStyle(color(for: issue.severity))
                                    VStack(alignment: .leading) {
                                        Text(issue.location).font(.caption).foregroundStyle(.secondary)
                                        Text(issue.message)
                                    }
                                }
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        Button {
                            isSaving = true
                            Task {
                                await model.commitImportedProfile(name: profileName)
                                isSaving = false
                                if model.importedDraft == nil { dismiss() }
                            }
                        } label: {
                            if isSaving { ProgressView().frame(maxWidth: .infinity) }
                            else { Text("校验并启用").frame(maxWidth: .infinity) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.isUsable || isSaving)
                        .padding()
                        .background(.bar)
                    }
                    .onAppear { if profileName.isEmpty { profileName = draft.suggestedName } }
                } else {
                    ContentUnavailableView("没有待导入配置", systemImage: "doc.questionmark")
                }
            }
            .navigationTitle("导入预览")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func icon(for severity: ProfileImportIssue.Severity) -> String {
        switch severity {
        case .information: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func color(for severity: ProfileImportIssue.Severity) -> Color {
        switch severity {
        case .information: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}
