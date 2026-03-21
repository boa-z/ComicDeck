import XCTest
@testable import ComicDeck

final class HtmlRuntimeBridgeTests: XCTestCase {
    private let fixtureHTML = """
    <div id="root">
      <section class="items">
        <article class="item featured" data-id="a1">
          <h1 id="title"> Hello <span>World</span></h1>
          <a class="link primary" href="/comic/1">Read</a>
          <ul id="chapters"><li>One<li class="current">Two</ul>
          <div class="nested"><span data-role="badge">New</span></div>
        </article>
        <article class="item" data-id="a2"><p>Second</p></article>
      </section>
    </div>
    """

    func testBridgeWorksOffMainThread() {
        let expectation = expectation(description: "background html parse")
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread)
            let documentKey = HtmlRuntimeBridge.shared.parse(html: self.fixtureHTML)
            XCTAssertGreaterThan(documentKey, 0)
            let titleKey = HtmlRuntimeBridge.shared.getElementById(documentKey: documentKey, id: "title")
            XCTAssertNotNil(titleKey)
            XCTAssertEqual(self.normalized(HtmlRuntimeBridge.shared.text(elementKey: titleKey ?? 0)), "Hello World")
            HtmlRuntimeBridge.shared.dispose(documentKey: documentKey)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testQuerySelectorQuerySelectorAllAndGetElementById() {
        let documentKey = HtmlRuntimeBridge.shared.parse(html: fixtureHTML)
        XCTAssertGreaterThan(documentKey, 0)

        let featured = HtmlRuntimeBridge.shared.querySelector(documentKey: documentKey, query: "article.item.featured")
        XCTAssertNotNil(featured)

        let allItems = HtmlRuntimeBridge.shared.querySelectorAll(documentKey: documentKey, query: "section.items article.item")
        XCTAssertEqual(allItems.count, 2)

        let title = HtmlRuntimeBridge.shared.getElementById(documentKey: documentKey, id: "title")
        XCTAssertNotNil(title)
        XCTAssertEqual(normalized(HtmlRuntimeBridge.shared.text(elementKey: title ?? 0)), "Hello World")

        HtmlRuntimeBridge.shared.dispose(documentKey: documentKey)
    }

    func testElementScopedQueriesAndChildren() {
        let documentKey = HtmlRuntimeBridge.shared.parse(html: fixtureHTML)
        let articleKey = HtmlRuntimeBridge.shared.querySelector(documentKey: documentKey, query: "article.item.featured")
        XCTAssertNotNil(articleKey)

        let badgeKey = HtmlRuntimeBridge.shared.elementQuerySelector(elementKey: articleKey ?? 0, query: ".nested > span[data-role=badge]")
        XCTAssertNotNil(badgeKey)
        XCTAssertEqual(HtmlRuntimeBridge.shared.text(elementKey: badgeKey ?? 0), "New")

        let chaptersKey = HtmlRuntimeBridge.shared.getElementById(documentKey: documentKey, id: "chapters")
        let children = HtmlRuntimeBridge.shared.children(elementKey: chaptersKey ?? 0)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(normalized(HtmlRuntimeBridge.shared.text(elementKey: children[0])), "One")
        XCTAssertEqual(normalized(HtmlRuntimeBridge.shared.text(elementKey: children[1])), "Two")

        HtmlRuntimeBridge.shared.dispose(documentKey: documentKey)
    }

    func testInnerHTMLAndAttributes() {
        let documentKey = HtmlRuntimeBridge.shared.parse(html: fixtureHTML)
        let titleKey = HtmlRuntimeBridge.shared.getElementById(documentKey: documentKey, id: "title")
        let linkKey = HtmlRuntimeBridge.shared.querySelector(documentKey: documentKey, query: "a.link.primary[href='/comic/1']")

        XCTAssertTrue(HtmlRuntimeBridge.shared.innerHTML(elementKey: titleKey ?? 0).contains("<span>World</span>"))
        let attributes = HtmlRuntimeBridge.shared.attributes(elementKey: linkKey ?? 0)
        XCTAssertEqual(attributes["href"], "/comic/1")
        XCTAssertEqual(attributes["class"], "link primary")

        HtmlRuntimeBridge.shared.dispose(documentKey: documentKey)
    }

    func testImplicitTbodyMatchesBrowserStyleSelectors() {
        let html = """
        <table class="itg gltc">
          <tr><td>Row 1</td></tr>
          <tr><td>Row 2</td></tr>
        </table>
        """

        let documentKey = HtmlRuntimeBridge.shared.parse(html: html)
        let rows = HtmlRuntimeBridge.shared.querySelectorAll(documentKey: documentKey, query: "table.itg.gltc > tbody > tr")

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(HtmlRuntimeBridge.shared.text(elementKey: rows[0]), "Row 1")
        XCTAssertEqual(HtmlRuntimeBridge.shared.text(elementKey: rows[1]), "Row 2")

        HtmlRuntimeBridge.shared.dispose(documentKey: documentKey)
    }

    func testGroupedSelectorsMatchMultipleClasses() {
        let html = """
        <div id="root">
          <div class="gt" title="tag:a">a</div>
          <div class="gtl" title="tag:b">b</div>
          <div class="other" title="tag:c">c</div>
        </div>
        """

        let documentKey = HtmlRuntimeBridge.shared.parse(html: html)
        let tags = HtmlRuntimeBridge.shared.querySelectorAll(documentKey: documentKey, query: "div.gt, div.gtl")

        XCTAssertEqual(tags.count, 2)
        XCTAssertEqual(HtmlRuntimeBridge.shared.attributes(elementKey: tags[0])["title"], "tag:a")
        XCTAssertEqual(HtmlRuntimeBridge.shared.attributes(elementKey: tags[1])["title"], "tag:b")

        HtmlRuntimeBridge.shared.dispose(documentKey: documentKey)
    }

    func testAdvancedSelectorsRemainBrowserCompatible() {
        let html = """
        <div id="root">
          <div class="row">
            <a class="link" href="/gallery/1?from=featured">One</a>
            <span class="marker">A</span>
            <span class="marker disabled">B</span>
            <span class="marker">C</span>
          </div>
          <div class="row alt">
            <a class="link secondary" href="/gallery/2?from=latest">Two</a>
            <span class="marker">D</span>
          </div>
        </div>
        """

        let documentKey = HtmlRuntimeBridge.shared.parse(html: html)

        let adjacent = HtmlRuntimeBridge.shared.querySelectorAll(documentKey: documentKey, query: "a + span.marker")
        XCTAssertEqual(adjacent.count, 2)
        XCTAssertEqual(HtmlRuntimeBridge.shared.text(elementKey: adjacent[0]), "A")
        XCTAssertEqual(HtmlRuntimeBridge.shared.text(elementKey: adjacent[1]), "D")

        let nthChild = HtmlRuntimeBridge.shared.querySelector(documentKey: documentKey, query: ".row > span:nth-child(4)")
        XCTAssertEqual(HtmlRuntimeBridge.shared.text(elementKey: nthChild ?? 0), "C")

        let notDisabled = HtmlRuntimeBridge.shared.querySelectorAll(documentKey: documentKey, query: ".row > span.marker:not(.disabled)")
        XCTAssertEqual(notDisabled.count, 3)

        let attributeContains = HtmlRuntimeBridge.shared.querySelectorAll(documentKey: documentKey, query: "a[href*='from=']")
        XCTAssertEqual(attributeContains.count, 2)

        HtmlRuntimeBridge.shared.dispose(documentKey: documentKey)
    }

    func testScriptElementsExposeRawInlineScriptText() {
        let html = """
        <html><body>
          <script>
            window.__DATA__ = {"gid": 123, "token": "abc"};
          </script>
        </body></html>
        """

        let documentKey = HtmlRuntimeBridge.shared.parse(html: html)
        let script = HtmlRuntimeBridge.shared.querySelector(documentKey: documentKey, query: "script")

        XCTAssertNotNil(script)
        XCTAssertTrue(HtmlRuntimeBridge.shared.text(elementKey: script ?? 0).contains("window.__DATA__"))
        XCTAssertTrue(HtmlRuntimeBridge.shared.text(elementKey: script ?? 0).contains("\"gid\": 123"))

        HtmlRuntimeBridge.shared.dispose(documentKey: documentKey)
    }

    func testNestedInnerTableDoesNotCollapseOuterFavoritesRows() {
        let html = """
        <table class="itg glte">
          <tr>
            <td class="gl1e"></td>
            <td class="gl2e">
              <div>
                <div class="gl3e"><div class="cn">Image Set</div></div>
                <a href="https://e-hentai.org/g/1/token/">
                  <div class="gl4e glname">
                    <div class="glink">Title 1</div>
                    <div>
                      <table>
                        <tr><td><div class="gt" title="language:english">english</div></td></tr>
                        <tr><td><div class="gtl" title="female:ahegao">ahegao</div></td></tr>
                      </table>
                    </div>
                  </div>
                </a>
              </div>
            </td>
            <td class="glfe"></td>
          </tr>
          <tr>
            <td class="gl1e"></td>
            <td class="gl2e">
              <div>
                <div class="gl3e"><div class="cn">Manga</div></div>
                <a href="https://e-hentai.org/g/2/token/">
                  <div class="gl4e glname">
                    <div class="glink">Title 2</div>
                  </div>
                </a>
              </div>
            </td>
            <td class="glfe"></td>
          </tr>
        </table>
        """

        let documentKey = HtmlRuntimeBridge.shared.parse(html: html)
        let rows = HtmlRuntimeBridge.shared.querySelectorAll(documentKey: documentKey, query: "table.itg.glte > tbody > tr")

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(HtmlRuntimeBridge.shared.children(elementKey: rows[0]).count, 3)
        XCTAssertEqual(HtmlRuntimeBridge.shared.children(elementKey: rows[1]).count, 3)

        HtmlRuntimeBridge.shared.dispose(documentKey: documentKey)
    }

    func testDisposeInvalidatesDocumentAndElementHandles() {
        let documentKey = HtmlRuntimeBridge.shared.parse(html: fixtureHTML)
        let titleKey = HtmlRuntimeBridge.shared.getElementById(documentKey: documentKey, id: "title")
        XCTAssertNotNil(titleKey)

        HtmlRuntimeBridge.shared.dispose(documentKey: documentKey)

        XCTAssertNil(HtmlRuntimeBridge.shared.querySelector(documentKey: documentKey, query: "#title"))
        XCTAssertEqual(HtmlRuntimeBridge.shared.querySelectorAll(documentKey: documentKey, query: "article.item").count, 0)
        XCTAssertEqual(HtmlRuntimeBridge.shared.text(elementKey: titleKey ?? 0), "")
        XCTAssertEqual(HtmlRuntimeBridge.shared.innerHTML(elementKey: titleKey ?? 0), "")
        XCTAssertEqual(HtmlRuntimeBridge.shared.attributes(elementKey: titleKey ?? 0), [:])
        XCTAssertEqual(HtmlRuntimeBridge.shared.children(elementKey: titleKey ?? 0), [])
    }

    func testSiblingAndParentTraversal() {
        let html = """
        <div id="root">
          <a id="first"></a>
          <span id="middle"></span>
          <b id="last"></b>
        </div>
        """

        let documentKey = HtmlRuntimeBridge.shared.parse(html: html)
        let middleKey = HtmlRuntimeBridge.shared.getElementById(documentKey: documentKey, id: "middle")
        XCTAssertNotNil(middleKey)

        let previous = HtmlRuntimeBridge.shared.previousElementSibling(elementKey: middleKey ?? 0)
        let next = HtmlRuntimeBridge.shared.nextElementSibling(elementKey: middleKey ?? 0)
        let parent = HtmlRuntimeBridge.shared.parentElement(elementKey: middleKey ?? 0)

        XCTAssertEqual(HtmlRuntimeBridge.shared.attributes(elementKey: previous ?? 0)["id"], "first")
        XCTAssertEqual(HtmlRuntimeBridge.shared.attributes(elementKey: next ?? 0)["id"], "last")
        XCTAssertEqual(HtmlRuntimeBridge.shared.attributes(elementKey: parent ?? 0)["id"], "root")

        HtmlRuntimeBridge.shared.dispose(documentKey: documentKey)
    }

    func testInvalidHandlesReturnEmptyValues() {
        XCTAssertNil(HtmlRuntimeBridge.shared.querySelector(documentKey: 0, query: "div"))
        XCTAssertNil(HtmlRuntimeBridge.shared.querySelector(documentKey: 999_999, query: "div"))
        XCTAssertEqual(HtmlRuntimeBridge.shared.querySelectorAll(documentKey: 999_999, query: "div"), [])
        XCTAssertNil(HtmlRuntimeBridge.shared.getElementById(documentKey: 999_999, id: "x"))
        XCTAssertNil(HtmlRuntimeBridge.shared.elementQuerySelector(elementKey: 999_999, query: "span"))
        XCTAssertEqual(HtmlRuntimeBridge.shared.elementQuerySelectorAll(elementKey: 999_999, query: "span"), [])
        XCTAssertEqual(HtmlRuntimeBridge.shared.children(elementKey: 999_999), [])
        XCTAssertEqual(HtmlRuntimeBridge.shared.text(elementKey: 999_999), "")
        XCTAssertEqual(HtmlRuntimeBridge.shared.innerHTML(elementKey: 999_999), "")
        XCTAssertEqual(HtmlRuntimeBridge.shared.attributes(elementKey: 999_999), [:])
    }

    private func normalized(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
