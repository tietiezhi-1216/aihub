import SwiftUI

struct RootView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView {
            List(AppPage.allCases, selection: Binding<AppPage?>(
                get: { state.page },
                set: { if let page = $0 { state.page = page } }
            )) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("AIHub")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            Group {
                switch state.page {
                case .dictation: DictationView(state: state)
                case .providers: ProvidersView(state: state)
                case .permissions: PermissionsView(state: state)
                case .usage: UsageView(state: state)
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle(state.page.title)
            .safeAreaInset(edge: .bottom) {
                if let notice = state.notice {
                    HStack {
                        Text(notice).foregroundStyle(.secondary)
                        Spacer()
                        Button("关闭") { state.notice = nil }
                    }
                    .font(.footnote)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
        }
        .alert("错误", isPresented: Binding(
            get: { state.error != nil },
            set: { if !$0 { state.error = nil } }
        )) {
            Button("好", role: .cancel) { state.error = nil }
        } message: {
            Text(state.error ?? "")
        }
    }
}
