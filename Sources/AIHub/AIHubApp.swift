import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var cleanup: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { cleanup?() }
}

@main
struct AIHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        Window("AIHub", id: "main") {
            RootView(state: state)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { delegate.cleanup = { state.shutdown() } }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("听写") {
                Button("开始 / 停止录音") {
                    if state.recorder.isRecording { state.stopRecording() }
                    else { state.startRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.isProcessing || state.isStartingRecording)
                Button("导入音频…") { state.importAudio() }
                    .keyboardShortcut("o", modifiers: [.command])
                    .disabled(state.locked)
                Button("转为文字") { state.transcribe() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(state.locked || !state.hasAudio)
                Button("识别并润色") { state.transcribe(polish: true) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(state.locked || !state.hasAudio || state.settings.speechSelection == nil || state.settings.chatSelection == nil)
            }
        }
    }
}
