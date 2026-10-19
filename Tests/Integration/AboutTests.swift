import Foundation

/// The two addresses About hands to the browser. The app opens nothing else.
@MainActor
func runAboutLinkTests() {
    expect("about: Report a problem goes to the issues", AppInfo.issuesURL.absoluteString,
           "https://github.com/colletpedro/keepnote/issues")
    expect("about: Check for Updates goes to the site", AppInfo.siteURL.absoluteString,
           "https://colletpedro.github.io/keepnote/")
}
