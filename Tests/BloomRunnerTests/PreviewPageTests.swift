import Foundation
import Testing
@testable import BloomRunner

@Suite("The pages the preview draws itself")
struct PreviewPageTests {
    @Test("a service's name and message are escaped, because the project and its processes wrote them")
    func escapesWhatTheProjectSupplies() {
        let html = PreviewPage.unavailable(advice: [], services: [
            .init(name: "<script>alert(1)</script>", state: "crashed", restarts: 0, message: "failed at \"<img src=x>\" & quit"),
        ])
        #expect(!html.contains("<script>alert(1)</script>"))
        #expect(!html.contains("<img src=x>"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(html.contains("failed at &quot;&lt;img src=x&gt;&quot; &amp; quit"))
    }

    @Test("a state the page does not know is drawn as busy, and never reaches the markup as a class")
    func unknownStateIsAClassNameOfOurs() {
        let html = PreviewPage.unavailable(advice: [], services: [.init(name: "web", state: "x\" onclick=\"y", restarts: 0)])
        #expect(html.contains("class=\"state busy\""))
        #expect(!html.contains("onclick=\"y"))
    }

    @Test("the empty preview asks again by itself, and the refused one does not")
    func onlyTheEmptyPreviewRefreshes() {
        #expect(PreviewPage.unavailable(advice: [], services: nil).contains("http-equiv=\"refresh\""))
        #expect(!PreviewPage.notAllowed().contains("http-equiv=\"refresh\""))
    }

    @Test("without the cookie the page names no services and no settings file")
    func strangerSeesNothingOfTheProject() {
        let html = PreviewPage.unavailable(advice: [], services: nil)
        #expect(!html.contains("class=\"services\""))
        #expect(!html.contains("settings.toml"))
    }

    @Test("port advice is drawn without the blank line portAdvice separates it with")
    func adviceDropsTheSeparator() {
        let html = PreviewPage.unavailable(advice: ["", "The preview reads port 3000."], services: [])
        #expect(html.contains("<div class=\"notice\"><p>The preview reads port 3000.</p></div>"))
        #expect(html.contains("No services are configured"))
    }
}
