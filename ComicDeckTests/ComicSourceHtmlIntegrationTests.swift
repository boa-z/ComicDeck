import XCTest
@testable import ComicDeck

final class ComicSourceHtmlIntegrationTests: XCTestCase {
    private let fixtureHTML = """
    <div class="card featured">
      <h2 class="title">Series <span>One</span></h2>
      <a class="link" data-id="42" href="/comic/42">Open</a>
    </div>
    <ul id="list"><li>One<li>Two</ul>
    """

    func testHtmlDocumentContractInsideSourceEngine() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'test';
            this.name = 'Test';
          }
        }
        """

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let result = try engine.callCustom(
            expression: """
            (() => {
              const doc = new HtmlDocument(arguments[0]);
              const card = doc.querySelector('div.card.featured');
              const title = card ? card.querySelector('.title') : null;
              const link = card ? card.querySelector('a.link[data-id="42"]') : null;
              const list = doc.getElementById('list');
              const beforeDisposeText = title ? title.text : '';
              const beforeDisposeInnerHTML = title ? title.innerHTML : '';
              const itemCount = doc.querySelectorAll('#list > li').length;
              const childCount = list ? list.children.length : 0;
              const href = link ? (link.attributes.href || '') : '';
              doc.dispose();
              return {
                beforeDisposeText,
                beforeDisposeInnerHTML,
                itemCount,
                childCount,
                href,
                missingIsNull: doc.querySelector('.missing') === null,
                disposedCount: doc.querySelectorAll('#list > li').length,
                disposedText: title ? title.text : ''
              };
            })()
            """,
            arguments: [fixtureHTML]
        )

        guard let object = result as? [String: Any] else {
            return XCTFail("expected dictionary result")
        }

        XCTAssertEqual(normalized(object["beforeDisposeText"] as? String ?? ""), "Series One")
        XCTAssertTrue((object["beforeDisposeInnerHTML"] as? String ?? "").contains("<span>One</span>"))
        XCTAssertEqual(object["itemCount"] as? Int, 2)
        XCTAssertEqual(object["childCount"] as? Int, 2)
        XCTAssertEqual(object["href"] as? String, "/comic/42")
        XCTAssertEqual(object["missingIsNull"] as? Bool, true)
        XCTAssertEqual(object["disposedCount"] as? Int, 0)
        XCTAssertEqual(object["disposedText"] as? String, "")
    }

    func testHtmlDocumentSupportsAdvancedSelectorsInsideSourceEngine() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'test';
            this.name = 'Test';
          }
        }
        """
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

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let result = try engine.callCustom(
            expression: """
            (() => {
              const doc = new HtmlDocument(arguments[0]);
              const adjacent = doc.querySelectorAll('a + span.marker').map((it) => it.text);
              const nth = doc.querySelector('.row > span:nth-child(4)');
              const notDisabled = doc.querySelectorAll('.row > span.marker:not(.disabled)').length;
              const attrContains = doc.querySelectorAll("a[href*='from=']").length;
              doc.dispose();
              return {
                adjacent,
                nth: nth ? nth.text : '',
                notDisabled,
                attrContains
              };
            })()
            """,
            arguments: [html]
        )

        guard let object = result as? [String: Any] else {
            return XCTFail("expected dictionary result")
        }
        XCTAssertEqual(object["adjacent"] as? [String], ["A", "D"])
        XCTAssertEqual(object["nth"] as? String, "C")
        XCTAssertEqual(object["notDisabled"] as? Int, 3)
        XCTAssertEqual(object["attrContains"] as? Int, 2)
    }

    func testHtmlDocumentExposesInlineScriptTextInsideSourceEngine() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'test';
            this.name = 'Test';
          }
        }
        """
        let html = """
        <html><body>
          <script>
            window.__DATA__ = {"gid": 123, "token": "abc"};
          </script>
        </body></html>
        """

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let result = try engine.callCustom(
            expression: """
            (() => {
              const doc = new HtmlDocument(arguments[0]);
              const script = doc.querySelector('script');
              const text = script ? script.text : '';
              doc.dispose();
              return { text };
            })()
            """,
            arguments: [html]
        )

        guard let object = result as? [String: Any] else {
            return XCTFail("expected dictionary result")
        }
        XCTAssertTrue((object["text"] as? String ?? "").contains("window.__DATA__"))
        XCTAssertTrue((object["text"] as? String ?? "").contains("\"gid\": 123"))
    }

    func testHtmlElementBrowserStyleAliasesInsideSourceEngine() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'test';
            this.name = 'Test';
          }
        }
        """
        let html = """
        <div id="root">
          <a id="jump" class="link primary" href="/comic/42"><span>Open</span></a>
        </div>
        """

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let result = try engine.callCustom(
            expression: """
            (() => {
              const doc = new HtmlDocument(arguments[0]);
              const link = doc.querySelector('a.link');
              const payload = {
                text: link ? link.text : '',
                textContent: link ? link.textContent : '',
                innerText: link ? link.innerText : '',
                innerHTML: link ? link.innerHTML : '',
                outerHTML: link ? link.outerHTML : '',
                tagName: link ? link.tagName : '',
                nodeName: link ? link.nodeName : '',
                id: link ? link.id : '',
                className: link ? link.className : '',
                href: link ? link.getAttribute('href') : null,
                hasHref: link ? link.hasAttribute('href') : false,
                missing: link ? link.getAttribute('missing') : 'fallback'
              };
              doc.dispose();
              return payload;
            })()
            """,
            arguments: [html]
        )

        guard let object = result as? [String: Any] else {
            return XCTFail("expected dictionary result")
        }
        XCTAssertEqual(object["text"] as? String, "Open")
        XCTAssertEqual(object["textContent"] as? String, "Open")
        XCTAssertEqual(object["innerText"] as? String, "Open")
        XCTAssertEqual(object["tagName"] as? String, "a")
        XCTAssertEqual(object["nodeName"] as? String, "a")
        XCTAssertEqual(object["id"] as? String, "jump")
        XCTAssertEqual(object["className"] as? String, "link primary")
        XCTAssertEqual(object["href"] as? String, "/comic/42")
        XCTAssertEqual(object["hasHref"] as? Bool, true)
        XCTAssertEqual(object["missing"] as? String, nil)
        XCTAssertTrue((object["innerHTML"] as? String ?? "").contains("<span>Open</span>"))
        XCTAssertTrue((object["outerHTML"] as? String ?? "").contains("class=\"link primary\""))
    }

    func testLoadComicEpRequestsPrefersChapterURLAsDefaultReferer() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'test';
            this.name = 'Test';
            this.comic = {
              loadEp: (comicID, chapterID) => ({
                images: ['https://images.example/page-1.jpg']
              })
            };
          }
        }
        """

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let requests = try engine.loadComicEpRequests(
            comicID: "https://comic.example/series/1",
            chapterID: "https://gallery.example/g/123/456"
        )

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, "https://images.example/page-1.jpg")
        XCTAssertEqual(requests.first?.method, "GET")
        XCTAssertEqual(requests.first?.headers["Referer"], "https://gallery.example/g/123/456")
    }

    func testLoadComicEpRequestsFallsBackToComicURLWhenChapterIDIsNotURL() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'test';
            this.name = 'Test';
            this.comic = {
              loadEp: (comicID, chapterID) => ({
                images: ['https://images.example/page-2.jpg']
              })
            };
          }
        }
        """

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let requests = try engine.loadComicEpRequests(
            comicID: "https://comic.example/series/1",
            chapterID: "chapter-2"
        )

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.headers["Referer"], "https://comic.example/series/1")
    }

    func testLoadComicEpRequestsAddsDefaultRefererToOnImageLoadOutput() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'test';
            this.name = 'Test';
            this.comic = {
              loadEp: () => ({
                images: ['https://images.example/page-3.jpg']
              }),
              onImageLoad: (token) => ({
                url: token,
                method: 'POST',
                headers: { 'X-Test': '1' },
                data: 'abc'
              })
            };
          }
        }
        """

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let requests = try engine.loadComicEpRequests(
            comicID: "https://comic.example/series/1",
            chapterID: "https://gallery.example/g/123/456"
        )

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.method, "POST")
        XCTAssertEqual(requests.first?.headers["X-Test"], "1")
        XCTAssertEqual(requests.first?.headers["Referer"], "https://gallery.example/g/123/456")
        XCTAssertEqual(requests.first?.body, Array("abc".utf8))
    }

    func testLoadComicEpRequestsMemoizesRepeatedOnImageLoadDependenciesWithinOneResolutionPass() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'test';
            this.name = 'Test';
            this.sharedCounters = {
              loadThumbnails: 0,
              getKey: 0
            };
            this.comic = {
              loadEp: () => ({
                images: ['0', '1', '2']
              }),
              loadThumbnails: async (comicId) => {
                this.sharedCounters.loadThumbnails += 1;
                return {
                  thumbnails: ['thumb-1'],
                  urls: ['https://gallery.example/g/123/456/page-1']
                };
              },
              getKey: async (url) => {
                this.sharedCounters.getKey += 1;
                return { showkey: 'abc' };
              },
              onImageLoad: async (token, comicId, chapterId, nl) => {
                const thumbs = await this.comic.loadThumbnails(comicId);
                const key = await this.comic.getKey(thumbs.urls[0]);
                return {
                  url: `https://images.example/${token}?showkey=${key.showkey}`,
                  headers: { 'X-NL': nl == null ? 'none' : String(nl) }
                };
              }
            };
          }
        }
        """

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let requests = try engine.loadComicEpRequests(
            comicID: "https://comic.example/series/1",
            chapterID: "chapter-1"
        )
        let counters = try engine.callCustom(
            expression: "({ loadThumbnails: this.__source_temp.sharedCounters.loadThumbnails, getKey: this.__source_temp.sharedCounters.getKey })"
        )

        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.map(\.url), [
            "https://images.example/0?showkey=abc",
            "https://images.example/1?showkey=abc",
            "https://images.example/2?showkey=abc"
        ])
        guard let object = counters as? [String: Any] else {
            return XCTFail("expected counters dictionary")
        }
        XCTAssertEqual(object["loadThumbnails"] as? Int, 1)
        XCTAssertEqual(object["getKey"] as? Int, 1)
    }

    func testPrepareReaderPageRequestSessionResolvesRequestedAbsoluteIndexes() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'test';
            this.name = 'Test';
            this.comic = {
              loadEp: () => ({
                images: ['zero', 'one', 'two']
              }),
              onImageLoad: (token) => ({
                url: `https://images.example/${token}.jpg`,
                method: 'POST',
                headers: { 'X-Token': token },
                data: token
              })
            };
          }
        }
        """

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let preparation = try engine.prepareReaderPageRequestSession(
            comicID: "https://comic.example/series/1",
            chapterID: "https://gallery.example/g/123/456"
        )
        let requests = try engine.resolveReaderPageRequestSession(preparation.handle, pageIndexes: [2, 0])

        XCTAssertEqual(preparation.totalPages, 3)
        XCTAssertEqual(requests.map(\.index), [0, 2])
        XCTAssertEqual(requests.map(\.request.url), [
            "https://images.example/zero.jpg",
            "https://images.example/two.jpg"
        ])
        XCTAssertEqual(requests.map(\.request.method), ["POST", "POST"])
        XCTAssertEqual(requests.first?.request.headers["X-Token"], "zero")
        XCTAssertEqual(requests.first?.request.headers["Referer"], "https://gallery.example/g/123/456")
        XCTAssertEqual(requests.first?.request.body, Array("zero".utf8))
    }

    func testReaderPageRequestSessionMemoizesDependenciesAcrossBatches() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'test';
            this.name = 'Test';
            this.sharedCounters = {
              loadThumbnails: 0,
              getKey: 0
            };
            this.comic = {
              loadEp: () => ({
                images: ['0', '1', '2']
              }),
              loadThumbnails: async (comicId) => {
                this.sharedCounters.loadThumbnails += 1;
                return {
                  thumbnails: ['thumb-1'],
                  urls: ['https://gallery.example/g/123/456/page-1']
                };
              },
              getKey: async (url) => {
                this.sharedCounters.getKey += 1;
                return { showkey: 'abc' };
              },
              onImageLoad: async (token, comicId, chapterId, nl) => {
                const thumbs = await this.comic.loadThumbnails(comicId);
                const key = await this.comic.getKey(thumbs.urls[0]);
                return {
                  url: `https://images.example/${token}?showkey=${key.showkey}`,
                  headers: { 'X-NL': nl == null ? 'none' : String(nl) }
                };
              }
            };
          }
        }
        """

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let preparation = try engine.prepareReaderPageRequestSession(comicID: "comic-1", chapterID: "chapter-1")
        let firstBatch = try engine.resolveReaderPageRequestSession(preparation.handle, pageIndexes: [0])
        let secondBatch = try engine.resolveReaderPageRequestSession(preparation.handle, pageIndexes: [1, 2])
        let counters = try engine.callCustom(
            expression: "({ loadThumbnails: this.__source_temp.sharedCounters.loadThumbnails, getKey: this.__source_temp.sharedCounters.getKey })"
        )

        XCTAssertEqual(firstBatch.map(\.index), [0])
        XCTAssertEqual(secondBatch.map(\.index), [1, 2])
        XCTAssertEqual(firstBatch.first?.request.url, "https://images.example/0?showkey=abc")
        XCTAssertEqual(secondBatch.map(\.request.url), [
            "https://images.example/1?showkey=abc",
            "https://images.example/2?showkey=abc"
        ])
        guard let object = counters as? [String: Any] else {
            return XCTFail("expected counters dictionary")
        }
        XCTAssertEqual(object["loadThumbnails"] as? Int, 1)
        XCTAssertEqual(object["getKey"] as? Int, 1)
    }

    func testReaderPageRequestSessionFallsBackToDirectLinksWithoutOnImageLoad() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'test';
            this.name = 'Test';
            this.comic = {
              loadEp: () => ({
                images: [
                  'https://images.example/page-1.jpg',
                  'https://images.example/page-2.jpg'
                ]
              })
            };
          }
        }
        """

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let preparation = try engine.prepareReaderPageRequestSession(
            comicID: "https://comic.example/series/1",
            chapterID: "https://gallery.example/g/123/456"
        )
        let requests = try engine.resolveReaderPageRequestSession(preparation.handle, pageIndexes: [1])

        XCTAssertEqual(preparation.totalPages, 2)
        XCTAssertEqual(requests.map(\.index), [1])
        XCTAssertEqual(requests.first?.request.url, "https://images.example/page-2.jpg")
        XCTAssertEqual(requests.first?.request.method, "GET")
        XCTAssertEqual(requests.first?.request.headers["Referer"], "https://gallery.example/g/123/456")
    }

    func testDisposeReaderPageRequestSessionInvalidatesFurtherResolution() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'test';
            this.name = 'Test';
            this.comic = {
              loadEp: () => ({ images: ['https://images.example/page-1.jpg'] })
            };
          }
        }
        """

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let preparation = try engine.prepareReaderPageRequestSession(comicID: "comic-1", chapterID: "chapter-1")
        engine.disposeReaderPageRequestSession(preparation.handle)

        XCTAssertThrowsError(
            try engine.resolveReaderPageRequestSession(preparation.handle, pageIndexes: [0])
        )
    }

    @MainActor
    func testReaderSessionPreferredInitialPageIndexKeepsResumePageStableAcrossModes() {
        let session = ReaderSession(
            item: ComicSummary(id: "comic-1", sourceKey: "test", title: "Test Comic"),
            chapterID: "chapter-1",
            chapterTitle: "Chapter 1",
            initialPage: 2
        )

        XCTAssertEqual(session.preferredInitialPageIndex(total: 5, readerMode: .ltr), 1)
        XCTAssertEqual(session.preferredInitialPageIndex(total: 5, readerMode: .vertical), 1)
        XCTAssertEqual(session.preferredInitialPageIndex(total: 5, readerMode: .rtl), 3)
    }

    func testEhentaiFavoritesTableRowsWorkWithImplicitTbody() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'eh';
            this.name = 'eh';
          }
        }
        """

        let html = """
        <table class="itg gltc">
          <tr>
            <td><div class="cn">Manga</div></td>
            <td>
              <div></div>
              <div><div><img src="https://images.example/cover.jpg"></div></div>
              <div><div>2026-03-19</div><div style="background-position:0px -21px"></div></div>
            </td>
            <td>
              <a href="https://e-hentai.org/g/1/token/">
                <div>Example Title</div>
                <div><span title="tag:a"></span><span title="language:english"></span></div>
              </a>
            </td>
          </tr>
        </table>
        """

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let result = try engine.callCustom(
            expression: """
            (() => {
              const document = new HtmlDocument(arguments[0]);
              const rows = document.querySelectorAll('table.itg.gltc > tbody > tr');
              return rows.map((item) => ({
                title: item.children[2].children[0].children[0].text,
                href: item.children[2].children[0].attributes['href']
              }));
            })()
            """,
            arguments: [html]
        )

        guard let rows = result as? [[String: Any]] else {
            return XCTFail("expected row list")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["title"] as? String, "Example Title")
        XCTAssertEqual(rows[0]["href"] as? String, "https://e-hentai.org/g/1/token/")
    }

    func testEhentaiExtendedFavoritesTagsSelectorListWorks() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'test';
            this.name = 'Test';
          }
        }
        """

        let html = """
        <table class="itg glte">
          <tr>
            <td class="gl1e"></td>
            <td class="gl2e">
              <div>
                <a href="https://e-hentai.org/g/1/token/">
                  <div class="gl4e glname">
                    <div class="glink">Example Title</div>
                    <div>
                      <table>
                        <tr>
                          <td><div class="gt" title="language:english">english</div></td>
                        </tr>
                        <tr>
                          <td><div class="gtl" title="female:ahegao">ahegao</div></td>
                        </tr>
                      </table>
                    </div>
                  </div>
                </a>
              </div>
            </td>
          </tr>
        </table>
        """

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let result = try engine.callCustom(
            expression: """
            (() => {
              const document = new HtmlDocument(arguments[0]);
              const row = document.querySelector('table.itg.glte > tbody > tr');
              return row.querySelectorAll('div.gt, div.gtl').map((item) => item.attributes['title']);
            })()
            """,
            arguments: [html]
        )

        guard let tags = result as? [String] else {
            return XCTFail("expected tag list")
        }
        XCTAssertEqual(tags, ["language:english", "female:ahegao"])
    }

    func testHtmlElementSiblingAndParentTraversalInsideSourceEngine() throws {
        let script = """
        class TestSource extends ComicSource {
          constructor() {
            super();
            this.key = 'test';
            this.name = 'Test';
          }
        }
        """

        let html = """
        <div id="root">
          <a id="first"></a>
          <span id="middle"></span>
          <b id="last"></b>
        </div>
        """

        let engine = try ComicSourceRepository().createSourceEngine(script: script)
        let result = try engine.callCustom(
            expression: """
            (() => {
              const document = new HtmlDocument(arguments[0]);
              const middle = document.getElementById('middle');
              return {
                previous: middle?.previousElementSibling?.attributes['id'] ?? null,
                next: middle?.nextElementSibling?.attributes['id'] ?? null,
                parent: middle?.parentElement?.attributes['id'] ?? null
              };
            })()
            """,
            arguments: [html]
        )

        guard let object = result as? [String: Any] else {
            return XCTFail("expected dictionary result")
        }
        XCTAssertEqual(object["previous"] as? String, "first")
        XCTAssertEqual(object["next"] as? String, "last")
        XCTAssertEqual(object["parent"] as? String, "root")
    }

    private func normalized(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
