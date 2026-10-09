import AppKit
import AVFoundation
import SwiftUI

struct PermissionsView: View {
    let state: AppState
    @State private var microphone = Recorder.permission
    @State private var requesting = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("麦克风") {
                LabeledContent("权限", value: microphoneLabel)
                HStack {
                    if microphone == .notDetermined {
                        Button("请求权限") { requestMicrophone() }.disabled(requesting)
                    }
                    Button("系统设置…") { openPrivacySettings() }
                    Button("刷新") { microphone = Recorder.permission }
                    if requesting { ProgressView().controlSize(.small) }
                }
            }
            Section("供应商") {
                LabeledContent("API Key", value: "系统钥匙串")
                Button("管理供应商") { state.page = .providers }
            }
        }
        .formStyle(.grouped)
        .onAppear { microphone = Recorder.permission }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { microphone = Recorder.permission }
        }
    }

    private var microphoneLabel: String {
        switch microphone {
        case .authorized: "已授权"
        case .denied: "已拒绝"
        case .restricted: "受系统限制"
        case .notDetermined: "未申请"
        @unknown default: "未知"
        }
    }

    private func requestMicrophone() {
        requesting = true
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphone = Recorder.permission
            requesting = false
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
