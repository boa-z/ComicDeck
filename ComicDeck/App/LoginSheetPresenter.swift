import SwiftUI

@MainActor
struct LoginSheetPresenter: View {
    @Bindable var login: LoginViewModel
    let appDebugLog: (String) -> Void

    var body: some View {
        Color.clear
            .sheet(isPresented: $login.showLogin) {
                Group {
#if os(macOS)
                    MacLoginWebViewContainer(
                        url: login.validatedLoginURL(),
                        onClose: { login.showLogin = false },
                        onCookieCaptured: { login.onLoginCookieCaptured() },
                        onPageChanged: { url, title in
                            login.onWebLoginPageChanged(url: url, title: title)
                        }
                    )
#else
                    LoginWebView(
                        url: login.validatedLoginURL(),
                        onCookieCaptured: { login.onLoginCookieCaptured() },
                        onPageChanged: { url, title in
                            login.onWebLoginPageChanged(url: url, title: title)
                        }
                    )
#endif
                }
                .onAppear {
                    appDebugLog("LoginWebView sheet onAppear, url=\(login.validatedLoginURL().absoluteString)")
                }
                .onDisappear {
                    appDebugLog("LoginWebView sheet onDisappear")
                }
            }
    }
}
