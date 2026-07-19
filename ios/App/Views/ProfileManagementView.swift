import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WlocCore

struct ProfileManagementView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFileImporter = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Shadowrocket", value: model.shadowrocketInstalled ? "已安装" : "未检测到")
                    LabeledContent("模块通信", value: model.moduleStatus)
                    LabeledContent("最近指令", value: model.shadowrocketLastCommand)
                    Button("打开 Shadowrocket") { Task { await model.openShadowrocket() } }
                        .accessibilityIdentifier("wloc.settings.open-shadowrocket")
                    Button("检测 WLOC 模块") {
                        Task { await model.refreshShadowrocketModuleStatus(showErrors: true) }
                    }
                    .accessibilityIdentifier("wloc.settings.detect-module")
                } header: {
                    Text("运行状态")
                } footer: {
                    Text("WLOC 能验证模块通信和定位回读，但 iOS 不允许本 App 读取另一个 App 的实际 VPN 开关，因此这里只显示已发出的指令，不伪报 VPN 已连接。")
                }

                Section {
                    if model.shadowrocketSetupConfirmed {
                        Label("设置已完成", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            Task { await model.installShadowrocketModule() }
                        } label: {
                            Label("1. 一键安装 WLOC 模块", systemImage: "wand.and.stars")
                        }
                        .accessibilityIdentifier("wloc.settings.install-module")
                        Button {
                            Task { await model.refreshShadowrocketModuleStatus(showErrors: true) }
                        } label: {
                            Label("2. 检测并完成设置", systemImage: "checkmark.circle")
                        }
                        .accessibilityIdentifier("wloc.settings.finish-setup")
                    }
                    if let moduleURL = model.moduleFileURL {
                        ShareLink(item: moduleURL) {
                            Label("一键安装失败？手动分享模块", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("首次设置")
                } footer: {
                    Text("先点第 1 步并在 Shadowrocket 中确认安装/启用。按其提示安装 HTTPS 解密证书，并在 iOS“设置 > 通用 > 关于本机 > 证书信任设置”中完全信任；返回后点第 2 步。只有真实取得模块响应才会显示完成，不再使用手动确认开关。")
                }

                Section {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("选择配置文件", systemImage: "doc.badge.plus")
                    }
                    if let configurationURL = model.configurationFileURL {
                        ShareLink(item: configurationURL) {
                            Label("交给 Shadowrocket 打开", systemImage: "square.and.arrow.up")
                        }
                        Text(configurationURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("导入配置")
                } footer: {
                    Text("支持从“文件”选择 .conf、订阅导出或其他 Shadowrocket 可识别文件。WLOC 只把文件安全转交给系统分享面板；最终是否导入成功，以 Shadowrocket 的确认界面为准。")
                }

                Section("手动控制") {
                    Button("发出连接指令") { Task { await model.requestShadowrocketConnect() } }
                    Button("发出断开指令", role: .destructive) {
                        Task { await model.requestShadowrocketDisconnect() }
                    }
                }

                Section {
                    if let verification = model.locationVerification {
                        LabeledContent("定位核验", value: verification.succeeded ? "通过" : "未通过")
                        LabeledContent(
                            "系统回读",
                            value: verification.actualCoordinate.map {
                                String(format: "%.6f, %.6f", $0.latitude, $0.longitude)
                            } ?? "未取得"
                        )
                        if let distance = verification.distanceMeters,
                           let threshold = verification.thresholdMeters {
                            LabeledContent(
                                "距离 / 阈值",
                                value: String(format: "%.0f m / %.0f m", distance, threshold)
                            )
                        }
                    } else {
                        Text("尚无定位切换核验证据。")
                            .foregroundStyle(.secondary)
                    }
                    Button("生成无配置诊断文件") { model.prepareDiagnosticsReport() }
                    if let url = model.diagnosticsReportURL {
                        ShareLink(item: url) {
                            Label("分享诊断文件", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("诊断")
                } footer: {
                    Text("诊断文件不包含代理服务器、用户名、密码或配置正文，也不能替代真实 iPhone 端到端录屏。")
                }
            }
            .navigationTitle("Shadowrocket 设置")
            .accessibilityIdentifier("wloc.settings.screen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .task {
                model.refreshShadowrocketAvailability()
                await model.refreshShadowrocketModuleStatus()
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.json, .plainText, .data, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                model.prepareShadowrocketImport(from: url)
            case let .failure(error):
                model.alert = .init(title: "无法读取文件", message: error.localizedDescription)
            }
        }
    }
}
