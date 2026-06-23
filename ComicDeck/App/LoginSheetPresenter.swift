import SwiftUI

@MainActor
struct LoginSheetPresenter: View {
    @Bindable var login: LoginViewModel
    let appDebugLog: (String) -> Void

    var body: some View {
        Color.clear
            .sheet(isPresented: $login.showLogin) {
                LoginWebView(
                    url: login.validatedLoginURL(),
                    onCookieCaptured: { login.onLoginCookieCaptured() },
                    onPageChanged: { url, title in
                        login.onWebLoginPageChanged(url: url, title: title)
                    }
                )
#if os(macOS)
                .frame(
                    minWidth: 900,
                    idealWidth: 980,
                    minHeight: 640,
                    idealHeight: 760
                )
#endif
                .onAppear {
                    appDebugLog("LoginWebView sheet onAppear, url=\(login.validatedLoginURL().absoluteString)")
                }
                .onDisappear {
                    appDebugLog("LoginWebView sheet onDisappear")
                }
            }
    }
}
