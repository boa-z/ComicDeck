import Foundation
import JavaScriptCore
import CryptoKit
import UIKit
import CommonCrypto

private enum RuntimeLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

@inline(__always)
private func jsDebugLog(_ message: String, level: RuntimeLogLevel = .debug) {
    guard RuntimeDebugConsole.isEnabled else { return }
    let line = "[SourceRuntime][\(level.rawValue)][JS] \(message)"
    NSLog("%@", line)
    RuntimeDebugConsole.shared.append(line)
}

enum ScriptEngineError: Error, LocalizedError {
    case buildContextFailed
    case missingFunction(String)
    case scriptException(String)
    case invalidResult(String)
    case unsupportedRuntime(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .buildContextFailed:
            return "Unable to create JavaScript runtime."
        case let .missingFunction(name):
            return "Function not found in script: \(name)"
        case let .scriptException(message):
            return "Script exception: \(message)"
        case let .invalidResult(message):
            return "Unexpected script result: \(message)"
        case let .unsupportedRuntime(message):
            return "Unsupported runtime: \(message)"
        case let .timeout(message):
            return "Timeout: \(message)"
        }
    }
}

final class ComicSourceScriptEngine {
    private let context: JSContext
    private var storageKey: String = "default"

    init(script: String) throws {
        guard let ctx = JSContext() else {
            throw ScriptEngineError.buildContextFailed
        }
        self.context = ctx
        try setupRuntime(on: ctx)
        jsDebugLog("Evaluating plain script runtime", level: .info)

        _ = ctx.evaluateScript(script)
        if let exception = ctx.exception {
            let message = exception.toString() ?? "Unknown JS exception"
            jsDebugLog("Script exception during init: \(message)", level: .error)
            throw ScriptEngineError.scriptException(message)
        }
    }

    private init(context: JSContext) {
        self.context = context
    }

    func setStorageKey(_ key: String) {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        storageKey = normalized.isEmpty ? "default" : normalized
    }

    private static let bridgeStorePrefix = "source.runtime.store."

    private func bridgeStoreRead() -> [String: Any] {
        let key = Self.bridgeStorePrefix + storageKey
        return UserDefaults.standard.dictionary(forKey: key) ?? [:]
    }

    private func bridgeStoreWrite(_ value: [String: Any]) {
        let key = Self.bridgeStorePrefix + storageKey
        UserDefaults.standard.set(value, forKey: key)
    }

    private func sanitizePropertyList(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let v = value as? String { return v }
        if let v = value as? NSNumber { return v }
        if let v = value as? Bool { return v }
        if let v = value as? Date { return v }
        if let v = value as? Data { return v }
        if let arr = value as? [Any] {
            return arr.compactMap { sanitizePropertyList($0) }
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if let pv = sanitizePropertyList(v) {
                    out[k] = pv
                }
            }
            return out
        }
        if let dict = value as? NSDictionary {
            var out: [String: Any] = [:]
            for (rawK, rawV) in dict {
                guard let k = rawK as? String else { continue }
                if let pv = sanitizePropertyList(rawV) {
                    out[k] = pv
                }
            }
            return out
        }
        return String(describing: value)
    }

    /// Creates a ComicSourceScriptEngine bound to the first ComicSource subclass found in the script.
    static func fromSourceScript(_ script: String) throws -> ComicSourceScriptEngine {
        guard let className = SourceScriptParser.extractClassName(from: script) else {
            throw ScriptEngineError.invalidResult("Cannot find 'class ... extends ComicSource'")
        }

        guard let ctx = JSContext() else {
            throw ScriptEngineError.buildContextFailed
        }
        let engine = ComicSourceScriptEngine(context: ctx)
        try engine.setupRuntime(on: ctx)
        jsDebugLog("Creating source script engine for class: \(className)", level: .info)

        let wrapped = """
        (() => {
          \(script)
          this.__source_temp = new \(className)();
        }).call(this)
        """
        _ = ctx.evaluateScript(wrapped)

        if let exception = ctx.exception {
            let message = exception.toString() ?? "Unknown JS exception"
            jsDebugLog("Script exception during fromSourceScript: \(message)", level: .error)
            throw ScriptEngineError.scriptException(message)
        }
        return engine
    }

    // JS Extension Point — call any expression or function exposed by the loaded source script.
    // Used internally and can be called directly for custom JS function invocations.
    func callCustom(expression: String, arguments: [Any] = []) throws -> Any {
        try callExpression(expression, arguments: arguments)
    }

    func call(function name: String, arguments: [Any] = []) throws -> Any {
        guard let function = context.objectForKeyedSubscript(name), !function.isUndefined else {
            throw ScriptEngineError.missingFunction(name)
        }

        jsDebugLog("Calling JS function: \(name), argsCount=\(arguments.count)")
        let output = function.call(withArguments: arguments)
        return try normalizeOutput(output, fallbackSourceKey: "demo")
    }

    func callExpression(_ expression: String, arguments: [Any] = []) throws -> Any {
        let wrappedExpr = """
        (async () => {
          if (this.__source_temp) {
            if (!this.__source_runtime_init_promise) {
              const source = this.__source_temp;
              const sourceType = source && source.constructor;
              const currentDomains = Array.isArray(sourceType && sourceType.apiDomains)
                ? sourceType.apiDomains
                : [];
              const jmBootstrapDomains = [
                'www.cdnzack.cc',
                'www.cdnhth.cc',
                'www.cdnhth.net',
                'www.cdnbea.net'
              ];
              const jmLegacyFallbackDomains = [
                'www.cdntwice.org',
                'www.cdnsha.org',
                'www.cdnaspa.cc',
                'www.cdnntr.cc'
              ];
              const shouldBootstrapJM = source &&
                String(source.key || '').toLowerCase() === 'jm' && (
                  currentDomains.length === 0 ||
                  currentDomains.every((item) => jmLegacyFallbackDomains.includes(String(item)))
                );
              if (sourceType && shouldBootstrapJM) {
                sourceType.apiDomains = jmBootstrapDomains.slice();
              }
              if (
                sourceType &&
                !Array.isArray(sourceType.apiDomains) &&
                Array.isArray(sourceType.fallbackServers) &&
                sourceType.fallbackServers.length > 0
              ) {
                sourceType.apiDomains = sourceType.fallbackServers.slice();
              }
              if (typeof this.__source_temp.init === 'function') {
                this.__source_runtime_init_promise = Promise.resolve(
                  this.__source_temp.init()
                ).then(() => {
                  if (
                    sourceType &&
                    shouldBootstrapJM &&
                    (!Array.isArray(sourceType.apiDomains) ||
                     sourceType.apiDomains.every((item) => jmLegacyFallbackDomains.includes(String(item))))
                  ) {
                    sourceType.apiDomains = jmBootstrapDomains.slice();
                  }
                  this.__source_runtime_inited = true;
                  return true;
                }).catch(() => {
                  if (sourceType && shouldBootstrapJM) {
                    sourceType.apiDomains = jmBootstrapDomains.slice();
                  }
                  this.__source_runtime_inited = true;
                  return false;
                });
              } else {
                this.__source_runtime_inited = true;
                this.__source_runtime_init_promise = Promise.resolve(true);
              }
            }
            await this.__source_runtime_init_promise;
          }
          return \(expression);
        })()
        """

        guard let function = context.evaluateScript("(function(){ return \(wrappedExpr); })") else {
            throw ScriptEngineError.invalidResult("failed to build expression call")
        }

        let compactExp = expression.replacingOccurrences(of: "\n", with: " ")
        jsDebugLog("Calling JS expression: \(compactExp.prefix(120))..., argsCount=\(arguments.count)")
        let output = function.call(withArguments: arguments)
        return try normalizeOutput(output, fallbackSourceKey: "demo")
    }

    func search(keyword: String, functionName: String = "search") throws -> [ComicSummary] {
        let result = try call(function: functionName, arguments: [keyword])
        return try Self.normalizeSearchResult(result, defaultSourceKey: "demo")
    }

    func searchSource(keyword: String, sourceKey: String, options: [String] = [], page: Int = 1) throws -> [ComicSummary] {
        let paged = try searchSourcePage(keyword: keyword, sourceKey: sourceKey, options: options, page: page, nextToken: nil)
        return paged.comics
    }

    func searchSourcePage(
        keyword: String,
        sourceKey: String,
        options: [String] = [],
        page: Int = 1,
        nextToken: String?
    ) throws -> ComicPageResult {
        jsDebugLog("searchSource start: sourceKey=\(sourceKey), keyword=\(keyword), options=\(options), page=\(page)", level: .info)
        let result = try callExpression(
            """
            (() => {
              const target = this.__source_temp && this.__source_temp.search;
              if (target && typeof target.load === 'function') {
                return target.load.call(this.__source_temp, arguments[0], arguments[1], arguments[2]);
              }
              if (target && typeof target.loadNext === 'function') {
                return target.loadNext.call(this.__source_temp, arguments[0], arguments[1], arguments[3] ?? null);
              }
              if (typeof target === 'function') {
                return target.call(this.__source_temp, arguments[0]);
              }
              throw new Error('search is not callable');
            })()
            """,
            arguments: [keyword, options, page, nextToken ?? NSNull()]
        )
        let object = (result as? [String: Any]) ?? [:]
        let normalized = try Self.normalizeSearchResult(object["comics"] ?? result, defaultSourceKey: sourceKey)
        let maxPage = object["maxPage"] as? Int
        let next = object["next"] as? String ?? object["nextToken"] as? String ?? object["token"] as? String
        jsDebugLog("searchSource success: sourceKey=\(sourceKey), resultCount=\(normalized.count), maxPage=\(String(describing: maxPage)), next=\(next ?? "nil")", level: .info)
        return ComicPageResult(comics: normalized, maxPage: maxPage, nextToken: next)
    }

    func getExplorePages() throws -> [ExplorePageItem] {
        let value = try callExpression("""
        (() => {
          const source = this.__source_temp;
          const explore = source && source.explore;
          if (!Array.isArray(explore)) return [];
          return explore.map((item, idx) => {
            const typeRaw = String(item?.type ?? '');
            let kind = null;
            if (typeRaw === 'multiPageComicList') {
              kind = 'multiPageComicList';
            } else if (typeRaw === 'multiPartPage' || typeRaw === 'singlePageWithMultiPart') {
              kind = 'singlePageWithMultiPart';
            } else if (typeRaw === 'mixed') {
              kind = 'mixed';
            }
            if (!kind) return null;
            return {
              id: String(idx),
              title: String(item?.title ?? `Explore ${idx + 1}`),
              kind
            };
          }).filter((x) => x != null);
        })()
        """)
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let title = row["title"] as? String,
                  let kindRaw = row["kind"] as? String,
                  let kind = ExplorePageKind(rawValue: kindRaw)
            else { return nil }
            return ExplorePageItem(id: id, title: title, kind: kind)
        }
    }

    func loadExploreComicsPage(
        sourceKey: String,
        pageIndex: Int,
        page: Int,
        nextToken: String?
    ) throws -> ComicPageResult {
        let result = try callExpression("""
        (async () => {
          const source = this.__source_temp;
          const explore = source && source.explore;
          const idx = Math.max(0, Math.floor(Number(arguments[0] ?? 0)));
          const pageNo = Math.max(1, Math.floor(Number(arguments[1] ?? 1)));
          const next = arguments[2];
          if (!Array.isArray(explore) || !explore[idx]) {
            throw new Error('explore page not found');
          }
          const entry = explore[idx];
          const type = String(entry?.type ?? '');
          if (type !== 'multiPageComicList') {
            throw new Error('explore page is not multiPageComicList');
          }
          let payload;
          if (typeof entry.load === 'function') {
            payload = await Promise.resolve(entry.load.call(source, pageNo));
          } else if (typeof entry.loadNext === 'function') {
            payload = await Promise.resolve(entry.loadNext.call(source, next ?? null));
          } else {
            throw new Error('explore.load/loadNext is not supported');
          }
          const root = (payload && typeof payload === 'object')
            ? ((payload.data && typeof payload.data === 'object') ? payload.data : payload)
            : {};
          const comics = Array.isArray(root.comics)
            ? root.comics
            : (Array.isArray(root.result) ? root.result : (Array.isArray(payload) ? payload : []));
          const rawMax = root.maxPage ?? root.totalPages ?? root.pages ?? root.subData ?? null;
          const maxPage = Number.isFinite(Number(rawMax)) ? Math.max(1, Math.floor(Number(rawMax))) : null;
          const nextRaw = root.next ?? root.nextToken ?? root.token ?? root.subData ?? null;
          const nextToken = (nextRaw == null || nextRaw === '') ? null : String(nextRaw);
          return { comics, maxPage, nextToken };
        })()
        """, arguments: [max(0, pageIndex), max(1, page), nextToken ?? NSNull()])

        guard let object = result as? [String: Any] else {
            return ComicPageResult(comics: [], maxPage: nil, nextToken: nil)
        }
        let comics = try Self.normalizeSearchResult(object["comics"] ?? [], defaultSourceKey: sourceKey)
        return ComicPageResult(
            comics: comics,
            maxPage: object["maxPage"] as? Int,
            nextToken: object["nextToken"] as? String
        )
    }

    func loadExploreMultiPart(sourceKey: String, pageIndex: Int) throws -> [ExplorePartData] {
        let result = try callExpression("""
        (async () => {
          const source = this.__source_temp;
          const explore = source && source.explore;
          const idx = Math.max(0, Math.floor(Number(arguments[0] ?? 0)));
          if (!Array.isArray(explore) || !explore[idx]) {
            throw new Error('explore page not found');
          }
          const entry = explore[idx];
          const type = String(entry?.type ?? '');
          if (type !== 'multiPartPage' && type !== 'singlePageWithMultiPart') {
            throw new Error('explore page is not multiPartPage');
          }
          if (typeof entry.load !== 'function') {
            throw new Error('explore.load is not supported');
          }
          const payload = await Promise.resolve(entry.load.call(source));

          const parseTarget = (raw) => {
            if (!raw) return null;
            if (typeof raw === 'string') {
              if (raw.startsWith('search:')) {
                return { page: 'search', keyword: raw.slice('search:'.length), category: null, param: null };
              }
              if (raw.startsWith('category:')) {
                const body = raw.slice('category:'.length);
                const at = body.indexOf('@');
                if (at >= 0) return { page: 'category', keyword: null, category: body.slice(0, at), param: body.slice(at + 1) };
                return { page: 'category', keyword: null, category: body, param: null };
              }
              return { page: raw, keyword: null, category: null, param: null };
            }
            if (typeof raw === 'object') {
              const page = String(raw.page ?? raw.action ?? 'category');
              return {
                page,
                keyword: raw.keyword != null ? String(raw.keyword) : null,
                category: raw.category != null ? String(raw.category) : null,
                param: raw.param != null ? String(raw.param) : null
              };
            }
            return null;
          };

          const asParts = (() => {
            if (Array.isArray(payload)) return payload;
            if (payload && typeof payload === 'object') {
              return Object.entries(payload).map(([k, v]) => ({ title: String(k), comics: Array.isArray(v) ? v : [] }));
            }
            return [];
          })();

          return asParts.map((part, i) => {
            const comics = Array.isArray(part?.comics) ? part.comics : [];
            return {
              id: String(i),
              title: String(part?.title ?? `Part ${i + 1}`),
              comics,
              viewMore: parseTarget(part?.viewMore ?? null)
            };
          });
        })()
        """, arguments: [max(0, pageIndex)])

        guard let rows = result as? [[String: Any]] else { return [] }
        return try rows.map { row in
            let comics = try Self.normalizeSearchResult(row["comics"] ?? [], defaultSourceKey: sourceKey)
            let targetObj = row["viewMore"] as? [String: Any]
            let target = targetObj.flatMap { targetObj -> CategoryJumpTarget? in
                guard let page = targetObj["page"] as? String else { return nil }
                return CategoryJumpTarget(
                    page: page,
                    keyword: targetObj["keyword"] as? String,
                    category: targetObj["category"] as? String,
                    param: targetObj["param"] as? String
                )
            }
            return ExplorePartData(
                id: row["id"] as? String ?? UUID().uuidString,
                title: row["title"] as? String ?? "Part",
                comics: comics,
                viewMore: target
            )
        }
    }

    func loadExploreMixed(sourceKey: String, pageIndex: Int, page: Int) throws -> ExploreMixedPageResult {
        let result = try callExpression("""
        (async () => {
          const source = this.__source_temp;
          const explore = source && source.explore;
          const idx = Math.max(0, Math.floor(Number(arguments[0] ?? 0)));
          const pageNo = Math.max(1, Math.floor(Number(arguments[1] ?? 1)));
          if (!Array.isArray(explore) || !explore[idx]) {
            throw new Error('explore page not found');
          }
          const entry = explore[idx];
          if (String(entry?.type ?? '') !== 'mixed' || typeof entry.load !== 'function') {
            throw new Error('explore mixed load is not supported');
          }
          const payload = await Promise.resolve(entry.load.call(source, pageNo));
          const root = (payload && typeof payload === 'object')
            ? ((payload.data && typeof payload.data === 'object') ? payload.data : payload)
            : {};
          const data = Array.isArray(root.data) ? root.data : (Array.isArray(payload) ? payload : []);

          const parseTarget = (raw) => {
            if (!raw) return null;
            if (typeof raw === 'string') {
              if (raw.startsWith('search:')) return { page: 'search', keyword: raw.slice('search:'.length), category: null, param: null };
              if (raw.startsWith('category:')) {
                const body = raw.slice('category:'.length);
                const at = body.indexOf('@');
                if (at >= 0) return { page: 'category', keyword: null, category: body.slice(0, at), param: body.slice(at + 1) };
                return { page: 'category', keyword: null, category: body, param: null };
              }
              return { page: raw, keyword: null, category: null, param: null };
            }
            if (typeof raw === 'object') {
              return {
                page: String(raw.page ?? raw.action ?? 'category'),
                keyword: raw.keyword != null ? String(raw.keyword) : null,
                category: raw.category != null ? String(raw.category) : null,
                param: raw.param != null ? String(raw.param) : null
              };
            }
            return null;
          };

          const blocks = data.map((it, i) => {
            if (Array.isArray(it)) {
              return { kind: 'comics', id: String(i), comics: it };
            }
            if (it && typeof it === 'object') {
              return {
                kind: 'part',
                id: String(i),
                title: String(it.title ?? `Part ${i + 1}`),
                comics: Array.isArray(it.comics) ? it.comics : [],
                viewMore: parseTarget(it.viewMore ?? null)
              };
            }
            return null;
          }).filter((x) => x != null);
          const rawMax = root.maxPage ?? root.totalPages ?? root.pages ?? root.subData ?? null;
          const maxPage = Number.isFinite(Number(rawMax)) ? Math.max(1, Math.floor(Number(rawMax))) : null;
          return { blocks, maxPage };
        })()
        """, arguments: [max(0, pageIndex), max(1, page)])

        var blocks: [ExploreMixedBlock] = []
        if let object = result as? [String: Any], let rows = object["blocks"] as? [[String: Any]] {
            blocks = try rows.compactMap { row in
                guard let kind = row["kind"] as? String else { return nil }
                if kind == "comics" {
                    let comics = try Self.normalizeSearchResult(row["comics"] ?? [], defaultSourceKey: sourceKey)
                    return .comics(id: row["id"] as? String ?? UUID().uuidString, items: comics)
                }
                if kind == "part" {
                    let comics = try Self.normalizeSearchResult(row["comics"] ?? [], defaultSourceKey: sourceKey)
                    let targetObj = row["viewMore"] as? [String: Any]
                    let target = targetObj.flatMap { t -> CategoryJumpTarget? in
                        guard let page = t["page"] as? String else { return nil }
                        return CategoryJumpTarget(
                            page: page,
                            keyword: t["keyword"] as? String,
                            category: t["category"] as? String,
                            param: t["param"] as? String
                        )
                    }
                    return .part(
                        ExplorePartData(
                            id: row["id"] as? String ?? UUID().uuidString,
                            title: row["title"] as? String ?? "Part",
                            comics: comics,
                            viewMore: target
                        )
                    )
                }
                return nil
            }
        }
        let maxPage = (result as? [String: Any])?["maxPage"] as? Int
        return ExploreMixedPageResult(blocks: blocks, maxPage: maxPage)
    }

    func getCategoryPageProfile() throws -> CategoryPageProfile {
        let value = try callExpression("""
        (async () => {
          const source = this.__source_temp;
          const category = source && source.category;
          if (!category || typeof category !== 'object') return null;
          if (typeof category.title !== 'string' || category.title.length === 0) return null;

          const parseTarget = (raw, fallbackLabel, partName, itemType, param) => {
            const asObj = (page, keyword, cat, p) => ({ page, keyword, category: cat, param: p });
            if (raw && typeof raw === 'object') {
              const page = String(raw.page ?? raw.action ?? itemType ?? 'category');
              const keyword = raw.keyword != null ? String(raw.keyword) : null;
              const category = raw.category != null ? String(raw.category) : (page === 'category' ? String(raw.keyword ?? fallbackLabel) : null);
              const rp = raw.param != null ? String(raw.param) : (param != null ? String(param) : null);
              return asObj(page, keyword, category, rp);
            }
            if (typeof raw === 'string') {
              if (raw.startsWith('search:')) {
                return asObj('search', raw.slice('search:'.length), null, null);
              }
              if (raw.startsWith('category:')) {
                const body = raw.slice('category:'.length);
                const at = body.indexOf('@');
                if (at >= 0) return asObj('category', null, body.slice(0, at), body.slice(at + 1));
                return asObj('category', null, body, null);
              }
              return asObj(raw, null, null, null);
            }
            if (itemType === 'search') return asObj('search', fallbackLabel, null, null);
            if (itemType === 'search_with_namespace') return asObj('search', `${partName}:${fallbackLabel}`, null, null);
            return asObj('category', null, fallbackLabel, param != null ? String(param) : null);
          };

          const partsRaw = Array.isArray(category.parts) ? category.parts : [];
          const parts = await Promise.all(partsRaw.map(async (part, partIdx) => {
            const name = String(part?.name ?? `Part ${partIdx + 1}`);
            const type = String(part?.type ?? 'fixed');
            const randomNumber = Number.isFinite(Number(part?.randomNumber)) ? Math.max(1, Math.floor(Number(part.randomNumber))) : null;

            let categories = Array.isArray(part?.categories) ? part.categories : [];
            if (type === 'dynamic' && categories.length === 0 && typeof part?.loader === 'function') {
              try {
                let loaded;
                try {
                  loaded = await Promise.resolve(part.loader.call(part));
                } catch (_) {
                  loaded = await Promise.resolve(part.loader.call(source));
                }
                if (Array.isArray(loaded)) categories = loaded;
              } catch (_) {}
            }
            const itemType = String(part?.itemType ?? 'category');
            const categoryParams = Array.isArray(part?.categoryParams) ? part.categoryParams.map((x) => String(x)) : null;
            const groupParam = part?.groupParam != null ? String(part.groupParam) : null;

            const items = categories.map((c, i) => {
              if (c && typeof c === 'object' && !Array.isArray(c)) {
                const label = String(c.label ?? c.title ?? c.name ?? `Category ${i + 1}`);
                const target = parseTarget(c.target, label, name, itemType, null);
                return { id: `${partIdx}_${i}`, label, target };
              }
              const label = String(c);
              const param = groupParam != null ? groupParam : (categoryParams && i < categoryParams.length ? categoryParams[i] : null);
              const target = parseTarget(null, label, name, itemType, param);
              return { id: `${partIdx}_${i}`, label, target };
            });

            return { id: String(partIdx), title: name, type, randomNumber, items };
          }));
          const filteredParts = parts.filter((x) => Array.isArray(x.items) && x.items.length > 0);

          return {
            title: String(category.title),
            key: String(category.key ?? category.title),
            enableRankingPage: !!category.enableRankingPage,
            parts: filteredParts
          };
        })()
        """)

        guard let object = value as? [String: Any] else {
            return .empty
        }
        let partsRaw = object["parts"] as? [[String: Any]] ?? []
        let parts: [CategoryPartData] = partsRaw.compactMap { part in
            guard let id = part["id"] as? String,
                  let title = part["title"] as? String,
                  let type = part["type"] as? String
            else { return nil }
            let itemsRaw = part["items"] as? [[String: Any]] ?? []
            let items: [CategoryItemData] = itemsRaw.compactMap { item in
                guard let iid = item["id"] as? String,
                      let label = item["label"] as? String,
                      let targetObj = item["target"] as? [String: Any],
                      let page = targetObj["page"] as? String
                else { return nil }
                return CategoryItemData(
                    id: iid,
                    label: label,
                    target: CategoryJumpTarget(
                        page: page,
                        keyword: targetObj["keyword"] as? String,
                        category: targetObj["category"] as? String,
                        param: targetObj["param"] as? String
                    )
                )
            }
            return CategoryPartData(
                id: id,
                title: title,
                type: type,
                randomNumber: part["randomNumber"] as? Int,
                items: items
            )
        }

        return CategoryPageProfile(
            title: object["title"] as? String ?? "",
            key: object["key"] as? String ?? "",
            enableRankingPage: object["enableRankingPage"] as? Bool ?? false,
            parts: parts
        )
    }

    func getCategoryComicsOptionGroups(category: String, param: String?) throws -> [CategoryComicsOptionGroup] {
        let value = try callExpression("""
        (async () => {
          const source = this.__source_temp;
          const cc = source && source.categoryComics;
          if (!cc || typeof cc !== 'object') return [];
          let optionList = Array.isArray(cc.optionList) ? cc.optionList : null;
          if ((!optionList || optionList.length === 0) && typeof cc.optionLoader === 'function') {
            try {
              let loaded;
              try {
                loaded = await Promise.resolve(cc.optionLoader.call(cc, arguments[0], arguments[1]));
              } catch (_) {
                loaded = await Promise.resolve(cc.optionLoader.call(source, arguments[0], arguments[1]));
              }
              if (Array.isArray(loaded)) optionList = loaded;
            } catch (_) {}
          }
          if (!Array.isArray(optionList)) return [];
          return optionList.map((item, idx) => {
            const opts = Array.isArray(item?.options) ? item.options : [];
            const mapped = opts.map((o, optionIdx) => {
              if (o && typeof o === 'object' && !Array.isArray(o)) {
                const value = String(o.value ?? o.id ?? o.key ?? '');
                const label = String(o.label ?? o.text ?? o.title ?? value);
                return {
                  id: `${idx}_${optionIdx}`,
                  value,
                  label
                };
              }
              const text = String(o ?? '');
              const dash = text.indexOf('-');
              if (dash >= 0) {
                return {
                  id: `${idx}_${optionIdx}`,
                  value: text.slice(0, dash),
                  label: text.slice(dash + 1)
                };
              }
              return { id: `${idx}_${optionIdx}`, value: text, label: text };
            }).filter((x) => x.value.length > 0 || x.label.length > 0);
            return {
              id: String(idx),
              label: item?.label != null ? String(item.label) : `Option ${idx + 1}`,
              notShowWhen: Array.isArray(item?.notShowWhen) ? item.notShowWhen.map((x) => String(x)) : [],
              showWhen: Array.isArray(item?.showWhen) ? item.showWhen.map((x) => String(x)) : null,
              options: mapped
            };
          });
        })()
        """, arguments: [category, param ?? NSNull()])

        guard let array = value as? [[String: Any]] else { return [] }
        return array.compactMap { groupObj in
            guard let id = groupObj["id"] as? String,
                  let label = groupObj["label"] as? String
            else { return nil }
            let optionsObj = groupObj["options"] as? [[String: Any]] ?? []
            let options = optionsObj.compactMap { opt -> CategoryComicsOptionItem? in
                guard let oid = opt["id"] as? String,
                      let value = opt["value"] as? String,
                      let text = opt["label"] as? String
                else { return nil }
                return CategoryComicsOptionItem(id: oid, value: value, label: text)
            }
            return CategoryComicsOptionGroup(
                id: id,
                label: label,
                options: options,
                notShowWhen: groupObj["notShowWhen"] as? [String] ?? [],
                showWhen: groupObj["showWhen"] as? [String]
            )
        }
    }

    func getCategoryRankingProfile() throws -> CategoryRankingProfile {
        let value = try callExpression("""
        (() => {
          const source = this.__source_temp;
          const cc = source && source.categoryComics;
          const ranking = cc && cc.ranking;
          if (!ranking || typeof ranking !== 'object') {
            return { options: [], supportsLoadPage: false, supportsLoadNext: false };
          }
          const rawOptions = Array.isArray(ranking.options) ? ranking.options : [];
          const options = rawOptions.map((o, idx) => {
            if (o && typeof o === 'object' && !Array.isArray(o)) {
              const value = String(o.value ?? o.id ?? o.key ?? '');
              const label = String(o.label ?? o.text ?? o.title ?? value);
              return {
                id: String(idx),
                value,
                label
              };
            }
            const text = String(o ?? '');
            const dash = text.indexOf('-');
            if (dash >= 0) {
              return {
                id: String(idx),
                value: text.slice(0, dash),
                label: text.slice(dash + 1)
              };
            }
            return { id: String(idx), value: text, label: text };
          }).filter((x) => x.value.length > 0 || x.label.length > 0);
          return {
            options,
            supportsLoadPage: typeof ranking.load === 'function',
            supportsLoadNext: (typeof ranking.loadWithNext === 'function') || (typeof ranking.loadNext === 'function')
          };
        })()
        """)

        guard let object = value as? [String: Any] else { return .empty }
        let optionsObj = object["options"] as? [[String: Any]] ?? []
        let options = optionsObj.compactMap { opt -> CategoryComicsOptionItem? in
            guard let id = opt["id"] as? String,
                  let value = opt["value"] as? String,
                  let label = opt["label"] as? String
            else { return nil }
            return CategoryComicsOptionItem(id: id, value: value, label: label)
        }
        return CategoryRankingProfile(
            options: options,
            supportsLoadPage: object["supportsLoadPage"] as? Bool ?? false,
            supportsLoadNext: object["supportsLoadNext"] as? Bool ?? false
        )
    }

    func loadCategoryComics(
        sourceKey: String,
        category: String,
        param: String?,
        options: [String],
        page: Int,
        nextToken: String?
    ) throws -> CategoryComicsPage {
        jsDebugLog("loadCategoryComics start: sourceKey=\(sourceKey), category=\(category), param=\(param ?? "nil"), options=\(options), page=\(page)", level: .info)
        let result = try callExpression("""
        (async () => {
          const source = this.__source_temp;
          const cc = source && source.categoryComics;
          const hasLoad = !!(cc && typeof cc.load === 'function');
          const hasLoadNext = !!(cc && typeof cc.loadNext === 'function');
          if (!hasLoad && !hasLoadNext) {
            throw new Error('categoryComics.load/loadNext is not supported by this source');
          }

          const isAppend = !!arguments[5];
          const reqNextToken = arguments[4] ?? null;
          let payload;
          if (isAppend && hasLoadNext && reqNextToken != null) {
            payload = await (async () => {
              try {
                return await Promise.resolve(cc.loadNext.call(cc, reqNextToken, arguments[0], arguments[1], arguments[2]));
              } catch (_) {
                return await Promise.resolve(cc.loadNext.call(source, reqNextToken, arguments[0], arguments[1], arguments[2]));
              }
            })();
          } else {
            if (hasLoad) {
              payload = await (async () => {
                try {
                  return await Promise.resolve(cc.load.call(cc, arguments[0], arguments[1], arguments[2], arguments[3]));
                } catch (_) {
                  return await Promise.resolve(cc.load.call(source, arguments[0], arguments[1], arguments[2], arguments[3]));
                }
              })();
            } else {
              payload = await (async () => {
                try {
                  return await Promise.resolve(cc.loadNext.call(cc, reqNextToken, arguments[0], arguments[1], arguments[2]));
                } catch (_) {
                  return await Promise.resolve(cc.loadNext.call(source, reqNextToken, arguments[0], arguments[1], arguments[2]));
                }
              })();
            }
          }

          const root = payload && typeof payload === 'object'
            ? ((payload.data && typeof payload.data === 'object') ? payload.data : payload)
            : {};
          const pickArray = (obj, path) => {
            let cur = obj;
            for (let i = 0; i < path.length; i += 1) {
              if (!cur || typeof cur !== 'object') return null;
              cur = cur[path[i]];
            }
            return Array.isArray(cur) ? cur : null;
          };
          const comics =
            pickArray(root, ['comics']) ??
            pickArray(root, ['list']) ??
            pickArray(root, ['data', 'comics']) ??
            pickArray(root, ['data', 'list']) ??
            pickArray(root, ['results', 'list']) ??
            pickArray(root, ['results', 'comics']) ??
            pickArray(payload, ['results', 'list']) ??
            pickArray(payload, ['results', 'comics']) ??
            (Array.isArray(payload) ? payload : []);

          const rawMax = root.maxPage ?? root.totalPages ?? root.pages ?? root.subData ?? payload?.subData ?? null;
          const maxPage = Number.isFinite(Number(rawMax)) ? Math.max(1, Math.floor(Number(rawMax))) : null;
          const nextRaw = root.next ?? root.nextToken ?? root.token ?? payload?.next ?? payload?.nextToken ?? payload?.token ?? null;
          const nextTokenOut = (nextRaw == null || nextRaw === '') ? null : String(nextRaw);
          return { comics, maxPage, nextToken: nextTokenOut };
        })()
        """, arguments: [category, param ?? NSNull(), options, max(1, page), nextToken ?? NSNull(), (nextToken != nil)])

        guard let object = result as? [String: Any] else {
            return CategoryComicsPage(comics: [], maxPage: nil, nextToken: nil)
        }
        let comics = try Self.normalizeSearchResult(object["comics"] ?? [], defaultSourceKey: sourceKey)
        let maxPage = object["maxPage"] as? Int
        let nextToken = object["nextToken"] as? String
        jsDebugLog("loadCategoryComics success: sourceKey=\(sourceKey), count=\(comics.count), maxPage=\(String(describing: maxPage)), nextToken=\(nextToken ?? "nil")", level: .info)
        return CategoryComicsPage(comics: comics, maxPage: maxPage, nextToken: nextToken)
    }

    func loadCategoryRanking(
        sourceKey: String,
        option: String,
        page: Int,
        nextToken: String?
    ) throws -> CategoryComicsPage {
        jsDebugLog("loadCategoryRanking start: sourceKey=\(sourceKey), option=\(option), page=\(page), next=\(nextToken ?? "nil")", level: .info)
        let result = try callExpression("""
        (async () => {
          const source = this.__source_temp;
          const cc = source && source.categoryComics;
          const ranking = cc && cc.ranking;
          if (!ranking || typeof ranking !== 'object') {
            throw new Error('categoryComics.ranking is not supported by this source');
          }
          let payload;
          const hasLoad = typeof ranking.load === 'function';
          const hasLoadWithNext = typeof ranking.loadWithNext === 'function';
          const hasLoadNext = typeof ranking.loadNext === 'function';
          if (hasLoad) {
            try {
              payload = await Promise.resolve(ranking.load.call(ranking, arguments[0], arguments[1]));
            } catch (_) {
              payload = await Promise.resolve(ranking.load.call(source, arguments[0], arguments[1]));
            }
          } else if (hasLoadWithNext || hasLoadNext) {
            const fn = hasLoadWithNext ? ranking.loadWithNext : ranking.loadNext;
            try {
              payload = await Promise.resolve(fn.call(ranking, arguments[0], arguments[2]));
            } catch (_) {
              payload = await Promise.resolve(fn.call(source, arguments[0], arguments[2]));
            }
          } else {
            throw new Error('categoryComics.ranking has no load function');
          }
          const root = payload && typeof payload === 'object' ? payload : {};
          const comics = Array.isArray(root.comics)
            ? root.comics
            : (Array.isArray(root.data?.comics)
              ? root.data.comics
              : (Array.isArray(root.results?.list)
                ? root.results.list
                : (Array.isArray(root.results?.comics)
                  ? root.results.comics
                  : (Array.isArray(payload) ? payload : []))));
          const rawMax = root.maxPage ?? root.totalPages ?? root.pages ?? root.subData ?? null;
          const maxPage = Number.isFinite(Number(rawMax)) ? Math.max(1, Math.floor(Number(rawMax))) : null;
          const nextRaw = root.next ?? root.nextToken ?? root.token ?? root.subData ?? null;
          const nextToken = (nextRaw == null || nextRaw === '') ? null : String(nextRaw);
          return { comics, maxPage, nextToken };
        })()
        """, arguments: [option, max(1, page), nextToken ?? NSNull()])

        guard let object = result as? [String: Any] else {
            return CategoryComicsPage(comics: [], maxPage: nil, nextToken: nil)
        }
        let comics = try Self.normalizeSearchResult(object["comics"] ?? [], defaultSourceKey: sourceKey)
        let maxPage = object["maxPage"] as? Int
        let next = object["nextToken"] as? String
        jsDebugLog("loadCategoryRanking success: sourceKey=\(sourceKey), count=\(comics.count), maxPage=\(String(describing: maxPage)), next=\(next ?? "nil")", level: .info)
        return CategoryComicsPage(comics: comics, maxPage: maxPage, nextToken: next)
    }

    func getLoginProfile() throws -> LoginProfile {
        let value = try callExpression("""
        (() => {
          const account = this.__source_temp && this.__source_temp.account;
          const web = account && (account.loginWithWebview || account.loginWithWebView);
          const cookie = account && account.loginWithCookies;
          const fields = cookie && Array.isArray(cookie.fields) ? cookie.fields.map((x) => String(x)) : [];
          const registerWebsite = account && typeof account.registerWebsite === 'string' ? account.registerWebsite : null;
          const webURL = web && typeof web.url === 'string' && web.url.startsWith('http') ? web.url : null;
          return {
            hasAccountLogin: !!(account && typeof account.login === 'function'),
            hasWebLogin: !!(web && typeof web.url === 'string' && web.url.length > 0),
            hasCookieLogin: !!(cookie && Array.isArray(cookie.fields) && typeof cookie.validate === 'function'),
            webLoginURL: webURL,
            registerWebsite: registerWebsite,
            cookieFields: fields
          };
        })()
        """)

        guard let object = value as? [String: Any] else {
            return LoginProfile(
                hasAccountLogin: false,
                hasWebLogin: false,
                hasCookieLogin: false,
                webLoginURL: nil,
                registerWebsite: nil,
                cookieFields: []
            )
        }

        return LoginProfile(
            hasAccountLogin: object["hasAccountLogin"] as? Bool ?? false,
            hasWebLogin: object["hasWebLogin"] as? Bool ?? false,
            hasCookieLogin: object["hasCookieLogin"] as? Bool ?? false,
            webLoginURL: object["webLoginURL"] as? String,
            registerWebsite: object["registerWebsite"] as? String,
            cookieFields: object["cookieFields"] as? [String] ?? []
        )
    }

    func getSearchOptionGroups() throws -> [SearchOptionGroup] {
        let value = try callExpression("""
        (() => {
          const search = this.__source_temp && this.__source_temp.search;
          const optionList = search && Array.isArray(search.optionList) ? search.optionList : [];
          return optionList.map((item, idx) => {
            const groupType = item.type ? String(item.type) : "select";
            const opts = Array.isArray(item.options) ? item.options : [];
            const mapped = opts.map((o, optionIdx) => {
              if (typeof o === 'string') {
                const dash = o.indexOf('-');
                if (dash >= 0) {
                  return {
                    id: `${idx}_${optionIdx}`,
                    value: o.slice(0, dash),
                    label: o.slice(dash + 1)
                  };
                }
                return { id: `${idx}_${optionIdx}`, value: o, label: o };
              }
              if (o && typeof o === 'object') {
                const value = (o.value ?? o.key ?? o.id ?? '').toString();
                const label = (o.text ?? o.title ?? o.label ?? value).toString();
                return { id: `${idx}_${optionIdx}`, value, label };
              }
              const text = String(o);
              return { id: `${idx}_${optionIdx}`, value: text, label: text };
            });

            let def = item.default;
            if (Array.isArray(def)) {
              def = JSON.stringify(def.map((v) => String(v)));
            } else if (def != null) {
              def = String(def);
            } else {
              if (groupType === "multi-select") {
                def = "[]";
              } else if (groupType === "dropdown") {
                def = null;
              } else {
                def = mapped.length > 0 ? mapped[0].value : null;
              }
            }

            return {
              id: String(idx),
              label: item.label ? String(item.label) : `Option ${idx + 1}`,
              type: groupType,
              defaultValue: def,
              options: mapped
            };
          });
        })()
        """)

        guard let array = value as? [[String: Any]] else { return [] }
        return array.compactMap { groupObj in
            guard
                let id = groupObj["id"] as? String,
                let label = groupObj["label"] as? String,
                let type = groupObj["type"] as? String
            else {
                return nil
            }
            let optionsObj = groupObj["options"] as? [[String: Any]] ?? []
            let options = optionsObj.compactMap { opt -> SearchOptionItem? in
                guard
                    let oid = opt["id"] as? String,
                    let value = opt["value"] as? String,
                    let text = opt["label"] as? String
                else {
                    return nil
                }
                return SearchOptionItem(id: oid, value: value, label: text)
            }
            return SearchOptionGroup(
                id: id,
                label: label,
                type: type,
                defaultValue: groupObj["defaultValue"] as? String,
                options: options
            )
        }
    }

    func getSearchFeatureProfile() throws -> SearchFeatureProfile {
        let value = try callExpression("""
        (() => {
          const search = this.__source_temp && this.__source_temp.search;
          if (!search || typeof search !== 'object') {
            return {
              hasKeywordSearch: false,
              supportsPagedKeywordSearch: false,
              supportsLoadPage: false,
              supportsLoadNext: false,
              optionGroupCount: 0,
              availableMethods: []
            };
          }
          const target = search.search;
          const optionList = Array.isArray(search.optionList) ? search.optionList : [];
          const methodNames = Object.keys(search)
            .filter((key) => typeof search[key] === 'function')
            .sort();
          const searchArity = typeof target === 'function' ? target.length : 0;
          return {
            hasKeywordSearch: typeof target === 'function',
            supportsPagedKeywordSearch: typeof target === 'function' && searchArity >= 3,
            supportsLoadPage: typeof search.loadPage === 'function',
            supportsLoadNext: typeof search.loadNext === 'function',
            optionGroupCount: optionList.length,
            availableMethods: methodNames
          };
        })()
        """)

        guard let object = value as? [String: Any] else {
            return .empty
        }

        return SearchFeatureProfile(
            hasKeywordSearch: object["hasKeywordSearch"] as? Bool ?? false,
            supportsPagedKeywordSearch: object["supportsPagedKeywordSearch"] as? Bool ?? false,
            supportsLoadPage: object["supportsLoadPage"] as? Bool ?? false,
            supportsLoadNext: object["supportsLoadNext"] as? Bool ?? false,
            optionGroupCount: object["optionGroupCount"] as? Int ?? 0,
            availableMethods: object["availableMethods"] as? [String] ?? []
        )
    }

    func getSourceCapabilityProfile() throws -> SourceCapabilityProfile {
        let value = try callExpression("""
        (() => {
          const source = this.__source_temp;
          const search = source && source.search;
          const favorites = source && source.favorites;
          const comic = source && source.comic;
          const account = source && source.account;
          const web = account && (account.loginWithWebview || account.loginWithWebView);
          const cookie = account && account.loginWithCookies;
          const settings = source && source.settings;
          const searchMethods = search && typeof search === 'object'
            ? Object.keys(search).filter((key) => typeof search[key] === 'function').sort()
            : [];
          const settingKeys = settings && typeof settings === 'object'
            ? Object.keys(settings)
            : [];
          const searchOptionGroupCount = search && Array.isArray(search.optionList)
            ? search.optionList.length
            : 0;
          return {
            hasExplore: Array.isArray(source && source.explore) && source.explore.length > 0,
            hasCategory: !!(source && source.category && typeof source.category === 'object'),
            hasSearch: !!(search && typeof search === 'object' && (
              typeof search.search === 'function' ||
              typeof search.loadPage === 'function' ||
              typeof search.loadNext === 'function'
            )),
            hasFavorites: !!(favorites && typeof favorites === 'object' && (
              typeof favorites.loadComics === 'function' ||
              typeof favorites.loadNext === 'function' ||
              typeof favorites.addOrDelFavorite === 'function'
            )),
            hasComments: !!(comic && typeof comic === 'object' && (
              typeof comic.loadComments === 'function' ||
              typeof comic.sendComment === 'function' ||
              typeof comic.likeComment === 'function' ||
              typeof comic.voteComment === 'function'
            )),
            hasAccountLogin: !!(account && typeof account.login === 'function'),
            hasWebLogin: !!(web && typeof web.url === 'string' && web.url.length > 0),
            hasCookieLogin: !!(cookie && Array.isArray(cookie.fields) && typeof cookie.validate === 'function'),
            hasSettings: settingKeys.length > 0,
            searchOptionGroupCount,
            settingCount: settingKeys.length,
            availableSearchMethods: searchMethods
          };
        })()
        """)

        guard let object = value as? [String: Any] else {
            return .empty
        }

        return SourceCapabilityProfile(
            hasExplore: object["hasExplore"] as? Bool ?? false,
            hasCategory: object["hasCategory"] as? Bool ?? false,
            hasSearch: object["hasSearch"] as? Bool ?? false,
            hasFavorites: object["hasFavorites"] as? Bool ?? false,
            hasComments: object["hasComments"] as? Bool ?? false,
            hasAccountLogin: object["hasAccountLogin"] as? Bool ?? false,
            hasWebLogin: object["hasWebLogin"] as? Bool ?? false,
            hasCookieLogin: object["hasCookieLogin"] as? Bool ?? false,
            hasSettings: object["hasSettings"] as? Bool ?? false,
            searchOptionGroupCount: object["searchOptionGroupCount"] as? Int ?? 0,
            settingCount: object["settingCount"] as? Int ?? 0,
            availableSearchMethods: object["availableSearchMethods"] as? [String] ?? []
        )
    }

    func getSourceSettings() throws -> [SourceSettingDefinition] {
        let value = try callExpression("""
        (() => {
          const source = this.__source_temp;
          const settings = source && source.settings;
          if (!settings || typeof settings !== 'object') {
            return [];
          }
          return Object.entries(settings).map(([key, item], idx) => {
            if (!item || typeof item !== 'object') {
              return null;
            }
            const type = typeof item.type === 'string' ? item.type : 'input';
            const title = typeof item.title === 'string' && item.title.length > 0 ? item.title : key;
            const currentRaw = typeof source.loadSetting === 'function'
              ? source.loadSetting(key)
              : (Object.prototype.hasOwnProperty.call(item, 'default') ? item.default : item.value);
            const currentStringValue = currentRaw == null ? '' : String(currentRaw);
            const currentBoolValue = currentRaw === true ||
              currentRaw === 'true' ||
              currentRaw === 1 ||
              currentRaw === '1';
            const options = Array.isArray(item.options)
              ? item.options.map((option, optionIdx) => {
                  if (typeof option === 'string') {
                    const dash = option.indexOf('-');
                    if (dash >= 0) {
                      return {
                        id: `${idx}_${optionIdx}`,
                        value: option.slice(0, dash),
                        label: option.slice(dash + 1)
                      };
                    }
                    return { id: `${idx}_${optionIdx}`, value: option, label: option };
                  }
                  if (option && typeof option === 'object') {
                    const value = String(option.value ?? option.key ?? option.id ?? '');
                    const label = String(option.text ?? option.title ?? option.label ?? value);
                    return { id: `${idx}_${optionIdx}`, value, label };
                  }
                  const text = String(option);
                  return { id: `${idx}_${optionIdx}`, value: text, label: text };
                })
              : [];
            const defaultRaw = Object.prototype.hasOwnProperty.call(item, 'default')
              ? item.default
              : (Object.prototype.hasOwnProperty.call(item, 'value') ? item.value : null);
            return {
              id: String(key),
              key: String(key),
              title,
              type,
              defaultValue: defaultRaw == null ? null : String(defaultRaw),
              currentStringValue,
              currentBoolValue,
              options
            };
          }).filter((item) => item !== null);
        })()
        """)

        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { object -> SourceSettingDefinition? in
            guard let id = object["id"] as? String,
                  let key = object["key"] as? String,
                  let title = object["title"] as? String,
                  let type = object["type"] as? String
            else {
                return nil
            }
            let options = (object["options"] as? [[String: Any]] ?? []).compactMap { optionObject -> SourceSettingOption? in
                guard let optionID = optionObject["id"] as? String,
                      let value = optionObject["value"] as? String,
                      let label = optionObject["label"] as? String
                else {
                    return nil
                }
                return SourceSettingOption(id: optionID, value: value, label: label)
            }
            return SourceSettingDefinition(
                id: id,
                key: key,
                title: title,
                type: type,
                defaultValue: object["defaultValue"] as? String,
                currentStringValue: object["currentStringValue"] as? String ?? "",
                currentBoolValue: object["currentBoolValue"] as? Bool ?? false,
                options: options
            )
        }
    }

    func saveSourceSetting(key: String, value: Any) throws {
        _ = try callExpression(
            """
            (() => {
              const source = this.__source_temp;
              if (!source || typeof source.saveSetting !== 'function') {
                throw new Error('Source settings are not supported by this source');
              }
              source.saveSetting(arguments[0], arguments[1]);
              return source.loadSetting(arguments[0]);
            })()
            """,
            arguments: [key, value]
        )
    }

    func getIsLogged() throws -> Bool? {
        let value = try callExpression("""
        (() => {
          const source = this.__source_temp;
          if (!source) return null;
          try {
            if (typeof source.isLogged === 'boolean') {
              return source.isLogged;
            }
            if (typeof source.isLogged === 'function') {
              return !!source.isLogged.call(source);
            }
          } catch (_) {}
          const account = source.account;
          try {
            if (account && typeof account.isLogged === 'boolean') {
              return account.isLogged;
            }
            if (account && typeof account.isLogged === 'function') {
              return !!account.isLogged.call(account);
            }
          } catch (_) {}
          return null;
        })()
        """)
        if value is NSNull { return nil }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    func hasAccountLogin() throws -> Bool {
        let value = try callExpression("""
        (() => {
          const a = this.__source_temp && this.__source_temp.account;
          return !!(a && typeof a.login === 'function');
        })()
        """)
        return (value as? Bool) ?? false
    }

    func getWebLoginURL() throws -> String? {
        let value = try callExpression("""
        (() => {
          const a = this.__source_temp && this.__source_temp.account;
          const web = a && (a.loginWithWebview || a.loginWithWebView);
          const u = web && web.url;
          return (typeof u === 'string' && u.startsWith('http')) ? u : '';
        })()
        """)
        let url = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return url.isEmpty ? nil : url
    }

    func loginSource(account: String, password: String) throws -> String {
        let result = try callExpression(
            """
            (async () => {
              const source = this.__source_temp;
              const accountRuntime = source && source.account;
              if (!source || !accountRuntime || typeof accountRuntime.login !== 'function') {
                throw new Error('Account login is not supported by this source');
              }
              const sourceType = source.constructor;
              const jmBootstrapDomains = [
                'www.cdnzack.cc',
                'www.cdnhth.cc',
                'www.cdnhth.net',
                'www.cdnbea.net'
              ];
              const jmLegacyFallbackDomains = [
                'www.cdntwice.org',
                'www.cdnsha.org',
                'www.cdnaspa.cc',
                'www.cdnntr.cc'
              ];
              if (typeof source.refreshApiDomains === 'function') {
                try {
                  await Promise.resolve(source.refreshApiDomains.call(source, false));
                } catch (_) {}
              }
              if (
                String(source.key || '').toLowerCase() === 'jm' &&
                sourceType &&
                (!Array.isArray(sourceType.apiDomains) ||
                 sourceType.apiDomains.every((item) => jmLegacyFallbackDomains.includes(String(item))))
              ) {
                sourceType.apiDomains = jmBootstrapDomains.slice();
              }
              return await Promise.resolve(
                accountRuntime.login.apply(accountRuntime, arguments)
              );
            })()
            """,
            arguments: [account, password]
        )

        if let text = result as? String {
            return text
        }
        if result is NSNull {
            return "ok"
        }
        if JSONSerialization.isValidJSONObject(result),
           let data = try? JSONSerialization.data(withJSONObject: result),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: result)
    }

    func validateCookieLogin(values: [String]) throws -> Bool {
        let result = try callExpression(
            """
            (() => {
              const account = this.__source_temp && this.__source_temp.account;
              const cookie = account && account.loginWithCookies;
              if (!cookie || typeof cookie.validate !== 'function') {
                throw new Error("Cookie login is not supported by this source");
              }
              return cookie.validate.apply(cookie, arguments);
            })()
            """,
            arguments: [values]
        )
        if let bool = result as? Bool { return bool }
        if let number = result as? NSNumber { return number.boolValue }
        return false
    }

    func checkWebLoginStatus(url: String, title: String) throws -> Bool {
        let result = try callExpression(
            """
            (() => {
              const account = this.__source_temp && this.__source_temp.account;
              const web = account && (account.loginWithWebview || account.loginWithWebView);
              if (!web || typeof web.checkStatus !== 'function') {
                return false;
              }
              return !!web.checkStatus.apply(web, arguments);
            })()
            """,
            arguments: [url, title]
        )
        return (result as? Bool) ?? false
    }

    func onWebLoginSuccess() throws {
        _ = try callExpression(
            """
            (() => {
              const account = this.__source_temp && this.__source_temp.account;
              const web = account && (account.loginWithWebview || account.loginWithWebView);
              if (web && typeof web.onLoginSuccess === 'function') {
                return web.onLoginSuccess.call(web);
              }
              return null;
            })()
            """
        )
    }

    func loadComicInfo(comicID: String) throws -> ComicDetail {
        let result = try callExpression(
            """
            (() => {
              const comic = this.__source_temp && this.__source_temp.comic;
              if (!comic || typeof comic.loadInfo !== 'function') {
                throw new Error("comic.loadInfo is not supported by this source");
              }
              return Promise.resolve(
                comic.loadInfo.apply(this.__source_temp, arguments)
              ).then((info) => {
                const chaptersRaw = info && info.chapters;
                const tagsRaw = info && info.tags;
                let chapters = [];
                if (chaptersRaw instanceof Map) {
                  chapters = Array.from(chaptersRaw.entries()).map((x) => ({ id: String(x[0]), title: String(x[1]) }));
                } else if (Array.isArray(chaptersRaw)) {
                  chapters = chaptersRaw.map((x, idx) => {
                    if (x && typeof x === 'object') {
                      return {
                        id: String(x.id ?? x.key ?? x.order ?? idx + 1),
                        title: String(x.title ?? x.name ?? x.text ?? x.id ?? idx + 1)
                      };
                    }
                    return { id: String(idx + 1), title: String(x) };
                  });
                } else if (chaptersRaw && typeof chaptersRaw === 'object') {
                  chapters = Object.entries(chaptersRaw).map(([k, v]) => ({ id: String(k), title: String(v) }));
                }

                const normalizeValues = (val) => {
                  if (Array.isArray(val)) {
                    return val.map((x) => String(x)).filter((x) => x.length > 0);
                  }
                  if (val === null || val === undefined) return [];
                  return [String(val)].filter((x) => x.length > 0);
                };

                let tags = [];
                if (tagsRaw instanceof Map) {
                  tags = Array.from(tagsRaw.entries()).map(([k, v], idx) => ({
                    id: `tag_${idx}_${String(k)}`,
                    title: String(k),
                    values: normalizeValues(v)
                  }));
                } else if (Array.isArray(tagsRaw)) {
                  tags = tagsRaw.map((it, idx) => {
                    if (it && typeof it === 'object') {
                      const title = String(it.title ?? it.name ?? it.key ?? idx + 1);
                      const values = normalizeValues(it.values ?? it.tags ?? it.items ?? it.value);
                      return { id: String(it.id ?? `tag_${idx}`), title, values };
                    }
                    return { id: `tag_${idx}`, title: String(idx + 1), values: normalizeValues(it) };
                  });
                } else if (tagsRaw && typeof tagsRaw === 'object') {
                  tags = Object.entries(tagsRaw).map(([k, v], idx) => ({
                    id: `tag_${idx}_${String(k)}`,
                    title: String(k),
                    values: normalizeValues(v)
                  }));
                }

                const commentsRaw = Array.isArray(info?.comments) ? info.comments : [];
                const comments = commentsRaw.map((it, idx) => {
                  if (!it || typeof it !== 'object') return null;
                  const content = String(it.content ?? it.text ?? it.body ?? '').trim();
                  if (content.length === 0) return null;
                  const userName = String(it.userName ?? it.user ?? it.name ?? it.nickname ?? 'Anonymous').trim();
                  const rawId = it.id ?? it.cid ?? it.commentId ?? null;
                  const timeTextRaw = it.timeText ?? it.time ?? it.createdAt ?? it.createTime ?? null;
                  const stableKey = `${String(rawId ?? '')}|${String(userName)}|${String(timeTextRaw ?? '')}|${String(content).slice(0, 64)}|${idx}`;
                  const id = String(rawId ?? stableKey);
                  const timeText = timeTextRaw;
                  const avatar = it.avatar ?? it.avatarUrl ?? it.avatarURL ?? null;
                  const scoreRaw = it.score ?? it.likes ?? it.like ?? it.likeCount ?? null;
                  const score = (scoreRaw === null || scoreRaw === undefined) ? null : Number(scoreRaw);
                  const voteStatusRaw = it.voteStatus ?? null;
                  const voteStatus = (voteStatusRaw === null || voteStatusRaw === undefined) ? null : Number(voteStatusRaw);
                  const replyCountRaw = it.replyCount ?? null;
                  const replyCount = (replyCountRaw === null || replyCountRaw === undefined) ? null : Number(replyCountRaw);
                  return {
                    id,
                    userName: userName.length > 0 ? userName : 'Anonymous',
                    content,
                    timeText: timeText == null ? null : String(timeText),
                    avatar: avatar == null ? null : String(avatar),
                    score: Number.isFinite(score) ? Math.floor(score) : null,
                    isLiked: (typeof it.isLiked === 'boolean') ? it.isLiked : null,
                    voteStatus: Number.isFinite(voteStatus) ? Math.floor(voteStatus) : null,
                    replyCount: Number.isFinite(replyCount) ? Math.floor(replyCount) : null
                  };
                }).filter((x) => x != null);
                const commentsCountRaw = info?.commentsCount ?? info?.commentCount ?? comments.length;
                const commentsCount = Number.isFinite(Number(commentsCountRaw))
                  ? Math.floor(Number(commentsCountRaw))
                  : comments.length;

                return {
                  title: info?.title ? String(info.title) : "",
                  cover: info?.cover ? String(info.cover) : null,
                  description: info?.description ? String(info.description) : null,
                  comicURL: (info?.url != null)
                    ? String(info.url)
                    : ((info?.link != null) ? String(info.link) : null),
                  subId: (info?.subId != null)
                    ? String(info.subId)
                    : ((info?.sid != null)
                        ? String(info.sid)
                        : ((info?.token != null) ? String(info.token) : null)),
                  tags: tags.filter((g) => g.values.length > 0),
                  isFavorite: (typeof info?.isFavorite === 'boolean') ? info.isFavorite : null,
                  favoriteId: (typeof info?.favoriteId === 'string' && info.favoriteId.length > 0)
                    ? info.favoriteId
                    : ((typeof info?.subId === 'string' && info.subId.length > 0) ? info.subId : null),
                  chapters: chapters,
                  commentsCount,
                  comments
                };
              });
            })()
            """,
            arguments: [comicID]
        )

        guard let object = result as? [String: Any] else {
            throw ScriptEngineError.invalidResult("comic.loadInfo result invalid")
        }
        let chaptersObj = object["chapters"] as? [[String: Any]] ?? []
        let chapters = chaptersObj.map { item in
            ComicChapter(
                id: item["id"] as? String ?? "",
                title: item["title"] as? String ?? ""
            )
        }
                let tagsObj = object["tags"] as? [[String: Any]] ?? []
                let tags = tagsObj.map { item in
                    let valuesAny = item["values"] as? [Any] ?? []
                    let values = valuesAny.map { String(describing: $0) }.filter { !$0.isEmpty }
                    return TagGroup(
                id: item["id"] as? String ?? UUID().uuidString,
                title: item["title"] as? String ?? "",
                values: values
            )
                }.filter { !$0.values.isEmpty }
                let commentsObj = object["comments"] as? [[String: Any]] ?? []
                let comments = commentsObj.compactMap { item -> ComicComment? in
                    let id = (item["id"] as? String) ?? UUID().uuidString
                    let userName = (item["userName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let content = (item["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !content.isEmpty else { return nil }
                    return ComicComment(
                        id: id,
                        userName: userName.isEmpty ? "Anonymous" : userName,
                        content: content,
                        timeText: item["timeText"] as? String,
                        avatar: item["avatar"] as? String,
                        score: item["score"] as? Int,
                        isLiked: item["isLiked"] as? Bool,
                        voteStatus: item["voteStatus"] as? Int,
                        replyCount: item["replyCount"] as? Int
                    )
                }
                return ComicDetail(
                    title: object["title"] as? String ?? "",
                    cover: object["cover"] as? String,
                    description: object["description"] as? String,
                    comicURL: object["comicURL"] as? String,
                    subID: object["subId"] as? String,
                    tags: tags,
                    isFavorite: object["isFavorite"] as? Bool,
                    favoriteId: object["favoriteId"] as? String,
                    chapters: chapters,
                    commentsCount: object["commentsCount"] as? Int,
                    comments: comments
                )
            }

    func loadFavoriteFolders(comicID: String?) throws -> [FavoriteFolder] {
        let result = try callExpression(
            """
            (() => {
              const source = this.__source_temp;
              const favorites = source && source.favorites;
              if (!favorites) {
                return { folders: [] };
              }
              const toText = (value, fallback = '') => {
                if (value === null || value === undefined) return fallback;
                const text = String(value).trim();
                return text.length > 0 ? text : fallback;
              };
              return Promise.resolve((async () => {
                let payload = null;
                if (typeof favorites.loadFolders === 'function') {
                  try {
                    payload = await Promise.resolve(favorites.loadFolders.call(favorites, arguments[0]));
                  } catch (_) {
                    try {
                      payload = await Promise.resolve(favorites.loadFolders.call(source, arguments[0]));
                    } catch (_) {
                      payload = null;
                    }
                  }
                }

                const root = (() => {
                  if (payload && typeof payload === 'object') {
                    if (payload.folders || payload.favorited) return payload;
                    if (payload.data && typeof payload.data === 'object') return payload.data;
                    if (payload.result && typeof payload.result === 'object') return payload.result;
                  }
                  return payload;
                })();

                const favoritedRaw = (() => {
                  if (!root || typeof root !== 'object') return [];
                  if (Array.isArray(root.favorited)) return root.favorited;
                  if (Array.isArray(root.subData)) return root.subData;
                  if (Array.isArray(root.selected)) return root.selected;
                  return [];
                })();
                const favorited = new Set(favoritedRaw.map((x) => toText(x)).filter((x) => x.length > 0));
                const foldersRaw = root && root.folders;

                let folders = [];
                if (foldersRaw instanceof Map) {
                  folders = Array.from(foldersRaw.entries()).map(([k, v]) => {
                    const id = toText(k);
                    return { id, title: toText(v, id), isFavorited: favorited.has(id) };
                  });
                } else if (Array.isArray(foldersRaw)) {
                  folders = foldersRaw.map((item, idx) => {
                    if (item && typeof item === 'object') {
                      const id = toText(item.id ?? item.key ?? item.value ?? idx);
                      const title = toText(item.title ?? item.name ?? item.label, id);
                      return { id, title, isFavorited: favorited.has(id) };
                    }
                    const id = toText(item, String(idx));
                    return { id, title: id, isFavorited: favorited.has(id) };
                  });
                } else if (foldersRaw && typeof foldersRaw === 'object') {
                  folders = Object.entries(foldersRaw).map(([k, v]) => {
                    const id = toText(k);
                    return { id, title: toText(v, id), isFavorited: favorited.has(id) };
                  });
                }

                if (folders.length === 0 && favorites.multiFolder !== true) {
                  folders = [{ id: "0", title: "Default", isFavorited: favorited.has("0") }];
                }
                return { folders };
              })());
            })()
            """,
            arguments: [comicID ?? NSNull()]
        )

        guard let object = result as? [String: Any] else { return [] }
        let rows = object["folders"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return FavoriteFolder(
                id: id,
                title: (title?.isEmpty == false) ? title! : id,
                isFavorited: row["isFavorited"] as? Bool ?? false
            )
        }
    }

    func loadFavoriteComics(sourceKey: String, page: Int = 1, folderID: String? = nil) throws -> [ComicSummary] {
        let paged = try loadFavoriteComicsPage(sourceKey: sourceKey, page: page, folderID: folderID, nextToken: nil)
        return paged.comics
    }

    func loadFavoriteComicsPage(
        sourceKey: String,
        page: Int = 1,
        folderID: String? = nil,
        nextToken: String?
    ) throws -> ComicPageResult {
        let result = try callExpression(
            """
            (() => {
              const source = this.__source_temp;
              const favorites = source && source.favorites;
              if (!favorites) {
                throw new Error('favorites is not supported by this source');
              }
              return Promise.resolve((async () => {
                const hasLoadComics = typeof favorites.loadComics === 'function';
                const hasLoadNext = typeof favorites.loadNext === 'function';
                if (!hasLoadComics && !hasLoadNext) {
                  throw new Error('favorites.loadComics/loadNext is not supported by this source');
                }
                const normalizeFolderArg = (value) => {
                  if (value === null || value === undefined) return undefined;
                  if (typeof value === 'string') {
                    const text = value.trim().toLowerCase();
                    if (text.length === 0 || text === 'null' || text === 'undefined') return undefined;
                    return value;
                  }
                  return value;
                };
                const folderArg = normalizeFolderArg(arguments[1]);

                const loadOnce = async () => {
                  if (hasLoadComics) {
                    try {
                      return await Promise.resolve(favorites.loadComics.call(favorites, arguments[0], folderArg));
                    } catch (_) {
                      return await Promise.resolve(favorites.loadComics.call(source, arguments[0], folderArg));
                    }
                  }
                  const nextToken = arguments[2] ?? null;
                  try {
                    return await Promise.resolve(favorites.loadNext.call(favorites, nextToken, folderArg));
                  } catch (_) {
                    return await Promise.resolve(favorites.loadNext.call(source, nextToken, folderArg));
                  }
                };

                let payload = null;
                try {
                  payload = await loadOnce();
                } catch (_) {
                  let needRetry = false;
                  const message = String(((_ && _.message) ? _.message : _) || '');
                  if (message.includes('Login expired')) {
                    needRetry = true;
                  }
                  if (needRetry && source && typeof source.reLogin === 'function') {
                    const ok = await Promise.resolve(source.reLogin.call(source));
                    if (ok) {
                      payload = await loadOnce();
                    } else {
                      throw new Error('Login expired');
                    }
                  } else {
                    throw _;
                  }
                }
                if (payload && typeof payload === 'object') {
                  if (Array.isArray(payload.comics)) {
                    return {
                      comics: payload.comics,
                      maxPage: payload.maxPage ?? payload.pages ?? payload.totalPages ?? payload.subData ?? null,
                      nextToken: payload.next ?? payload.nextToken ?? payload.token ?? null
                    };
                  }
                  if (payload.data && Array.isArray(payload.data.comics)) {
                    return {
                      comics: payload.data.comics,
                      maxPage: payload.data.maxPage ?? payload.maxPage ?? payload.subData ?? null,
                      nextToken: payload.data.next ?? payload.next ?? payload.data.nextToken ?? payload.nextToken ?? null
                    };
                  }
                  if (Array.isArray(payload.data)) {
                    return {
                      comics: payload.data,
                      maxPage: payload.maxPage ?? payload.subData ?? null,
                      nextToken: payload.next ?? payload.nextToken ?? null
                    };
                  }
                  if (Array.isArray(payload.result)) {
                    return {
                      comics: payload.result,
                      maxPage: payload.maxPage ?? payload.subData ?? null,
                      nextToken: payload.next ?? payload.nextToken ?? null
                    };
                  }
                }
                return { comics: payload, maxPage: null, nextToken: null };
              })());
            })()
            """,
            arguments: [page, folderID ?? NSNull(), nextToken ?? NSNull()]
        )
        let object = (result as? [String: Any]) ?? [:]
        let comics = try Self.normalizeSearchResult(object["comics"] ?? result, defaultSourceKey: sourceKey)
        let maxPage = object["maxPage"] as? Int
        let next = object["nextToken"] as? String
        return ComicPageResult(comics: comics, maxPage: maxPage, nextToken: next)
    }

    func getComicCommentCapabilities() throws -> ComicCommentCapabilities {
        let value = try callExpression(
            """
            (() => {
              const source = this.__source_temp;
              const comic = source && source.comic;
              return {
                canLoad: !!(comic && typeof comic.loadComments === 'function'),
                canSend: !!(comic && typeof comic.sendComment === 'function'),
                canLike: !!(comic && typeof comic.likeComment === 'function'),
                canVote: !!(comic && typeof comic.voteComment === 'function')
              };
            })()
            """
        )
        let object = value as? [String: Any] ?? [:]
        return ComicCommentCapabilities(
            canLoad: object["canLoad"] as? Bool ?? false,
            canSend: object["canSend"] as? Bool ?? false,
            canLike: object["canLike"] as? Bool ?? false,
            canVote: object["canVote"] as? Bool ?? false
        )
    }

    func resolveComicTagClick(namespace: String, tag: String) throws -> CategoryJumpTarget {
        let value = try callExpression(
            """
            (() => {
              const source = this.__source_temp;
              const comic = source && source.comic;
              const fallback = { page: 'search', keyword: arguments[1], category: null, param: null };
              if (!comic || typeof comic.onClickTag !== 'function') {
                return fallback;
              }
              const parse = (raw) => {
                if (raw == null) return fallback;
                if (typeof raw === 'string') {
                  const text = raw.trim();
                  if (!text) return fallback;
                  if (text.startsWith('search:')) {
                    return { page: 'search', keyword: text.slice('search:'.length), category: null, param: null };
                  }
                  if (text.startsWith('category:')) {
                    const body = text.slice('category:'.length);
                    const at = body.indexOf('@');
                    if (at >= 0) return { page: 'category', keyword: null, category: body.slice(0, at), param: body.slice(at + 1) };
                    return { page: 'category', keyword: null, category: body, param: null };
                  }
                  return { page: 'search', keyword: text, category: null, param: null };
                }
                if (typeof raw === 'object') {
                  const action = String(raw.action ?? raw.page ?? 'search').trim();
                  if (action === 'search') {
                    return {
                      page: 'search',
                      keyword: String(raw.keyword ?? arguments[1]),
                      category: null,
                      param: raw.param != null ? String(raw.param) : null
                    };
                  }
                  if (action === 'category') {
                    return {
                      page: 'category',
                      keyword: null,
                      category: String(raw.keyword ?? raw.category ?? arguments[1]),
                      param: raw.param != null ? String(raw.param) : null
                    };
                  }
                  if (action === 'ranking') {
                    return { page: 'ranking', keyword: null, category: null, param: null };
                  }
                  return {
                    page: action,
                    keyword: raw.keyword != null ? String(raw.keyword) : null,
                    category: raw.category != null ? String(raw.category) : null,
                    param: raw.param != null ? String(raw.param) : null
                  };
                }
                return fallback;
              };
              const out = comic.onClickTag.call(source, arguments[0], arguments[1]);
              return parse(out);
            })()
            """,
            arguments: [namespace, tag]
        )
        let object = value as? [String: Any] ?? [:]
        return CategoryJumpTarget(
            page: object["page"] as? String ?? "search",
            keyword: object["keyword"] as? String,
            category: object["category"] as? String,
            param: object["param"] as? String
        )
    }

    func loadComicComments(comicID: String, subID: String?, page: Int = 1, replyTo: String? = nil) throws -> ComicCommentsPage {
        let result = try callExpression(
            """
            (() => {
              const source = this.__source_temp;
              const comic = source && source.comic;
              if (!comic || typeof comic.loadComments !== 'function') {
                throw new Error('comic.loadComments is not supported by this source');
              }
              return Promise.resolve((async () => {
                const loadOnce = async () => {
                  try {
                    return await Promise.resolve(
                      comic.loadComments.call(comic, arguments[0], arguments[1], arguments[2], arguments[3])
                    );
                  } catch (_) {
                    return await Promise.resolve(
                      comic.loadComments.call(source, arguments[0], arguments[1], arguments[2], arguments[3])
                    );
                  }
                };

                let payload = null;
                try {
                  payload = await loadOnce();
                } catch (e) {
                  const message = String((e && e.message) ? e.message : e);
                  if (message.includes('Login expired') && source && typeof source.reLogin === 'function') {
                    const ok = await Promise.resolve(source.reLogin.call(source));
                    if (!ok) throw new Error('Login expired');
                    payload = await loadOnce();
                  } else {
                    throw e;
                  }
                }

                const root = (payload && typeof payload === 'object')
                  ? ((payload.data && typeof payload.data === 'object') ? payload.data : payload)
                  : {};
                const raw = Array.isArray(root.comments)
                  ? root.comments
                  : (Array.isArray(root.result) ? root.result : []);
                const comments = raw.map((it, idx) => {
                  const obj = (it && typeof it === 'object') ? it : {};
                  const content = String(obj.content ?? obj.text ?? obj.body ?? '').trim();
                  if (content.length === 0) return null;
                  const userName = String(obj.userName ?? obj.user ?? obj.author ?? 'Anonymous').trim();
                  const rawId = obj.id ?? obj.commentId ?? obj.cid ?? null;
                  const timeTextRaw = (obj.timeText ?? obj.time ?? obj.date ?? null);
                  const stableKey = `${String(rawId ?? '')}|${String(userName)}|${String(timeTextRaw ?? '')}|${String(content).slice(0, 64)}|p${arguments[2]}|${idx}`;
                  const scoreRaw = obj.score ?? obj.likes ?? obj.like ?? obj.likeCount ?? null;
                  const score = (scoreRaw === null || scoreRaw === undefined) ? null : Number(scoreRaw);
                  const voteStatusRaw = obj.voteStatus ?? null;
                  const voteStatus = (voteStatusRaw === null || voteStatusRaw === undefined) ? null : Number(voteStatusRaw);
                  const replyCountRaw = obj.replyCount ?? null;
                  const replyCount = (replyCountRaw === null || replyCountRaw === undefined) ? null : Number(replyCountRaw);
                  return {
                    id: String(rawId ?? stableKey),
                    userName: userName.length > 0 ? userName : 'Anonymous',
                    content,
                    timeText: timeTextRaw,
                    avatar: (obj.avatar ?? obj.avatarUrl ?? obj.avatarURL ?? null),
                    score: Number.isFinite(score) ? Math.floor(score) : null,
                    isLiked: (typeof obj.isLiked === 'boolean') ? obj.isLiked : null,
                    voteStatus: Number.isFinite(voteStatus) ? Math.floor(voteStatus) : null,
                    replyCount: Number.isFinite(replyCount) ? Math.floor(replyCount) : null
                  };
                }).filter((x) => x != null);

                const rawMax = root.maxPage ?? root.totalPages ?? root.pages ?? root.subData ?? payload?.subData ?? null;
                const maxPage = Number.isFinite(Number(rawMax)) ? Math.max(1, Math.floor(Number(rawMax))) : null;
                return { comments, maxPage };
              })());
            })()
            """,
            arguments: [comicID, subID ?? NSNull(), max(1, page), replyTo ?? NSNull()]
        )

        let object = result as? [String: Any] ?? [:]
        let rows = object["comments"] as? [[String: Any]] ?? []
        let comments = rows.compactMap { item -> ComicComment? in
            let id = (item["id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let userName = (item["userName"] as? String ?? "Anonymous").trimmingCharacters(in: .whitespacesAndNewlines)
            let content = (item["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return ComicComment(
                id: id,
                userName: userName.isEmpty ? "Anonymous" : userName,
                content: content,
                timeText: item["timeText"] as? String,
                avatar: item["avatar"] as? String,
                score: item["score"] as? Int,
                isLiked: item["isLiked"] as? Bool,
                voteStatus: item["voteStatus"] as? Int,
                replyCount: item["replyCount"] as? Int
            )
        }
        return ComicCommentsPage(comments: comments, maxPage: object["maxPage"] as? Int)
    }

    func sendComicComment(comicID: String, subID: String?, content: String, replyTo: String? = nil) throws {
        _ = try callExpression(
            """
            (() => {
              const source = this.__source_temp;
              const comic = source && source.comic;
              if (!comic || typeof comic.sendComment !== 'function') {
                throw new Error('comic.sendComment is not supported by this source');
              }
              return Promise.resolve((async () => {
                const sendOnce = async () => {
                  try {
                    return await Promise.resolve(
                      comic.sendComment.call(comic, arguments[0], arguments[1], arguments[2], arguments[3])
                    );
                  } catch (_) {
                    return await Promise.resolve(
                      comic.sendComment.call(source, arguments[0], arguments[1], arguments[2], arguments[3])
                    );
                  }
                };
                try {
                  return await sendOnce();
                } catch (e) {
                  const message = String((e && e.message) ? e.message : e);
                  if (message.includes('Login expired') && source && typeof source.reLogin === 'function') {
                    const ok = await Promise.resolve(source.reLogin.call(source));
                    if (!ok) throw new Error('Login expired');
                    return await sendOnce();
                  }
                  throw e;
                }
              })());
            })()
            """,
            arguments: [comicID, subID ?? NSNull(), content, replyTo ?? NSNull()]
        )
    }

    func likeComicComment(comicID: String, subID: String?, commentID: String, isLiking: Bool) throws -> Int? {
        let result = try callExpression(
            """
            (() => {
              const source = this.__source_temp;
              const comic = source && source.comic;
              if (!comic || typeof comic.likeComment !== 'function') {
                throw new Error('comic.likeComment is not supported by this source');
              }
              return Promise.resolve((async () => {
                try {
                  return await Promise.resolve(
                    comic.likeComment.call(comic, arguments[0], arguments[1], arguments[2], arguments[3])
                  );
                } catch (_) {
                  return await Promise.resolve(
                    comic.likeComment.call(source, arguments[0], arguments[1], arguments[2], arguments[3])
                  );
                }
              })());
            })()
            """,
            arguments: [comicID, subID ?? NSNull(), commentID, isLiking]
        )
        if let n = result as? NSNumber { return n.intValue }
        if let d = result as? [String: Any] {
            if let score = d["score"] as? Int { return score }
            if let likes = d["likes"] as? Int { return likes }
        }
        return nil
    }

    func voteComicComment(comicID: String, subID: String?, commentID: String, isUp: Bool, isCancel: Bool) throws -> Int? {
        let result = try callExpression(
            """
            (() => {
              const source = this.__source_temp;
              const comic = source && source.comic;
              if (!comic || typeof comic.voteComment !== 'function') {
                throw new Error('comic.voteComment is not supported by this source');
              }
              return Promise.resolve((async () => {
                try {
                  return await Promise.resolve(
                    comic.voteComment.call(comic, arguments[0], arguments[1], arguments[2], arguments[3], arguments[4])
                  );
                } catch (_) {
                  return await Promise.resolve(
                    comic.voteComment.call(source, arguments[0], arguments[1], arguments[2], arguments[3], arguments[4])
                  );
                }
              })());
            })()
            """,
            arguments: [comicID, subID ?? NSNull(), commentID, isUp, isCancel]
        )
        if let n = result as? NSNumber { return n.intValue }
        if let d = result as? [String: Any] {
            if let score = d["score"] as? Int { return score }
            if let likes = d["likes"] as? Int { return likes }
        }
        return nil
    }

    func setFavoriteStatus(comicID: String, isAdding: Bool, favoriteId: String?, folderID: String?) throws -> Bool {
        let value = try callExpression(
            """
            (() => {
              const source = this.__source_temp;
              const favorites = source && source.favorites;
              if (!favorites || typeof favorites.addOrDelFavorite !== 'function') {
                throw new Error('favorites.addOrDelFavorite is not supported by this source');
              }

              const pickFolder = async () => {
                if (typeof favorites.loadFolders !== 'function') return null;
                let payload = null;
                try {
                  payload = await Promise.resolve(favorites.loadFolders.call(favorites, arguments[0]));
                } catch (_) {
                  try {
                    payload = await Promise.resolve(favorites.loadFolders.call(source, arguments[0]));
                  } catch (_) {
                    payload = null;
                  }
                }
                if (!payload || typeof payload !== 'object') return null;

                const root = (() => {
                  if (payload.folders || payload.favorited) return payload;
                  if (payload.data && typeof payload.data === 'object') return payload.data;
                  if (payload.result && typeof payload.result === 'object') return payload.result;
                  return payload;
                })();

                const foldersRaw = root && root.folders;
                let folderKeys = [];
                if (foldersRaw instanceof Map) {
                  folderKeys = Array.from(foldersRaw.keys()).map((x) => String(x));
                } else if (foldersRaw && typeof foldersRaw === 'object') {
                  folderKeys = Object.keys(foldersRaw).map((x) => String(x));
                }

                const favoritedRaw = Array.isArray(root?.favorited)
                  ? root.favorited
                  : (Array.isArray(root?.subData) ? root.subData : []);
                const favorited = Array.isArray(favoritedRaw)
                  ? favoritedRaw.map((x) => String(x)).filter((x) => x.length > 0)
                  : [];
                if (favorited.length > 0) return favorited[0];
                if (folderKeys.length > 0) return folderKeys[0];
                return null;
              };

              return Promise.resolve((async () => {
                let folderId = (typeof arguments[3] === 'string' && arguments[3].length > 0)
                  ? arguments[3]
                  : null;
                if (!folderId) {
                  folderId = await pickFolder();
                }
                if (!folderId && favorites.multiFolder !== true) {
                  folderId = "0";
                }
                try {
                  await Promise.resolve(
                    favorites.addOrDelFavorite.call(
                      favorites,
                      arguments[0],
                      folderId,
                      !!arguments[1],
                      arguments[2]
                    )
                  );
                } catch (_) {
                  await Promise.resolve(
                    favorites.addOrDelFavorite.call(
                      source,
                      arguments[0],
                      folderId,
                      !!arguments[1],
                      arguments[2]
                    )
                  );
                }
                return true;
              })());
            })()
            """,
            arguments: [comicID, isAdding, favoriteId ?? NSNull(), folderID ?? NSNull()]
        )

        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return true
    }

    func loadComicEp(comicID: String, chapterID: String) throws -> [String] {
        let result = try callExpression(
            """
            (() => {
              const comic = this.__source_temp && this.__source_temp.comic;
              if (!comic || typeof comic.loadEp !== 'function') {
                throw new Error("comic.loadEp is not supported by this source");
              }
              return Promise.resolve(
                comic.loadEp.apply(this.__source_temp, arguments)
              ).then((ep) => {
                const imagesRaw = ep && ep.images;
                const normalizeUrl = (u) => {
                  if (typeof u !== 'string') return '';
                  const text = u.trim();
                  if (!text) return '';
                  if (text.startsWith('//')) return `https:${text}`;
                  if (text.startsWith('http://') || text.startsWith('https://')) return text;
                  return '';
                };

                let images = [];
                if (Array.isArray(imagesRaw)) {
                  images = imagesRaw.map((it) => {
                    if (typeof it === 'string') return normalizeUrl(it);
                    if (it && typeof it === 'object') {
                      const candidate =
                        it.url ?? it.src ?? it.image ?? it.link ?? it.href ?? it.origin ?? '';
                      return normalizeUrl(candidate);
                    }
                    return '';
                  }).filter((x) => x.length > 0);
                }
                return images;
              });
            })()
            """,
            arguments: [comicID, chapterID]
        )

        if let images = result as? [String] {
            return sanitizeImageURLs(images)
        }
        if let images = result as? [Any] {
            return sanitizeImageURLs(images.compactMap { $0 as? String })
        }
        throw ScriptEngineError.invalidResult("comic.loadEp images invalid")
    }

    func loadComicEpRequests(comicID: String, chapterID: String) throws -> [ImageRequest] {
        let result = try callExpression(
            """
            (() => {
              const comic = this.__source_temp && this.__source_temp.comic;
              if (!comic || typeof comic.loadEp !== 'function') {
                throw new Error("comic.loadEp is not supported by this source");
              }
              const normalizeToken = (u) => {
                if (typeof u !== 'string') return '';
                const text = u.trim();
                return text.length > 0 ? text : '';
              };
              const normalizeUrl = (u) => {
                const text = normalizeToken(u);
                if (!text) return '';
                if (text.startsWith('//')) return `https:${text}`;
                if (text.startsWith('http://') || text.startsWith('https://')) return text;
                return '';
              };
              const normalizeImage = (it) => {
                if (typeof it === 'string') return normalizeToken(it);
                if (it && typeof it === 'object') {
                  const candidate = it.url ?? it.src ?? it.image ?? it.link ?? it.href ?? it.origin ?? '';
                  return normalizeToken(candidate);
                }
                return '';
              };

              return Promise.resolve(comic.loadEp.apply(this.__source_temp, arguments)).then(async (ep) => {
                const imagesRaw = ep && ep.images;
                let images = [];
                if (Array.isArray(imagesRaw)) {
                  images = imagesRaw.map(normalizeImage).filter((x) => x.length > 0);
                }
                if (typeof comic.onImageLoad !== 'function') {
                  return images
                    .map((token) => {
                      const url = normalizeUrl(token);
                      if (!url) return null;
                      return { url, method: 'GET', headers: {}, data: null };
                    })
                    .filter((x) => x != null);
                }
                return Promise.all(images.map(async (token) => {
                  const defaultReferer = (typeof arguments[0] === 'string' && arguments[0].startsWith('http'))
                    ? arguments[0]
                    : '';
                  let cfg = null;
                  try {
                    cfg = await Promise.resolve(comic.onImageLoad.call(this.__source_temp, token, arguments[0], arguments[1], null));
                  } catch (_) {
                    cfg = null;
                  }
                  if (!cfg || typeof cfg !== 'object') {
                    const fallback = normalizeUrl(token);
                    if (!fallback) return null;
                    return { url: fallback, method: 'GET', headers: {}, data: null };
                  }
                  const outUrl = normalizeUrl(typeof cfg.url === 'string' ? cfg.url : '') || normalizeUrl(token);
                  if (!outUrl) return null;
                  const method = (typeof cfg.method === 'string' && cfg.method.trim().length > 0) ? cfg.method.trim().toUpperCase() : 'GET';
                  const headers = (cfg.headers && typeof cfg.headers === 'object') ? { ...cfg.headers } : {};
                  if (!headers.Referer && !headers.referer && defaultReferer) {
                    headers.Referer = defaultReferer;
                  }
                  let data = cfg.data ?? null;
                  if (typeof data === 'string') data = Convert.encodeUtf8(data);
                  if (!Array.isArray(data)) data = null;
                  return { url: outUrl, method, headers, data };
                })).then((rows) => rows
                  .filter((x) => x != null && typeof x === 'object')
                  .map((x) => ({
                    url: (typeof x.url === 'string' ? x.url : '').trim(),
                    method: (typeof x.method === 'string' ? x.method : 'GET'),
                    headers: (x.headers && typeof x.headers === 'object') ? x.headers : {},
                    data: Array.isArray(x.data) ? x.data : null
                  }))
                  .filter((x) => x.url.length > 0)
                );
              });
            })()
            """,
            arguments: [comicID, chapterID]
        )

        guard let list = result as? [Any] else {
            throw ScriptEngineError.invalidResult("comic.loadEp image requests invalid")
        }
        jsDebugLog("loadComicEpRequests rawCount=\(list.count), comicID=\(comicID)")

        var requests: [ImageRequest] = []
        requests.reserveCapacity(list.count)
        for (idx, item) in list.enumerated() {
            let object: [String: Any]?
            if let obj = item as? [String: Any] {
                object = obj
            } else if let ns = item as? NSDictionary {
                object = ns as? [String: Any]
            } else {
                object = nil
            }
            guard let object else {
                jsDebugLog("loadComicEpRequests skip index=\(idx): not an object", level: .warn)
                continue
            }
            guard let parsed = parseImageRequest(object) else {
                let keys = object.keys.sorted().joined(separator: ",")
                jsDebugLog("loadComicEpRequests skip index=\(idx): parse failed, keys=\(keys)", level: .warn)
                continue
            }
            requests.append(parsed)
        }
        jsDebugLog("loadComicEpRequests parsedCount=\(requests.count), comicID=\(comicID)")
        if requests.isEmpty && !list.isEmpty {
            let sample = String(describing: list.prefix(1))
            jsDebugLog("loadComicEpRequests empty after parse, firstItem=\(sample)", level: .warn)
        }
        return requests
    }

    private func parseImageRequest(_ object: [String: Any]) -> ImageRequest? {
        guard let rawURL = object["url"] as? String else { return nil }
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }

        let methodRaw = (object["method"] as? String) ?? "GET"
        let method = methodRaw.uppercased()

        var headers: [String: String] = [:]
        if let rawHeaders = object["headers"] as? [String: Any] {
            for (k, v) in rawHeaders {
                headers[k] = String(describing: v)
            }
        }

        let bodyBytes = bytesFromAny(object["data"])
        let body = bodyBytes.isEmpty ? nil : bodyBytes

        return ImageRequest(url: url, method: method, headers: headers, body: body)
    }

    private func sanitizeImageURLs(_ links: [String]) -> [String] {
        links.compactMap { link in
            let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = trimmed.hasPrefix("//") ? "https:\(trimmed)" : trimmed
            guard let url = URL(string: normalized),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                return nil
            }
            return normalized
        }
    }

    private func normalizeOutput(_ output: JSValue?, fallbackSourceKey: String) throws -> Any {
        if let exception = context.exception {
            let message = exception.toString() ?? "Unknown JS exception"
            jsDebugLog("normalizeOutput found JS exception: \(message)", level: .error)
            throw ScriptEngineError.scriptException(message)
        }

        guard let output else {
            throw ScriptEngineError.invalidResult("function returned nil")
        }

        if output.isUndefined || output.isNull {
            return NSNull()
        }

        if output.isObject, output.hasProperty("then") {
            jsDebugLog("normalizeOutput detected Promise, awaiting")
            let awaited = try awaitPromise(output)
            return awaited
        }

        guard let object = output.toObject() else {
            throw ScriptEngineError.invalidResult("cannot convert JS value")
        }
        return object
    }

    private func awaitPromise(_ promise: JSValue) throws -> Any {
        var done = false
        var resolved: Any?
        var rejected: String?

        let resolve: @convention(block) (JSValue) -> Void = { value in
            if value.isUndefined || value.isNull {
                resolved = NSNull()
            } else {
                resolved = value.toObject()
            }
            done = true
        }
        let reject: @convention(block) (JSValue) -> Void = { error in
            rejected = error.toString()
            done = true
        }

        let resolveObj: AnyObject = unsafeBitCast(resolve, to: AnyObject.self)
        let rejectObj: AnyObject = unsafeBitCast(reject, to: AnyObject.self)

        promise.invokeMethod("then", withArguments: [resolveObj])
        promise.invokeMethod("catch", withArguments: [rejectObj])

        let timeout = Date().addingTimeInterval(20)
        while !done && Date() < timeout {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }

        if !done {
            jsDebugLog("awaitPromise timeout", level: .error)
            throw ScriptEngineError.timeout("Promise is not resolved in time")
        }
        if let rejected {
            jsDebugLog("awaitPromise rejected: \(rejected)", level: .error)
            throw ScriptEngineError.scriptException(rejected)
        }
        guard let resolved else {
            throw ScriptEngineError.invalidResult("Promise resolved to nil")
        }
        return resolved
    }

    static func normalizeSearchResult(_ result: Any, defaultSourceKey: String) throws -> [ComicSummary] {
        if let text = result as? String {
            let data = Data(text.utf8)
            let decoded = try JSONDecoder().decode([ComicSummary].self, from: data)
            return decoded.map { fixSourceKeyIfNeeded($0, defaultSourceKey: defaultSourceKey) }
        }

        if let object = result as? [String: Any], let comics = object["comics"] {
            return try normalizeSearchResult(comics, defaultSourceKey: defaultSourceKey)
        }

        guard let array = result as? [[String: Any]] else {
            throw ScriptEngineError.invalidResult("expect JSON string / comics array / {comics:[]}")
        }

        return array.map { object in
            let nestedComic = object["comic"] as? [String: Any]
            let primary = nestedComic ?? object
            let id = (primary["id"] as? String)
                ?? (primary["url"] as? String)
                ?? (primary["path_word"] as? String)
                ?? UUID().uuidString
            let sourceKey = (primary["sourceKey"] as? String) ?? (object["sourceKey"] as? String) ?? defaultSourceKey
            let title = (primary["title"] as? String) ?? (primary["name"] as? String) ?? "Untitled"
            let cover = (primary["coverURL"] as? String) ?? (primary["cover"] as? String)
            let author = (primary["author"] as? String) ?? (object["subTitle"] as? String)
            let tags = (primary["tags"] as? [String]) ?? (object["tags"] as? [String]) ?? []
            return ComicSummary(
                id: id,
                sourceKey: sourceKey,
                title: title,
                coverURL: cover,
                author: author,
                tags: tags
            )
        }
    }

    private static func fixSourceKeyIfNeeded(_ item: ComicSummary, defaultSourceKey: String) -> ComicSummary {
        if item.sourceKey.isEmpty {
            return ComicSummary(
                id: item.id,
                sourceKey: defaultSourceKey,
                title: item.title,
                coverURL: item.coverURL,
                author: item.author,
                tags: item.tags
            )
        }
        return item
    }

    private func setupRuntime(on ctx: JSContext) throws {
        ctx.exceptionHandler = { _, exception in
            if let exception {
                NSLog("[SourceRuntime][ERROR][JS] Exception: %@", exception.toString())
            }
        }

        try installBridgeObjects(on: ctx)

        let prelude = """
        class ComicSource {
          constructor() {
            this.__data = {};
            this.__settingsData = {};
          }
          saveData(key, value) {
            this.__data[key] = value;
            try { BridgeStorage.saveData(String(key), value); } catch (_) {}
          }
          loadData(key) {
            if (Object.prototype.hasOwnProperty.call(this.__data, key)) {
              return this.__data[key];
            }
            try {
              const v = BridgeStorage.loadData(String(key));
              if (v !== null && v !== undefined) {
                this.__data[key] = v;
                return v;
              }
            } catch (_) {}
            return undefined;
          }
          deleteData(key) {
            delete this.__data[key];
            try { BridgeStorage.deleteData(String(key)); } catch (_) {}
          }
          saveSetting(key, value) {
            this.__settingsData[key] = value;
            try { BridgeStorage.saveSetting(String(key), value); } catch (_) {}
          }
          loadSetting(key) {
            if (Object.prototype.hasOwnProperty.call(this.__settingsData, key)) {
              return this.__settingsData[key];
            }
            try {
              const saved = BridgeStorage.loadSetting(String(key));
              if (saved !== null && saved !== undefined) {
                this.__settingsData[key] = saved;
                return saved;
              }
            } catch (_) {}
            const item = this.settings && this.settings[key];
            if (item && typeof item === 'object' && Object.prototype.hasOwnProperty.call(item, 'default')) {
              return item.default;
            }
            if (item && typeof item === 'object' && Object.prototype.hasOwnProperty.call(item, 'value')) {
              return item.value;
            }
            return item;
          }
          get isLogged() {
            return !!(this.loadData('token') || this.loadData('cookies') || this.loadData('session'));
          }
        }

        class Comic { constructor(obj){ Object.assign(this, obj || {}); } }
        class ComicDetails { constructor(obj){ Object.assign(this, obj || {}); } }
        class Comment { constructor(obj){ Object.assign(this, obj || {}); } }
        class Cookie { constructor(obj){ Object.assign(this, obj || {}); } }
        const APP = { version: "1.0.0", locale: "en_US" };
        const App = APP;
        var res = null;
        var response = null;
        try {
          const __net = Network;
          const __wrapNet = (name) => {
            if (!__net || typeof __net[name] !== 'function') return;
            const original = __net[name].bind(__net);
            __net[name] = (...args) => {
              const out = original(...args);
              res = out;
              response = out;
              if (typeof globalThis !== 'undefined') {
                globalThis.res = out;
                globalThis.response = out;
              }
              return out;
            };
          };
          ['sendRequest', 'get', 'post', 'put', 'patch', 'delete', 'fetchBytes'].forEach(__wrapNet);
        } catch (_) {}
        const UI = {
          showMessage: (msg) => {
            try { BridgeUI.showMessage(String(msg ?? '')); } catch (_) {}
            return null;
          },
          showDialog: (title, content, actions) => {
            let labels = Array.isArray(actions) ? actions.map((it) => String((it && it.text) || '')) : [];
            let index = 0;
            try {
              index = BridgeUI.showDialog(String(title ?? ''), String(content ?? ''), labels);
            } catch (_) {
              index = 0;
            }
            if (Array.isArray(actions) && index >= 0 && index < actions.length) {
              const callback = actions[index] && actions[index].callback;
              if (typeof callback === 'function') {
                try { callback(); } catch (_) {}
              }
            }
            return index;
          },
          launchUrl: (url) => {
            try { BridgeUI.launchUrl(String(url ?? '')); } catch (_) {}
            return null;
          },
          showInputDialog: (title, validator, imageData) => {
            let value = '';
            let retries = 0;
            while (retries < 3) {
              try { value = BridgeUI.showInputDialog(String(title ?? '')); } catch (_) { value = ''; }
              if (typeof validator !== 'function') {
                break;
              }
              try {
                const message = validator(value);
                if (typeof message === 'string' && message.length > 0) {
                  UI.showMessage(message);
                  retries++;
                  continue;
                }
              } catch (_) {}
              break;
            }
            return value;
          },
          copyToClipboard: (text) => {
            try { BridgeUI.copyToClipboard(String(text ?? '')); } catch (_) {}
            return null;
          }
        };

        class HtmlElement {
          constructor(key, docKey) {
            this.key = key;
            this.docKey = docKey;
          }
          querySelector(query) {
            const k = Html.elementQuerySelector(this.key, query);
            return k ? new HtmlElement(k, this.docKey) : null;
          }
          querySelectorAll(query) {
            return Html.elementQuerySelectorAll(this.key, query).map((k) => new HtmlElement(k, this.docKey));
          }
          get children() {
            return Html.children(this.key).map((k) => new HtmlElement(k, this.docKey));
          }
          get text() {
            return Html.text(this.key);
          }
          get innerHTML() {
            return Html.innerHTML(this.key);
          }
          get attributes() {
            return Html.attributes(this.key);
          }
        }

        class HtmlDocument {
          constructor(html) {
            this.key = Html.parse(html);
          }
          querySelector(query) {
            const k = Html.querySelector(this.key, query);
            return k ? new HtmlElement(k, this.key) : null;
          }
          querySelectorAll(query) {
            return Html.querySelectorAll(this.key, query).map((k) => new HtmlElement(k, this.key));
          }
          getElementById(id) {
            const k = Html.getElementById(this.key, id);
            return k ? new HtmlElement(k, this.key) : null;
          }
          dispose() {
            Html.dispose(this.key);
          }
        }

        function createUuid() {
          if (typeof crypto !== 'undefined' && crypto.randomUUID) {
            return crypto.randomUUID();
          }
          return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
            const r = Math.random() * 16 | 0;
            const v = c === 'x' ? r : (r & 0x3 | 0x8);
            return v.toString(16);
          });
        }

        async function fetch(url, options = {}) {
          const method = options.method || 'GET';
          const headers = options.headers || {};
          let body = options.body;
          if (typeof body === 'string') {
            body = Convert.encodeUtf8(body);
          }
          const res = Network.fetchBytes(method, url, headers, body || []);
          const toArrayBuffer = (payload) => {
            if (!payload) return new ArrayBuffer(0);
            if (payload instanceof ArrayBuffer) return payload;
            if (ArrayBuffer.isView(payload)) return payload.buffer;
            if (Array.isArray(payload)) return new Uint8Array(payload).buffer;
            return new ArrayBuffer(0);
          };
          const bytes = toArrayBuffer(res.body);
          return {
            ok: res.status >= 200 && res.status < 300,
            status: res.status,
            headers: res.headers,
            url,
            arrayBuffer: async () => bytes,
            text: async () => Convert.decodeUtf8(new Uint8Array(bytes)),
            json: async () => JSON.parse(Convert.decodeUtf8(new Uint8Array(bytes)))
          };
        }

        function btoa(s){ return Convert.encodeBase64(Convert.encodeUtf8(s)); }
        function atob(s){ return Convert.decodeUtf8(Convert.decodeBase64(s)); }
        function randomInt(min, max){ return Convert.randomInt(min, max); }
        """

        _ = ctx.evaluateScript(prelude)
        if let exception = ctx.exception {
            throw ScriptEngineError.scriptException(exception.toString())
        }
    }

    private func installBridgeObjects(on ctx: JSContext) throws {
        let bridgeStorage = JSValue(newObjectIn: ctx)!
        let saveData: @convention(block) (String, Any?) -> Void = { [weak self] key, value in
            guard let self else { return }
            var store = self.bridgeStoreRead()
            var data = store["data"] as? [String: Any] ?? [:]
            if let pv = self.sanitizePropertyList(value) {
                data[key] = pv
            } else {
                data.removeValue(forKey: key)
            }
            store["data"] = data
            self.bridgeStoreWrite(store)
        }
        let loadData: @convention(block) (String) -> Any? = { [weak self] key in
            guard let self else { return nil }
            let store = self.bridgeStoreRead()
            let data = store["data"] as? [String: Any] ?? [:]
            return data[key]
        }
        let deleteData: @convention(block) (String) -> Void = { [weak self] key in
            guard let self else { return }
            var store = self.bridgeStoreRead()
            var data = store["data"] as? [String: Any] ?? [:]
            data.removeValue(forKey: key)
            store["data"] = data
            self.bridgeStoreWrite(store)
        }
        let saveSetting: @convention(block) (String, Any?) -> Void = { [weak self] key, value in
            guard let self else { return }
            var store = self.bridgeStoreRead()
            var data = store["settings"] as? [String: Any] ?? [:]
            if let pv = self.sanitizePropertyList(value) {
                data[key] = pv
            } else {
                data.removeValue(forKey: key)
            }
            store["settings"] = data
            self.bridgeStoreWrite(store)
        }
        let loadSetting: @convention(block) (String) -> Any? = { [weak self] key in
            guard let self else { return nil }
            let store = self.bridgeStoreRead()
            let data = store["settings"] as? [String: Any] ?? [:]
            return data[key]
        }

        bridgeStorage.setObject(unsafeBitCast(saveData, to: AnyObject.self), forKeyedSubscript: "saveData" as NSString)
        bridgeStorage.setObject(unsafeBitCast(loadData, to: AnyObject.self), forKeyedSubscript: "loadData" as NSString)
        bridgeStorage.setObject(unsafeBitCast(deleteData, to: AnyObject.self), forKeyedSubscript: "deleteData" as NSString)
        bridgeStorage.setObject(unsafeBitCast(saveSetting, to: AnyObject.self), forKeyedSubscript: "saveSetting" as NSString)
        bridgeStorage.setObject(unsafeBitCast(loadSetting, to: AnyObject.self), forKeyedSubscript: "loadSetting" as NSString)
        ctx.setObject(bridgeStorage, forKeyedSubscript: "BridgeStorage" as NSString)

        let network = JSValue(newObjectIn: ctx)!

        let sendRequest: @convention(block) (String, String, [String: Any]?, Any?) -> [String: Any] = {
            method, url, headers, data in
            Self.performRequest(method: method, url: url, headers: headers, bodyLike: data)
        }
        let fetchBytes: @convention(block) (String, String, [String: Any]?, Any?) -> [String: Any] = {
            method, url, headers, data in
            Self.performRequestBytes(method: method, url: url, headers: headers, bodyLike: data)
        }
        let get: @convention(block) (String, [String: Any]?) -> [String: Any] = { url, headers in
            Self.performRequest(method: "GET", url: url, headers: headers, bodyLike: nil)
        }
        let post: @convention(block) (String, [String: Any]?, Any?) -> [String: Any] = { url, headers, data in
            Self.performRequest(method: "POST", url: url, headers: headers, bodyLike: data)
        }
        let put: @convention(block) (String, [String: Any]?, Any?) -> [String: Any] = { url, headers, data in
            Self.performRequest(method: "PUT", url: url, headers: headers, bodyLike: data)
        }
        let patch: @convention(block) (String, [String: Any]?, Any?) -> [String: Any] = { url, headers, data in
            Self.performRequest(method: "PATCH", url: url, headers: headers, bodyLike: data)
        }
        let del: @convention(block) (String, [String: Any]?) -> [String: Any] = { url, headers in
            Self.performRequest(method: "DELETE", url: url, headers: headers, bodyLike: nil)
        }

        let getCookies: @convention(block) (String) -> [[String: Any]] = { urlStr in
            guard let url = URL(string: urlStr) else { return [] }
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            return cookies.map { cookie in
                [
                    "name": cookie.name,
                    "value": cookie.value,
                    "domain": cookie.domain,
                    "path": cookie.path,
                    "expires": cookie.expiresDate?.timeIntervalSince1970 as Any
                ]
            }
        }

        let setCookies: @convention(block) (String, [[String: Any]]) -> Void = { urlStr, cookies in
            guard let url = URL(string: urlStr) else { return }
            for item in cookies {
                var props: [HTTPCookiePropertyKey: Any] = [
                    .domain: item["domain"] as? String ?? url.host ?? "",
                    .path: item["path"] as? String ?? "/",
                    .name: item["name"] as? String ?? "",
                    .value: item["value"] as? String ?? ""
                ]
                if let expires = item["expires"] as? TimeInterval {
                    props[.expires] = Date(timeIntervalSince1970: expires)
                }
                if let cookie = HTTPCookie(properties: props) {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
            }
        }

        let deleteCookies: @convention(block) (String) -> Void = { urlStr in
            guard let url = URL(string: urlStr) else { return }
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            for cookie in cookies {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }

        network.setObject(unsafeBitCast(sendRequest, to: AnyObject.self), forKeyedSubscript: "sendRequest" as NSString)
        network.setObject(unsafeBitCast(fetchBytes, to: AnyObject.self), forKeyedSubscript: "fetchBytes" as NSString)
        network.setObject(unsafeBitCast(get, to: AnyObject.self), forKeyedSubscript: "get" as NSString)
        network.setObject(unsafeBitCast(post, to: AnyObject.self), forKeyedSubscript: "post" as NSString)
        network.setObject(unsafeBitCast(put, to: AnyObject.self), forKeyedSubscript: "put" as NSString)
        network.setObject(unsafeBitCast(patch, to: AnyObject.self), forKeyedSubscript: "patch" as NSString)
        network.setObject(unsafeBitCast(del, to: AnyObject.self), forKeyedSubscript: "delete" as NSString)
        network.setObject(unsafeBitCast(getCookies, to: AnyObject.self), forKeyedSubscript: "getCookies" as NSString)
        network.setObject(unsafeBitCast(setCookies, to: AnyObject.self), forKeyedSubscript: "setCookies" as NSString)
        network.setObject(unsafeBitCast(deleteCookies, to: AnyObject.self), forKeyedSubscript: "deleteCookies" as NSString)

        ctx.setObject(network, forKeyedSubscript: "Network" as NSString)

        let convert = JSValue(newObjectIn: ctx)!

        let encodeUtf8: @convention(block) (String) -> [Int] = { str in
            Array(str.utf8).map(Int.init)
        }
        let decodeUtf8: @convention(block) (Any?) -> String = { value in
            String(decoding: bytesFromAny(value), as: UTF8.self)
        }
        let encodeBase64: @convention(block) (Any?) -> String = { value in
            Data(bytesFromAny(value)).base64EncodedString()
        }
        let decodeBase64: @convention(block) (String) -> [Int] = { value in
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let data = Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters]) ?? Data()
            return data.map(Int.init)
        }
        let hexEncode: @convention(block) (Any?) -> String = { value in
            bytesFromAny(value).map { String(format: "%02x", $0) }.joined()
        }
        let md5: @convention(block) (Any?) -> [Int] = { value in
            let digest = Insecure.MD5.hash(data: Data(bytesFromAny(value)))
            return Array(digest).map(Int.init)
        }
        let sha1: @convention(block) (Any?) -> [Int] = { value in
            let digest = Insecure.SHA1.hash(data: Data(bytesFromAny(value)))
            return Array(digest).map(Int.init)
        }
        let sha256: @convention(block) (Any?) -> [Int] = { value in
            let digest = SHA256.hash(data: Data(bytesFromAny(value)))
            return Array(digest).map(Int.init)
        }
        let sha512: @convention(block) (Any?) -> [Int] = { value in
            let digest = SHA512.hash(data: Data(bytesFromAny(value)))
            return Array(digest).map(Int.init)
        }
        let hmacString: @convention(block) (Any?, Any?, String) -> String = { key, value, hash in
            let keyData = Data(bytesFromAny(key))
            let valData = Data(bytesFromAny(value))
            switch hash.lowercased() {
            case "sha1":
                let k = SymmetricKey(data: keyData)
                let mac = HMAC<Insecure.SHA1>.authenticationCode(for: valData, using: k)
                return Data(mac).map { String(format: "%02x", $0) }.joined()
            case "sha512":
                let k = SymmetricKey(data: keyData)
                let mac = HMAC<SHA512>.authenticationCode(for: valData, using: k)
                return Data(mac).map { String(format: "%02x", $0) }.joined()
            default:
                let k = SymmetricKey(data: keyData)
                let mac = HMAC<SHA256>.authenticationCode(for: valData, using: k)
                return Data(mac).map { String(format: "%02x", $0) }.joined()
            }
        }
        let randomInt: @convention(block) (Int, Int) -> Int = { min, max in
            if min >= max { return min }
            return Int.random(in: min...max)
        }
        let decryptAesCbc: @convention(block) (Any?, Any?, Any?) -> [Int] = { data, key, iv in
            let out = aesCBC(operation: CCOperation(kCCDecrypt), data: bytesFromAny(data), key: bytesFromAny(key), iv: bytesFromAny(iv))
            return out.map(Int.init)
        }
        let encryptAesCbc: @convention(block) (Any?, Any?, Any?) -> [Int] = { data, key, iv in
            let out = aesCBC(operation: CCOperation(kCCEncrypt), data: bytesFromAny(data), key: bytesFromAny(key), iv: bytesFromAny(iv))
            return out.map(Int.init)
        }
        let decryptAesEcb: @convention(block) (Any?, Any?) -> [Int] = { data, key in
            let out = aesECB(operation: CCOperation(kCCDecrypt), data: bytesFromAny(data), key: bytesFromAny(key))
            return out.map(Int.init)
        }
        let encryptAesEcb: @convention(block) (Any?, Any?) -> [Int] = { data, key in
            let out = aesECB(operation: CCOperation(kCCEncrypt), data: bytesFromAny(data), key: bytesFromAny(key))
            return out.map(Int.init)
        }

        convert.setObject(unsafeBitCast(encodeUtf8, to: AnyObject.self), forKeyedSubscript: "encodeUtf8" as NSString)
        convert.setObject(unsafeBitCast(decodeUtf8, to: AnyObject.self), forKeyedSubscript: "decodeUtf8" as NSString)
        convert.setObject(unsafeBitCast(encodeBase64, to: AnyObject.self), forKeyedSubscript: "encodeBase64" as NSString)
        convert.setObject(unsafeBitCast(decodeBase64, to: AnyObject.self), forKeyedSubscript: "decodeBase64" as NSString)
        convert.setObject(unsafeBitCast(hexEncode, to: AnyObject.self), forKeyedSubscript: "hexEncode" as NSString)
        convert.setObject(unsafeBitCast(md5, to: AnyObject.self), forKeyedSubscript: "md5" as NSString)
        convert.setObject(unsafeBitCast(sha1, to: AnyObject.self), forKeyedSubscript: "sha1" as NSString)
        convert.setObject(unsafeBitCast(sha256, to: AnyObject.self), forKeyedSubscript: "sha256" as NSString)
        convert.setObject(unsafeBitCast(sha512, to: AnyObject.self), forKeyedSubscript: "sha512" as NSString)
        convert.setObject(unsafeBitCast(hmacString, to: AnyObject.self), forKeyedSubscript: "hmacString" as NSString)
        convert.setObject(unsafeBitCast(randomInt, to: AnyObject.self), forKeyedSubscript: "randomInt" as NSString)
        convert.setObject(unsafeBitCast(decryptAesEcb, to: AnyObject.self), forKeyedSubscript: "decryptAesEcb" as NSString)
        convert.setObject(unsafeBitCast(encryptAesEcb, to: AnyObject.self), forKeyedSubscript: "encryptAesEcb" as NSString)
        convert.setObject(unsafeBitCast(decryptAesCbc, to: AnyObject.self), forKeyedSubscript: "decryptAesCbc" as NSString)
        convert.setObject(unsafeBitCast(encryptAesCbc, to: AnyObject.self), forKeyedSubscript: "encryptAesCbc" as NSString)

        ctx.setObject(convert, forKeyedSubscript: "Convert" as NSString)

        let bridgeUI = JSValue(newObjectIn: ctx)!
        let showMessage: @convention(block) (String) -> Void = { message in
            if RuntimeDebugConsole.isEnabled {
                RuntimeDebugConsole.shared.append("[SourceRuntime][INFO][UI] \(message)")
            }
        }
        let showDialog: @convention(block) (String, String, [String]) -> Int = { title, content, labels in
            if RuntimeDebugConsole.isEnabled {
                RuntimeDebugConsole.shared.append("[SourceRuntime][INFO][UI] dialog: \(title) | \(content)")
            }
            return BridgeUIRuntime.showDialog(title: title, message: content, actions: labels)
        }
        let showInputDialog: @convention(block) (String) -> String = { title in
            if RuntimeDebugConsole.isEnabled {
                RuntimeDebugConsole.shared.append("[SourceRuntime][INFO][UI] input dialog requested: \(title)")
            }
            return BridgeUIRuntime.showInputDialog(title: title) ?? ""
        }
        let launchUrl: @convention(block) (String) -> Void = { urlStr in
            guard let url = URL(string: urlStr) else { return }
            DispatchQueue.main.async {
                UIApplication.shared.open(url)
            }
        }
        let copyToClipboard: @convention(block) (String) -> Void = { text in
            DispatchQueue.main.async {
                UIPasteboard.general.string = text
            }
        }
        bridgeUI.setObject(unsafeBitCast(showMessage, to: AnyObject.self), forKeyedSubscript: "showMessage" as NSString)
        bridgeUI.setObject(unsafeBitCast(showDialog, to: AnyObject.self), forKeyedSubscript: "showDialog" as NSString)
        bridgeUI.setObject(unsafeBitCast(showInputDialog, to: AnyObject.self), forKeyedSubscript: "showInputDialog" as NSString)
        bridgeUI.setObject(unsafeBitCast(launchUrl, to: AnyObject.self), forKeyedSubscript: "launchUrl" as NSString)
        bridgeUI.setObject(unsafeBitCast(copyToClipboard, to: AnyObject.self), forKeyedSubscript: "copyToClipboard" as NSString)
        ctx.setObject(bridgeUI, forKeyedSubscript: "BridgeUI" as NSString)

        let html = JSValue(newObjectIn: ctx)!
        let parse: @convention(block) (String) -> Int = { html in
            HtmlRuntimeBridge.shared.parse(html: html)
        }
        let querySelector: @convention(block) (Int, String) -> Int = { key, query in
            HtmlRuntimeBridge.shared.querySelector(documentKey: key, query: query) ?? 0
        }
        let querySelectorAll: @convention(block) (Int, String) -> [Int] = { key, query in
            HtmlRuntimeBridge.shared.querySelectorAll(documentKey: key, query: query)
        }
        let getElementById: @convention(block) (Int, String) -> Int = { key, id in
            HtmlRuntimeBridge.shared.getElementById(documentKey: key, id: id) ?? 0
        }
        let elementQuerySelector: @convention(block) (Int, String) -> Int = { key, query in
            HtmlRuntimeBridge.shared.elementQuerySelector(elementKey: key, query: query) ?? 0
        }
        let elementQuerySelectorAll: @convention(block) (Int, String) -> [Int] = { key, query in
            HtmlRuntimeBridge.shared.elementQuerySelectorAll(elementKey: key, query: query)
        }
        let children: @convention(block) (Int) -> [Int] = { key in
            HtmlRuntimeBridge.shared.children(elementKey: key)
        }
        let text: @convention(block) (Int) -> String = { key in
            HtmlRuntimeBridge.shared.text(elementKey: key)
        }
        let innerHTML: @convention(block) (Int) -> String = { key in
            HtmlRuntimeBridge.shared.innerHTML(elementKey: key)
        }
        let attributes: @convention(block) (Int) -> [String: String] = { key in
            HtmlRuntimeBridge.shared.attributes(elementKey: key)
        }
        let dispose: @convention(block) (Int) -> Void = { key in
            HtmlRuntimeBridge.shared.dispose(documentKey: key)
        }

        html.setObject(unsafeBitCast(parse, to: AnyObject.self), forKeyedSubscript: "parse" as NSString)
        html.setObject(unsafeBitCast(querySelector, to: AnyObject.self), forKeyedSubscript: "querySelector" as NSString)
        html.setObject(unsafeBitCast(querySelectorAll, to: AnyObject.self), forKeyedSubscript: "querySelectorAll" as NSString)
        html.setObject(unsafeBitCast(getElementById, to: AnyObject.self), forKeyedSubscript: "getElementById" as NSString)
        html.setObject(unsafeBitCast(elementQuerySelector, to: AnyObject.self), forKeyedSubscript: "elementQuerySelector" as NSString)
        html.setObject(unsafeBitCast(elementQuerySelectorAll, to: AnyObject.self), forKeyedSubscript: "elementQuerySelectorAll" as NSString)
        html.setObject(unsafeBitCast(children, to: AnyObject.self), forKeyedSubscript: "children" as NSString)
        html.setObject(unsafeBitCast(text, to: AnyObject.self), forKeyedSubscript: "text" as NSString)
        html.setObject(unsafeBitCast(innerHTML, to: AnyObject.self), forKeyedSubscript: "innerHTML" as NSString)
        html.setObject(unsafeBitCast(attributes, to: AnyObject.self), forKeyedSubscript: "attributes" as NSString)
        html.setObject(unsafeBitCast(dispose, to: AnyObject.self), forKeyedSubscript: "dispose" as NSString)
        ctx.setObject(html, forKeyedSubscript: "Html" as NSString)
    }

    private static func performRequest(
        method: String,
        url: String,
        headers: [String: Any]?,
        bodyLike: Any?
    ) -> [String: Any] {
        let sanitizedURL = sanitizeRequestURL(url)
        jsDebugLog("HTTP request: method=\(method), url=\(sanitizedURL)")
        guard let urlObj = URL(string: sanitizedURL) else {
            return ["status": 0, "headers": [:], "body": "invalid url"]
        }

        var request = URLRequest(url: urlObj)
        request.httpMethod = method
        request.timeoutInterval = 35
        request.httpShouldHandleCookies = true

        if let headers {
            var scriptCookieHeader: String?
            for (k, v) in headers {
                if k.compare("Cookie", options: .caseInsensitive) == .orderedSame {
                    let value = String(describing: v).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        scriptCookieHeader = value
                    }
                } else {
                    request.setValue(String(describing: v), forHTTPHeaderField: k)
                }
            }

            if scriptCookieHeader != nil || request.value(forHTTPHeaderField: "Cookie") == nil {
                let storedCookies = HTTPCookieStorage.shared.cookies(for: urlObj) ?? []
                var mergedCookie = HTTPCookie.requestHeaderFields(with: storedCookies)["Cookie"] ?? ""
                if let scriptCookieHeader, !scriptCookieHeader.isEmpty {
                    if mergedCookie.isEmpty {
                        mergedCookie = scriptCookieHeader
                    } else {
                        mergedCookie += "; \(scriptCookieHeader)"
                    }
                }
                if !mergedCookie.isEmpty {
                    request.setValue(mergedCookie, forHTTPHeaderField: "Cookie")
                }
            }
        }

        if methodAllowsRequestBody(method),
           let bodyData = encodeRequestBody(bodyLike: bodyLike, contentType: request.value(forHTTPHeaderField: "Content-Type")) {
            request.httpBody = bodyData
        } else if !methodAllowsRequestBody(method) {
            request.httpBody = nil
            request.setValue(nil, forHTTPHeaderField: "Content-Length")
        }

        var result: [String: Any] = [
            "status": 0,
            "statusCode": 0,
            "headers": [String: Any](),
            "body": "",
            "error": NSNull()
        ]
        let executed = executeDataRequestWithRetry(request: request, method: method, url: sanitizedURL)
        let responseData = executed.data
        let responseObj = executed.response
        let responseErr = executed.error

        if let error = responseErr {
            jsDebugLog("HTTP request failed: method=\(method), url=\(sanitizedURL), error=\(error.localizedDescription)", level: .error)
            return [
                "status": 0,
                "statusCode": 0,
                "headers": [String: Any](),
                "body": error.localizedDescription,
                "error": error.localizedDescription,
                "url": sanitizedURL
            ]
        }

        guard let http = responseObj as? HTTPURLResponse else {
            jsDebugLog("HTTP request invalid response: method=\(method), url=\(sanitizedURL), response=\(String(describing: responseObj))", level: .error)
            return [
                "status": 0,
                "statusCode": 0,
                "headers": [String: Any](),
                "body": "invalid response",
                "error": "invalid response",
                "url": sanitizedURL
            ]
        }

        var headersObj: [String: Any] = [:]
        for (k, v) in http.allHeaderFields {
            let key = String(describing: k)
            let val = normalizeHeaderValue(name: key, value: v)
            headersObj[key] = val
            headersObj[key.lowercased()] = val
        }

        let body = String(data: responseData ?? Data(), encoding: .utf8) ?? ""
        result = [
            "status": http.statusCode,
            "statusCode": http.statusCode,
            "headers": headersObj,
            "body": body,
            "error": NSNull(),
            "url": sanitizedURL
        ]
        if (200..<300).contains(http.statusCode) {
            jsDebugLog("HTTP response: method=\(method), url=\(sanitizedURL), status=\(http.statusCode), bodyLen=\(body.count)")
        } else {
            let bodyPreview = String(body.prefix(220)).replacingOccurrences(of: "\n", with: " ")
            jsDebugLog(
                "HTTP response: method=\(method), url=\(sanitizedURL), status=\(http.statusCode), bodyLen=\(body.count), bodyPreview=\(bodyPreview)",
                level: .warn
            )
        }
        return result
    }

    private static func performRequestBytes(
        method: String,
        url: String,
        headers: [String: Any]?,
        bodyLike: Any?
    ) -> [String: Any] {
        let sanitizedURL = sanitizeRequestURL(url)
        guard let urlObj = URL(string: sanitizedURL) else {
            return ["status": 0, "headers": [String: Any](), "body": [Int]()]
        }
        var request = URLRequest(url: urlObj)
        request.httpMethod = method
        request.timeoutInterval = 35
        request.httpShouldHandleCookies = true
        if let headers {
            for (k, v) in headers {
                request.setValue(String(describing: v), forHTTPHeaderField: k)
            }
        }
        if methodAllowsRequestBody(method),
           let bodyData = encodeRequestBody(bodyLike: bodyLike, contentType: request.value(forHTTPHeaderField: "Content-Type")) {
            request.httpBody = bodyData
        } else if !methodAllowsRequestBody(method) {
            request.httpBody = nil
            request.setValue(nil, forHTTPHeaderField: "Content-Length")
        }

        var result: [String: Any] = [
            "status": 0,
            "statusCode": 0,
            "headers": [String: Any](),
            "body": [Int](),
            "error": NSNull()
        ]
        let executed = executeDataRequestWithRetry(request: request, method: method, url: sanitizedURL)
        let responseData = executed.data
        let responseObj = executed.response
        let responseErr = executed.error

        if let error = responseErr {
            jsDebugLog("HTTP bytes request failed: method=\(method), url=\(sanitizedURL), error=\(error.localizedDescription)", level: .error)
            return [
                "status": 0,
                "statusCode": 0,
                "headers": [String: Any](),
                "body": [Int](),
                "error": error.localizedDescription,
                "url": sanitizedURL
            ]
        }

        guard let http = responseObj as? HTTPURLResponse else {
            jsDebugLog("HTTP bytes request invalid response: method=\(method), url=\(sanitizedURL), response=\(String(describing: responseObj))", level: .error)
            return [
                "status": 0,
                "statusCode": 0,
                "headers": [String: Any](),
                "body": [Int](),
                "error": "invalid response",
                "url": sanitizedURL
            ]
        }
        var headersObj: [String: Any] = [:]
        for (k, v) in http.allHeaderFields {
            let key = String(describing: k)
            let val = normalizeHeaderValue(name: key, value: v)
            headersObj[key] = val
            headersObj[key.lowercased()] = val
        }
        let bytes = (responseData ?? Data()).map(Int.init)
        result = [
            "status": http.statusCode,
            "statusCode": http.statusCode,
            "headers": headersObj,
            "body": bytes,
            "error": NSNull(),
            "url": sanitizedURL
        ]
        return result
    }

    private static func sanitizeRequestURL(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL),
              let items = components.queryItems,
              !items.isEmpty else {
            return rawURL
        }
        let filtered = items.filter { item in
            if item.name.caseInsensitiveCompare("request_id") == .orderedSame {
                let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !value.isEmpty
            }
            return true
        }
        guard filtered.count != items.count else { return rawURL }
        components.queryItems = filtered.isEmpty ? nil : filtered
        return components.url?.absoluteString ?? rawURL
    }

    private static func methodAllowsRequestBody(_ method: String) -> Bool {
        let normalized = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized != "GET" && normalized != "HEAD"
    }

    private static func executeDataRequestWithRetry(
        request: URLRequest,
        method: String,
        url: String
    ) -> (data: Data?, response: URLResponse?, error: Error?) {
        let maxTimeoutRetry = 1
        let maxRedirects = 4
        let waitSeconds = max(15.0, request.timeoutInterval + 5.0)
        var attempt = 0
        var currentRequest = request
        var currentURL = url
        var redirectCount = 0
        while true {
            attempt += 1
            let executed = performDataRequestWithoutRedirects(
                request: currentRequest,
                method: method,
                url: currentURL,
                waitSeconds: waitSeconds
            )
            let responseData = executed.data
            let responseObj = executed.response
            let responseErr = executed.error

            if let nsError = responseErr as NSError?,
               nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorDataLengthExceedsMaximum {
                jsDebugLog("HTTP request exceeded in-memory size, retrying via downloadTask: method=\(method), url=\(currentURL)", level: .warn)
                return performRequestViaDownload(request: currentRequest)
            }

            if responseErr == nil,
               let httpResponse = responseObj as? HTTPURLResponse,
               let redirected = makeRedirectedRequest(
                    from: currentRequest,
                    response: httpResponse,
                    maxRedirects: maxRedirects,
                    redirectCount: redirectCount
               ) {
                redirectCount += 1
                currentRequest = redirected
                currentURL = redirected.url?.absoluteString ?? currentURL
                attempt = 0
                continue
            }

            if let nsError = responseErr as NSError?,
               nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorTimedOut,
               attempt <= maxTimeoutRetry {
                jsDebugLog("HTTP request timeout, retry once: method=\(method), url=\(currentURL), attempt=\(attempt)", level: .warn)
                continue
            }

            if responseErr == nil, responseObj == nil, attempt <= 2 {
                jsDebugLog("HTTP request returned empty response, retrying: method=\(method), url=\(currentURL), attempt=\(attempt)", level: .warn)
                continue
            }

            return (responseData, responseObj, responseErr)
        }
    }

    private static func performDataRequestWithoutRedirects(
        request: URLRequest,
        method: String,
        url: String,
        waitSeconds: TimeInterval
    ) -> (data: Data?, response: URLResponse?, error: Error?) {
        let session = URLSession(
            configuration: .default,
            delegate: RedirectBlockingDelegate(),
            delegateQueue: nil
        )
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseObj: URLResponse?
        var responseErr: Error?
        var task: URLSessionDataTask?

        task = session.dataTask(with: request) { data, response, error in
            responseData = data
            responseObj = response
            responseErr = error
            semaphore.signal()
        }
        task?.resume()
        let waitResult = semaphore.wait(timeout: .now() + waitSeconds)
        if waitResult == .timedOut {
            task?.cancel()
            responseErr = URLError(.timedOut)
            jsDebugLog("HTTP request semaphore timeout: method=\(method), url=\(url), wait=\(waitSeconds)s", level: .warn)
        }
        session.finishTasksAndInvalidate()
        return (responseData, responseObj, responseErr)
    }

    private static func makeRedirectedRequest(
        from request: URLRequest,
        response: HTTPURLResponse,
        maxRedirects: Int,
        redirectCount: Int
    ) -> URLRequest? {
        guard (300...399).contains(response.statusCode) else { return nil }
        guard redirectCount < maxRedirects else {
            jsDebugLog("HTTP redirect limit reached: status=\(response.statusCode), url=\(request.url?.absoluteString ?? "")", level: .warn)
            return nil
        }
        guard let locationValue = response.value(forHTTPHeaderField: "Location"),
              let baseURL = request.url,
              let redirectedURL = URL(string: locationValue, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }

        var redirected = request
        redirected.url = redirectedURL
        redirected.mainDocumentURL = redirectedURL
        if let host = redirectedURL.host {
            redirected.setValue(host, forHTTPHeaderField: "Host")
        }
        if let origin = request.url?.absoluteString {
            redirected.setValue(origin, forHTTPHeaderField: "Referer")
        }
        jsDebugLog(
            "HTTP redirect intercepted: status=\(response.statusCode), from=\(request.url?.absoluteString ?? ""), to=\(redirectedURL.absoluteString), preserving method=\(request.httpMethod ?? "GET")",
            level: .info
        )
        return redirected
    }

    private static func performRequestViaDownload(request: URLRequest) -> (data: Data?, response: URLResponse?, error: Error?) {
        let waitSeconds = max(20.0, request.timeoutInterval + 8.0)
        let semaphore = DispatchSemaphore(value: 0)
        var outData: Data?
        var outResponse: URLResponse?
        var outError: Error?
        var task: URLSessionDownloadTask?

        task = URLSession.shared.downloadTask(with: request) { localURL, response, error in
            defer { semaphore.signal() }
            outResponse = response
            if let error {
                outError = error
                return
            }
            guard let localURL else {
                return
            }
            outData = try? Data(contentsOf: localURL)
        }
        task?.resume()
        let waitResult = semaphore.wait(timeout: .now() + waitSeconds)
        if waitResult == .timedOut {
            task?.cancel()
            outError = URLError(.timedOut)
            jsDebugLog("HTTP downloadTask semaphore timeout: wait=\(waitSeconds)s", level: .warn)
        }
        return (outData, outResponse, outError)
    }
}

private func aesCBC(operation: CCOperation, data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
    guard !data.isEmpty, !key.isEmpty else { return [] }
    let keyLen = key.count
    guard keyLen == kCCKeySizeAES128 || keyLen == kCCKeySizeAES192 || keyLen == kCCKeySizeAES256 else {
        return []
    }
    var outLength = 0
    var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
    let outCapacity = out.count
    let status = key.withUnsafeBytes { keyPtr in
        data.withUnsafeBytes { dataPtr in
            iv.withUnsafeBytes { ivPtr in
                out.withUnsafeMutableBytes { outPtr in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress, keyLen,
                        ivPtr.baseAddress,
                        dataPtr.baseAddress, data.count,
                        outPtr.baseAddress, outCapacity,
                        &outLength
                    )
                }
            }
        }
    }
    guard status == kCCSuccess else { return [] }
    return Array(out.prefix(outLength))
}

private func aesECB(operation: CCOperation, data: [UInt8], key: [UInt8]) -> [UInt8] {
    guard !data.isEmpty, !key.isEmpty else { return [] }
    let keyLen = key.count
    guard keyLen == kCCKeySizeAES128 || keyLen == kCCKeySizeAES192 || keyLen == kCCKeySizeAES256 else {
        return []
    }
    guard data.count.isMultiple(of: kCCBlockSizeAES128) else {
        return []
    }
    var outLength = 0
    var out = [UInt8](repeating: 0, count: data.count)
    let outCapacity = out.count
    let status = key.withUnsafeBytes { keyPtr in
        data.withUnsafeBytes { dataPtr in
            out.withUnsafeMutableBytes { outPtr in
                CCCrypt(
                    operation,
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyPtr.baseAddress, keyLen,
                    nil,
                    dataPtr.baseAddress, data.count,
                    outPtr.baseAddress, outCapacity,
                    &outLength
                )
            }
        }
    }
    guard status == kCCSuccess else { return [] }
    return Array(out.prefix(outLength))
}

private func encodeRequestBody(bodyLike: Any?, contentType: String?) -> Data? {
    guard let bodyLike else { return nil }

    let rawBytes = bytesFromAny(bodyLike)
    if !rawBytes.isEmpty {
        return Data(rawBytes)
    }

    if let dict = bodyLike as? [String: Any],
       let data = try? JSONSerialization.data(withJSONObject: dict) {
        return data
    }
    if let dict = bodyLike as? NSDictionary,
       JSONSerialization.isValidJSONObject(dict),
       let data = try? JSONSerialization.data(withJSONObject: dict) {
        return data
    }

    if let arr = bodyLike as? [Any],
       JSONSerialization.isValidJSONObject(arr),
       let data = try? JSONSerialization.data(withJSONObject: arr) {
        return data
    }
    if let arr = bodyLike as? NSArray,
       JSONSerialization.isValidJSONObject(arr),
       let data = try? JSONSerialization.data(withJSONObject: arr) {
        return data
    }

    if let contentType, contentType.lowercased().contains("application/x-www-form-urlencoded"),
       let dict = bodyLike as? [String: Any] {
        let query = dict
            .map { key, value in
                "\(percentEscape(key))=\(percentEscape(String(describing: value)))"
            }
            .joined(separator: "&")
        return query.data(using: .utf8)
    }

    return nil
}

private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private func normalizeHeaderValue(name: String, value: Any) -> Any {
    if let array = value as? [Any] {
        return array.map { String(describing: $0) }
    }
    if let nsArray = value as? NSArray {
        return nsArray.compactMap { String(describing: $0) }
    }

    let text = String(describing: value)
    if name.lowercased() == "set-cookie" {
        let split = splitSetCookieHeader(text)
        if split.count > 1 {
            return split
        }
    }
    return text
}

private func splitSetCookieHeader(_ header: String) -> [String] {
    guard !header.isEmpty else { return [] }
    var result: [String] = []
    var current = ""
    var i = header.startIndex
    while i < header.endIndex {
        let ch = header[i]
        if ch == "," {
            let next = header.index(after: i)
            if next < header.endIndex {
                let suffix = header[next...]
                let tokenPrefix = suffix.prefix { $0 != ";" && $0 != "," }
                if tokenPrefix.contains("=") && !tokenPrefix.lowercased().contains("expires=") {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        result.append(trimmed)
                    }
                    current.removeAll(keepingCapacity: true)
                    i = next
                    continue
                }
            }
        }
        current.append(ch)
        i = header.index(after: i)
    }
    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        result.append(trimmed)
    }
    return result
}

private func percentEscape(_ text: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
}

private enum BridgeUIRuntime {
    static func showDialog(title: String, message: String, actions: [String]) -> Int {
        let normalized = actions.isEmpty ? ["OK"] : actions
        return runBlockingOnMain(defaultValue: 0) {
            guard let host = topController() else { return 0 }
            var selected = 0
            let semaphore = DispatchSemaphore(value: 0)
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            for (idx, label) in normalized.enumerated() {
                alert.addAction(UIAlertAction(title: label.isEmpty ? "Action \(idx + 1)" : label, style: .default) { _ in
                    selected = idx
                    semaphore.signal()
                })
            }
            host.present(alert, animated: true)
            _ = semaphore.wait(timeout: .now() + 120)
            return selected
        }
    }

    static func showInputDialog(title: String) -> String? {
        runBlockingOnMain(defaultValue: nil) {
            guard let host = topController() else { return nil }
            var text: String?
            let semaphore = DispatchSemaphore(value: 0)
            let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
            alert.addTextField { tf in
                tf.placeholder = "Input"
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                text = nil
                semaphore.signal()
            })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                text = alert.textFields?.first?.text
                semaphore.signal()
            })
            host.present(alert, animated: true)
            _ = semaphore.wait(timeout: .now() + 180)
            return text
        }
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    private static func runBlockingOnMain<T>(defaultValue: T, _ work: @escaping () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        var result = defaultValue
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            result = work()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 180)
        return result
    }
}

private func bytesFromAny(_ any: Any?) -> [UInt8] {
    guard let any else { return [] }

    if let data = any as? Data {
        return [UInt8](data)
    }

    if let str = any as? String {
        return [UInt8](str.utf8)
    }

    if let nums = any as? [Int] {
        return nums.map { UInt8($0 & 0xff) }
    }

    if let nums = any as? [Double] {
        return nums.map { UInt8(Int($0) & 0xff) }
    }

    if let arr = any as? [Any] {
        return arr.compactMap {
            if let i = $0 as? Int { return UInt8(i & 0xff) }
            if let d = $0 as? Double { return UInt8(Int(d) & 0xff) }
            return nil
        }
    }

    return []
}
