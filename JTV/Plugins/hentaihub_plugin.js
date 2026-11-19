// =============================================================================
// Hentai Hub plugin v1.0.0 — ONE combined plugin, THREE source adapters.
// Built 2026-11-18 from the measured source hunt (HENTAI-SOURCE-HUNT.md).
// The owner ordered every quality hentai source that verifies folded
// into a single plugin; catalogues stay per-source (labelled rails,
// source-scoped genres, source-prefixed ids) — never one merged list.
//
//   hs:   hstream.moe    — fully verified end-to-end from the VM:
//         list /search?order=recently-released (25/page, page= works),
//         search /search?search=<kw> (verified filtering), tag lists
//         /search?tags[0]=<tag>. Detail /hentai/<slug>-<ep> carries a
//         hidden #e_id and the session CSRF token in the Livewire
//         script tag's data-csrf attribute. Playback: POST
//         /player/api {"episode_id":N,"_token":T} with header
//         X-CSRF-TOKEN: T — measured 200 (the hunt's cookie-derived
//         X-XSRF-TOKEN also works, but a plugin cannot read cookies;
//         the page-embedded token is the in-contract equivalent, and
//         the app's shared cookie jar rides along on the POST anyway).
//         Response JSON -> <stream_domain>/<stream_url>/x264.720p.mp4
//         (range GET verified 206 video/mp4, 115,556,776 bytes on the
//         sampled title; x264.1080p.mp4 measured 404 — higher variant
//         file naming is NOT confirmed, so v1 ships the verified 720p
//         file) + eng.vtt / eng.ass subtitles alongside.
//   haho: haho.moe       — series /anime/<id> (24/page, ?page= works),
//         search /anime?q=<kw> (verified filtering), genres are opaque
//         ids under /genre/<id> (index at /genre). Episodes
//         /anime/<id>/<n> (the ?v= variant is a per-server alias; the
//         canonical no-query URL works — the watch page itself carries
//         the embed iframe). Watch -> iframe /embed?v=<vid> -> the
//         embed's <video> <source> ladder on filegasm: direct token'd
//         MP4s (s*.filegasm.com/<hash>?download_token=) labelled by
//         resolution; prefer the highest-labelled DIRECT file, with
//         the embed page as Referer. filegasm /watch/ page sources
//         are returned as embeds for the app's webview path. The final
//         file's true resolution is device-owed (the VM's fetch of a
//         token'd file was dropped by filegasm — inconclusive).
//   hh:   hentaihaven.co — the .xxx host is Cloudflare-challenged from
//         the VM; .co is the same network's mirror and serves openly.
//         The site is a Next.js app: list cards live in the escaped
//         RSC flight payload (\"className\":\"a_item\",\"href\":...),
//         40 cards/page, /?page=N up to 85. Genres /genre/<slug>/,
//         tags /tag/<slug>/. NO working server search (/?s= and
//         /search/?s= return the identical default listing — measured
//         with a nonsense query), and parseSearchResponse cannot see
//         the keyword, so hh is honestly OMITTED from search v1.
//         Watch /watch/<series>-episode-<n>/ -> iframe
//         nhplayer.com/v/<id>/ -> server <li data-id="/player.php?
//         vid=<b64>&s=<b64>&i=<b64>&type=">. v1 hands the player.php
//         URL to the app's sniffing WebView player (isEmbed), whose
//         real page runs its own proof-of-work and plays.
//         *** v2 hardening task: implement the PoW in-plugin (fetch
//         player.php + player-core-v2.php, harvest the five DOM
//         challenge parts, SHA-256 PoW, GET /get-video-url-v2.php)
//         to resolve the direct MP4 natively. ***
//   hanime.tv is EXCLUDED from v1 by the hunt's verdict: playback is
//   gated (WASM-signed handshake for <=720p, premium login for 1080p).
//
// Search fan-out: the app contract fetches ONE search URL per page
// (MovieService.search -> getUrlSearch(keyword, filters{page})), so
// true parallel fan-out is impossible in-contract. v1 rotates by
// page: odd pages serve hstream results, even pages serve haho
// results — each page block is one source's grouped results, item
// ids are source-prefixed, and one source failing yields an empty
// page without touching the other source's pages.
// =============================================================================

function getManifest() {
    return JSON.stringify({
        "id": "hentaihub",
        "name": "Hentai Hub",
        "version": "1.0.0",
        "baseUrl": "https://hstream.moe",
        "iconUrl": "https://hstream.moe/images/cropped-HS-1-270x270.webp",
        "isEnabled": true,
        "isAdult": true,
        "type": "MOVIE",
        "layoutType": "HORIZONTAL"
    });
}

function getHomeSections() {
    // One labelled rail per source, plus one big-genre rail each.
    return JSON.stringify([
        { slug: 'hs:latest', title: 'HStream — Mới nhất', type: 'Horizontal', path: '' },
        { slug: 'haho:latest', title: 'HAHO — Mới cập nhật', type: 'Horizontal', path: '' },
        { slug: 'hs:tag:uncensored', title: 'HStream — Uncensored', type: 'Horizontal', path: '' },
        { slug: 'hh:g:uncensored', title: 'HentaiHaven — Uncensored', type: 'Horizontal', path: '' },
        { slug: 'hh:latest', title: 'HentaiHaven — Mới nhất', type: 'Grid', path: '' }
    ]);
}

// Source-scoped categories. Slugs carry the adapter prefix; genre
// taxonomies genuinely differ per source, so nothing is merged.
var HS_TAGS = ['ahegao', 'big-boobs', 'bdsm', 'censored', 'creampie', 'elf', 'fantasy', 'maid', 'milf', 'mind-control', 'ntr', 'public-sex', 'rape', 'school-girl', 'succubus', 'tentacle', 'uncensored', 'virgin'];
// haho genre ids are opaque; pairs measured on haho.moe/genre (the
// index paginates alphabetically — these are the A-page entries plus
// the ones a user is most likely to want; the full set is reachable
// via parseCategoriesResponse on the same index).
var HAHO_GENRES = [
    ['fzbv2fbz', '3D CG animation'], ['zdwxopnb', 'action'], ['ukgtxrki', 'adventure'],
    ['5wqtovj0', 'ahegao'], ['t0xpmr7i', 'alien'], ['04mvuqdv', 'alien invasion'],
    ['iy6puzyi', 'all-girls school'], ['tcqzrpn8', 'age difference romance'],
    ['hl5ctn5a', 'absurdist humour'], ['ymlxgyrm', 'Akihabara'], ['f67vdqka', 'alcohol'],
    ['bc1dtix2', 'adults are useless'], ['bpgnzedz', 'amnesia']
];
var HH_GENRES = ['ahegao', 'anal', 'bdsm', 'big-boobs', 'blow-job', 'censored', 'cosplay', 'creampie', 'fantasy', 'futanari', 'gangbang', 'harem', 'incest', 'loli', 'maid', 'milf', 'mind-break', 'mind-control', 'monster', 'ntr', 'nurse', 'orgy', 'plot', 'pov', 'pregnant', 'public-sex', 'rape', 'school-girl', 'tentacle', 'threesome', 'uncensored', 'vanilla', 'virgin', 'yuri'];

function titleCaseSlug(slug) {
    return slug.split('-').map(function (w) {
        return w ? w.charAt(0).toUpperCase() + w.slice(1) : w;
    }).join(' ');
}

function getPrimaryCategories() {
    var cats = [{ name: 'Tất cả — HStream', slug: 'hs:latest' }, { name: 'Tất cả — HAHO', slug: 'haho:latest' }, { name: 'Tất cả — HentaiHaven', slug: 'hh:latest' }];
    HS_TAGS.forEach(function (t) { cats.push({ name: 'HS · ' + titleCaseSlug(t), slug: 'hs:tag:' + t }); });
    HAHO_GENRES.forEach(function (g) { cats.push({ name: 'HAHO · ' + g[1], slug: 'haho:g:' + g[0] }); });
    HH_GENRES.forEach(function (t) { cats.push({ name: 'HH · ' + titleCaseSlug(t), slug: 'hh:g:' + t }); });
    return JSON.stringify(cats);
}

function getFilterConfig() {
    var cats = [];
    HS_TAGS.forEach(function (t) { cats.push({ name: 'HS · ' + titleCaseSlug(t), value: 'hs:tag:' + t }); });
    HAHO_GENRES.forEach(function (g) { cats.push({ name: 'HAHO · ' + g[1], value: 'haho:g:' + g[0] }); });
    HH_GENRES.forEach(function (t) { cats.push({ name: 'HH · ' + titleCaseSlug(t), value: 'hh:g:' + t }); });
    return JSON.stringify({
        sort: [{ name: 'Mới nhất', value: 'latest' }],
        category: cats
    });
}

// =============================================================================
// URL GENERATION
// =============================================================================

var HS = "https://hstream.moe";
var HAHO = "https://haho.moe";
var HH = "https://hentaihaven.co";
var DESKTOP_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

function listUrlFor(slug, page) {
    if (!slug || slug === 'hs:latest') return HS + "/search?order=recently-released&page=" + page;
    if (slug.indexOf('hs:tag:') === 0) return HS + "/search?tags%5B0%5D=" + encodeURIComponent(slug.slice(7)) + "&page=" + page;
    if (slug === 'haho:latest') {
        // The series index for every page. (The homepage's episode
        // rail features only a handful of series, and haho's series
        // lists serve no poster images at all — measured; posters
        // come from each series' detail page.)
        return HAHO + "/anime?page=" + page;
    }
    if (slug.indexOf('haho:g:') === 0) return HAHO + "/genre/" + slug.slice(7) + (page > 1 ? "?page=" + page : "");
    if (slug === 'hh:latest') return HH + "/?page=" + page;
    if (slug.indexOf('hh:g:') === 0) return HH + "/genre/" + slug.slice(5) + "/?page=" + page;
    if (slug.indexOf('hh:tag:') === 0) return HH + "/tag/" + slug.slice(7) + "/?page=" + page;
    return HS + "/search?order=recently-released&page=" + page;
}

// Request stash for LIST pagination (round-2 list-pagination
// fix): getUrlList receives the requested page (filters.page),
// parseListResponse does not. The app serializes getUrlList ->
// fetch -> parseListResponse per plugin (the same pairing the
// search stash relies on), so parseListResponse may use this as
// the currentPage FALLBACK — a verified in-markup signal always
// wins over it (see listCurrentPage).
var _listStash = null;

function listSourceOf(slug) {
    if (!slug) return "hs";
    if (slug.indexOf("haho:") === 0) return "haho";
    if (slug.indexOf("hh:") === 0) return "hh";
    return "hs";
}

function getUrlList(slug, filtersJson) {
    var filters = JSON.parse(filtersJson || "{}");
    var page = filters.page || 1;
    var effective = filters.category ? filters.category : slug;
    _listStash = { source: listSourceOf(effective), slug: effective || "", page: parseInt(page) || 1 };
    return listUrlFor(effective, page);
}

// Routing stash for the search pagination translation (see
// getUrlSearch / parseSearchResponse). One entry, overwritten by
// every getUrlSearch call; read once by the matching parse.
var _searchStash = null;

// Per-source set of item ids already served in the current
// search — haho's end-of-results signal is re-serving its last
// page, which only a seen-set can detect (see parseSearchResponse).
var _searchSeen = { hs: {}, haho: {} };

function getUrlSearch(keyword, filtersJson) {
    var filters = JSON.parse(filtersJson || "{}");
    var page = filters.page || 1;
    // Page rotation fan-out (see header): odd pages = hstream,
    // even pages = haho. hh has no working server search (measured)
    // and parseSearchResponse cannot see the keyword, so hh is not
    // part of search v1.
    // Stash the routing for parseSearchResponse's pagination
    // translation (M-1 fix, review round 2): the engine's JSContext
    // persists per plugin instance, and the app fetches+parses one
    // search page at a time, so this pairing is reliable.
    _searchStash = { appPage: page, source: (page % 2 === 1) ? "hs" : "haho" };
    if (page % 2 === 1) {
        return HS + "/search?search=" + encodeURIComponent(keyword) + "&page=" + Math.ceil(page / 2);
    }
    return HAHO + "/anime?q=" + encodeURIComponent(keyword) + "&page=" + (page / 2);
}

function getUrlDetail(id) {
    if (!id) return "";
    if (id.indexOf("http") === 0) return id;
    if (id.indexOf("hs:") === 0) return HS + "/hentai/" + id.slice(3);
    if (id.indexOf("haho:") === 0) return HAHO + "/anime/" + id.slice(5);
    if (id.indexOf("hh:") === 0) return HH + "/watch/" + id.slice(3) + "/";
    return id;
}

function getUrlCategories() { return HAHO + "/genre"; }
function getUrlCountries() { return ""; }
function getUrlYears() { return ""; }

// =============================================================================
// UTILS
// =============================================================================

var PluginUtils = {
    cleanText: function (text) {
        if (!text) return "";
        return text.replace(/<[^>]*>/g, "")
            .replace(/&amp;/g, "&")
            .replace(/&quot;/g, '"')
            .replace(/&#039;/g, "'")
            .replace(/&#39;/g, "'")
            .replace(/&lt;/g, "<")
            .replace(/&gt;/g, ">")
            .replace(/\s+/g, " ")
            .trim();
    },
    decodeEntities: function (text) {
        if (!text) return "";
        return text.replace(/&amp;/g, "&")
            .replace(/&quot;/g, '"')
            .replace(/&#039;/g, "'")
            .replace(/&#39;/g, "'")
            .replace(/&lt;/g, "<")
            .replace(/&gt;/g, ">");
    },
    absolutize: function (url, base) {
        if (!url) return "";
        url = PluginUtils.decodeEntities(url);
        if (url.indexOf("http") === 0) return url;
        if (url.indexOf("//") === 0) return "https:" + url;
        if (url.charAt(0) === "/") return base + url;
        return base + "/" + url;
    },
    // Pagination heuristic shared by all three adapters: honour an
    // explicit "active page" marker when the markup carries one,
    // and take totalPages from the largest ?page= link on the page.
    pagination: function (html, itemCount) {
        var currentPage = 1;
        var active = html.match(/class="[^"]*(?:active|current)[^"]*"[^>]*>\s*(?:<a[^>]*>)?\s*(\d+)/i);
        if (active) currentPage = parseInt(active[1]);
        var totalPages = currentPage;
        var re = /[?&]page=(\d+)/g, m;
        while ((m = re.exec(html)) !== null) {
            var p = parseInt(m[1]);
            if (p > totalPages) totalPages = p;
        }
        if (totalPages === currentPage && itemCount >= 20) totalPages = currentPage + 1;
        return { currentPage: currentPage, totalPages: totalPages, totalItems: itemCount * totalPages, itemsPerPage: itemCount };
    },
    // In-markup current-page signals for LIST pages, per source
    // (round-2 list-pagination fix; both measured live 2026-11-18):
    // hs pages are Livewire — the component snapshot embeds its
    // paginator state as &quot;paginators&quot;:[{&quot;page&quot;:N
    // (N equalled the requested page on latest pages 1, 2, 3, 10,
    // 30 and on a tag page; the raw unescaped shape is matched as
    // a fallback). haho pages carry a Laravel pager whose current
    // page is a <span> inside <li class="page-item active"
    // aria-current="page">, NOT a link (N equalled the requested
    // page on pages 1, 2, 3, 59). The (active|current) marker
    // regex in pagination() above misfires on hs (reports 2 on
    // page 1 — it locks onto the page-2 pager button — then 1 on
    // later pages) and never matches haho's span at all; that is
    // what froze CategoryView's adopted page counter. Returns 0
    // when the source's signal is absent.
    markupCurrentPage: function (source, html) {
        if (!html) return 0;
        var m = null;
        if (source === "hs") {
            m = html.match(/paginators&quot;:\[\{&quot;page&quot;:(\d+)/) ||
                html.match(/"paginators":\[\{"page":(\d+)/);
        } else if (source === "haho") {
            m = html.match(/aria-current="page"[^>]*>\s*<span[^>]*>\s*(\d+)/i);
        }
        return m ? (parseInt(m[1]) || 0) : 0;
    }
};

// LIST currentPage resolution (round-2 fix): the app adopts the
// reported currentPage as its own page counter (CategoryView:
// page = result.pagination.currentPage after every fetch), so it
// must be the page that was actually served — a wrong value makes
// loadMore re-fetch the same page forever and truncates the
// catalogue. Priority: (1) the source's verified in-markup signal
// (PluginUtils.markupCurrentPage); (2) the getUrlList request
// stash, when its source matches the parsed page's source (the
// app serializes fetch->parse per plugin, so the pairing is
// reliable, and a mismatch simply ignores the stash); (3) the old
// marker result from PluginUtils.pagination — the documented
// floor when both signals are absent.
function listCurrentPage(source, html, markerPage) {
    var markup = PluginUtils.markupCurrentPage(source, html);
    if (markup > 0) return markup;
    if (_listStash && _listStash.source === source && _listStash.page > 0) return _listStash.page;
    return markerPage;
}

function sniffSource(html) {
    if (!html) return "";
    if (html.indexOf('"stream_url"') !== -1 || html.indexOf('id="e_id"') !== -1 || html.indexOf('hstream.moe/hentai/') !== -1) return "hs";
    if (html.indexOf('a_item') !== -1 && html.indexOf('/watch/') !== -1) return "hh";
    if (html.indexOf('hentaihaven') !== -1) return "hh";
    if (html.indexOf('nhplayer.com') !== -1) return "hh";
    if (html.indexOf('haho.moe') !== -1 || html.indexOf('filegasm') !== -1) return "haho";
    return "";
}

// =============================================================================
// HSTREAM (hs:) — list/search parser
// Cards: <div class="episode-item"> wrapping <a href="ABSOLUTE/hentai/
// <slug>"> with cover <img src="/images/hentai/<stem>/cover-ep-N.webp"
// alt="<Title> - <ep>">, a quality badge and an <h3> title.
// =============================================================================

function parseHsList(html) {
    var items = [];
    var seen = {};
    var re = /<a[^>]+href="https:\/\/hstream\.moe\/hentai\/([a-z0-9-]+)"[^>]*>([\s\S]*?)<\/a>/gi;
    var card;
    while ((card = re.exec(html)) !== null) {
        var slug = card[1];
        if (seen[slug]) continue;
        var block = card[2];
        var img = block.match(/<img[^>]+src="([^"]+)"/i);
        var poster = img ? PluginUtils.absolutize(img[1], HS) : "";
        var title = "";
        var h3 = block.match(/<h3[^>]*>([\s\S]*?)<\/h3>/i);
        if (h3) title = PluginUtils.cleanText(h3[1]);
        if (!title && img) {
            var alt = block.match(/<img[^>]+alt="([^"]*)"/i);
            if (alt) title = PluginUtils.cleanText(alt[1]);
        }
        if (!title) title = slug;
        var badge = block.match(/>([^<]*?(?:4K|FHD|HD|48fps)[^<]*?)</i);
        var quality = badge ? PluginUtils.cleanText(badge[1]) : "HD";
        var epNum = slug.match(/-(\d+)$/);
        seen[slug] = true;
        items.push({
            id: "hs:" + slug,
            title: title,
            posterUrl: poster,
            backdropUrl: poster,
            description: "",
            episode_current: epNum ? ("Episode " + epNum[1]) : "",
            quality: quality,
            lang: "Engsub"
        });
    }
    // Pagination (round-2 fix): currentPage from the verified
    // signal chain (see listCurrentPage). totalPages is a
    // LOOKAHEAD, mirroring the search design: hstream's markup
    // carries no page-count links at all and the catalogue runs
    // deep (full 25-item pages measured at least to p30; p100 is
    // empty), so a FULL page (25 items — the site's page size)
    // reports currentPage + 1, and the first partial or empty
    // page reports currentPage — exactly where the app stops.
    var base = PluginUtils.pagination(html, items.length);
    var cp = listCurrentPage("hs", html, base.currentPage);
    var totalPages = items.length >= 25 ? cp + 1 : cp;
    return { items: items, pagination: { currentPage: cp, totalPages: totalPages, totalItems: items.length * totalPages, itemsPerPage: items.length } };
}

// =============================================================================
// HAHO (haho:) — list/search parser
// Two card shapes:
//  A) episode rail cards (homepage / rails): <li class="video-N">
//     <a href=".../anime/<seriesId>/<n>?v=<vid>"> with cover <img>,
//     .anime-title (series) and .episode-title. Mapped to the SERIES.
//  B) series cards (/anime, /genre/<id>, search): <a href=".../anime/
//     <id>" title="<Title>" data-content="<desc>"> with .year etc.
//     These pages carry no poster images (measured) — posterUrl is
//     empty; the detail page supplies the real poster via og:image.
// =============================================================================

function parseHahoList(html) {
    var items = [];
    var seen = {};

    // Series cards are the page content — they win whenever present.
    var serRe = /<a[^>]+href="https:\/\/haho\.moe\/anime\/([a-z0-9]+)"([^>]*)>([\s\S]*?)<\/a>/gi;
    var card;
    while ((card = serRe.exec(html)) !== null) {
        var id2 = card[1];
        if (seen[id2]) continue;
        var attrs = card[2];
        var inner = card[3];
        var tMatch = attrs.match(/title="([^"]+)"/i);
        var title2 = tMatch ? PluginUtils.decodeEntities(tMatch[1]) : "";
        if (!title2) {
            var span = inner.match(/class="text-primary"[^>]*>([\s\S]*?)<\/span>/i);
            if (span) title2 = PluginUtils.cleanText(span[1]);
        }
        if (!title2) continue;
        var dMatch = attrs.match(/data-content="([^"]*)"/i);
        var yearMatch = inner.match(/class="year"[^>]*>([\s\S]*?)<\/div>/i);
        var year = yearMatch ? parseInt(PluginUtils.cleanText(yearMatch[1]).replace(/\D/g, "")) || 0 : 0;
        seen[id2] = true;
        items.push({
            id: "haho:" + id2,
            title: title2,
            posterUrl: "",
            backdropUrl: "",
            description: dMatch ? PluginUtils.decodeEntities(dMatch[1]).substring(0, 300) : "",
            year: year,
            quality: "HD",
            lang: "Engsub"
        });
    }

    // Fallback: episode rail cards (the only shape on pages without
    // series cards), mapped to their series.
    if (items.length === 0) {
        var railRe = /<a[^>]+href="https:\/\/haho\.moe\/anime\/([a-z0-9]+)\/\d+\?v=[a-z0-9]+"[^>]*>([\s\S]*?)<\/a>/gi;
        while ((card = railRe.exec(html)) !== null) {
            var sid = card[1];
            if (seen[sid]) continue;
            var block = card[2];
            var img = block.match(/<img[^>]+src="([^"]+)"/i);
            var series = block.match(/class="anime-title"[^>]*>([\s\S]*?)<\/div>/i);
            var ep = block.match(/class="episode-title"[^>]*>([\s\S]*?)<\/div>/i);
            var title = series ? PluginUtils.cleanText(series[1]) : "";
            if (!title) continue;
            seen[sid] = true;
            items.push({
                id: "haho:" + sid,
                title: title,
                posterUrl: img ? img[1] : "",
                backdropUrl: img ? img[1] : "",
                description: "",
                episode_current: ep ? PluginUtils.cleanText(ep[1]) : "",
                quality: "HD",
                lang: "Engsub"
            });
        }
    }

    // Pagination (round-2 fix): currentPage from the verified
    // signal chain (see listCurrentPage) — the old marker never
    // matched haho's span-shaped current page and reported 1 on
    // every page. totalPages stays LINK-DERIVED via the shared
    // helper (the pager links are real: max ?page= is 59 on
    // /anime and p59 serves the final 12 items — 58x24+12 =
    // 1,416 series), floored at the resolved currentPage.
    var base = PluginUtils.pagination(html, items.length);
    var cp = listCurrentPage("haho", html, base.currentPage);
    var totalPages = Math.max(base.totalPages, cp);
    return { items: items, pagination: { currentPage: cp, totalPages: totalPages, totalItems: items.length * totalPages, itemsPerPage: items.length } };
}

// =============================================================================
// HENTAIHAVEN (hh:) — list parser
// Next.js flight payload: cards are escaped JSON — unescape first,
// then each "a_item" chunk carries href /watch/<slug>/, the cover
// "src":"/uploads/...", an "EP N" badge and the video_title text.
// A plain-anchor fallback covers a WebView-rendered DOM variant.
// =============================================================================

function parseHhList(html) {
    var items = [];
    var seen = {};
    var u = html.replace(/\\"/g, '"').replace(/\\\//g, '/');
    var chunks = u.split('"className":"a_item"');
    for (var i = 1; i < chunks.length; i++) {
        var chunk = chunks[i].substring(0, 1600);
        var href = chunk.match(/"href":"(\/watch\/([a-z0-9-]+)\/)"/);
        if (!href) continue;
        var slug = href[2];
        if (seen[slug]) continue;
        var src = chunk.match(/"src":"([^"]+)"/);
        var titleM = chunk.match(/"className":"video_title"[^[]*"children":"([^"]+)"/) ||
            chunk.match(/"alt":"([^"]+)"/);
        var badge = chunk.match(/"className":"card_badge","children":"([^"]+)"/);
        var poster = src ? PluginUtils.absolutize(src[1], HH) : "";
        seen[slug] = true;
        items.push({
            id: "hh:" + slug,
            title: titleM ? PluginUtils.decodeEntities(titleM[1]) : slug,
            posterUrl: poster,
            backdropUrl: poster,
            description: "",
            episode_current: badge ? badge[1] : "",
            quality: "HD",
            lang: "Engsub"
        });
    }

    if (items.length === 0) {
        var re = /<a[^>]+href="(\/watch\/([a-z0-9-]+)\/)"[^>]*>([\s\S]*?)<\/a>/gi;
        var card;
        while ((card = re.exec(html)) !== null) {
            if (seen[card[2]]) continue;
            var img = card[3].match(/<img[^>]+src="([^"]+)"/i);
            var alt = card[3].match(/<img[^>]+alt="([^"]*)"/i);
            seen[card[2]] = true;
            items.push({
                id: "hh:" + card[2],
                title: alt ? PluginUtils.decodeEntities(alt[1]) : card[2],
                posterUrl: img ? PluginUtils.absolutize(img[1], HH) : "",
                backdropUrl: img ? PluginUtils.absolutize(img[1], HH) : "",
                description: "",
                episode_current: "",
                quality: "HD",
                lang: "Engsub"
            });
        }
    }

    // Pagination (round-2 M-1 fix): currentPage stays the shared
    // helper's marker value (verified exact on hh pages, 1..85).
    // totalPages must NOT keep the helper's +1 lookahead for hh:
    // this site's pager enumerates the true page range in real
    // ?page= links (max ?page= = 85 on latest, present on every
    // page), so the link-derived total is authoritative — and the
    // site CLAMPS out-of-range pages to the last page, so the
    // lookahead's cp+1 on the true last page (35 items on latest
    // p85, 32 on genre threesome p4 — both >= the helper's
    // 20-item threshold) re-served the last page verbatim, the
    // plugin re-reported cp=last / tp=last+1, and CategoryView
    // (which adopts the reported currentPage) looped on the
    // final page forever with 0 fresh items per fetch. Recompute
    // the total from the page links exactly as the helper does
    // before its lookahead, floored at cp — the same override
    // shape hs and haho already apply to the helper's total.
    var base = PluginUtils.pagination(html, items.length);
    var cp = base.currentPage;
    var totalPages = cp;
    var pageRe = /[?&]page=(\d+)/g, pm;
    while ((pm = pageRe.exec(html)) !== null) {
        var lp = parseInt(pm[1]);
        if (lp > totalPages) totalPages = lp;
    }
    return { items: items, pagination: { currentPage: cp, totalPages: totalPages, totalItems: items.length * totalPages, itemsPerPage: items.length } };
}

function parseListResponse(html) {
    try {
        var src = sniffSource(html);
        var result;
        if (src === "haho") result = parseHahoList(html);
        else if (src === "hh") result = parseHhList(html);
        else result = parseHsList(html);
        return JSON.stringify(result);
    } catch (e) {
        return JSON.stringify({ items: [], pagination: { currentPage: 1, totalPages: 1 } });
    }
}

function parseSearchResponse(html) {
    // One fetched page belongs to exactly one source (rotation in
    // getUrlSearch); the markup sniff routes it. hh never appears
    // here in v1 (no server search — see header).
    var raw = parseListResponse(html);
    // M-1 fix (review round 2, measured): the parsers report
    // pagination in SOURCE page units, but the app pages in
    // ROTATION units (its page 1 = hs 1, page 2 = haho 1, page 3 =
    // hs 2…) and stops at the largest totalPages ever reported —
    // untranslated totals silently capped deep searches at about
    // half the deeper source's depth (~74% of one measured result
    // set unreachable). The sources' own totals are also unreliable
    // in markup (haho search pages expose no page-count links at
    // all; hstream's active-page marker misfires), so the
    // translation does not trust them. Measured end-signals
    // differ per source: hstream ends on an EMPTY page; haho ends
    // by RE-SERVING its last page forever (page 5+ of one measured
    // search repeated page 4's 4 items verbatim). The only signal
    // that covers both: a page contributes only while it brings at
    // least one FRESH item id (tracked per source in _searchSeen,
    // reset on that source's first page of a search). Rule, in app
    // units: fresh items -> report appPage + 2 (this source fills
    // its next rotation slot too); empty or all-duplicate page ->
    // report appPage (this source is done) — EXCEPT on app page 1,
    // where a non-fresh page still reports 2 (M-2 fix): the app
    // fetches while page < the max reported totalPages, so a
    // "done" report of 1 on page 1 would close the search before
    // haho ever gets its first turn on page 2 (measured: a keyword
    // living only in haho returned an EMPTY search). The app's running max
    // then tracks the true combined depth, and paging stops once
    // both sources have answered done on consecutive turns.
    try {
        var obj = JSON.parse(raw);
        if (!obj || !obj.pagination) return raw;
        var src = sniffSource(html);
        var appPage = 0, srcKey = "";
        if (_searchStash && (src === "" || src === _searchStash.source)) {
            appPage = _searchStash.appPage;
            srcKey = _searchStash.source;
        } else if (src === "hs" || src === "haho") {
            // Stale/missing stash (overlapping searches): fall back
            // to the page's own reported position, best effort.
            var cp = obj.pagination.currentPage || 1;
            srcKey = src;
            appPage = (src === "hs") ? (2 * cp - 1) : (2 * cp);
        } else {
            return raw;
        }
        if (appPage <= 2) _searchSeen[srcKey] = {};
        var seen = _searchSeen[srcKey] || (_searchSeen[srcKey] = {});
        var fresh = 0, i, id;
        for (i = 0; i < obj.items.length; i++) {
            id = obj.items[i] && obj.items[i].id;
            if (id && !seen[id]) { seen[id] = 1; fresh++; }
        }
        obj.pagination.currentPage = appPage;
        obj.pagination.totalPages = fresh > 0 ? appPage + 2 : Math.max(appPage, 2);
        // totalItems (m-1 fix): the true count of items THIS
        // source has served so far in the current search — the
        // size of its _searchSeen set, just updated above with
        // this page's ids — not itemsPerPage (source units)
        // multiplied by totalPages (app units).
        obj.pagination.totalItems = Object.keys(seen).length;
        return JSON.stringify(obj);
    } catch (e) {
        return raw;
    }
}

// =============================================================================
// DETAIL (parseMovieDetail) — one adapter per source
// =============================================================================

function hsStem(slug) {
    var m = slug.match(/^(.*?)-\d+$/);
    return m ? m[1] : slug;
}

function parseHsDetail(html, url) {
    var slugM = (url || "").match(/\/hentai\/([a-z0-9-]+)/i);
    var slug = slugM ? slugM[1] : "";
    var title = "";
    var ogTitle = html.match(/property="og:title" content="([^"]+)"/i);
    if (ogTitle) {
        title = PluginUtils.decodeEntities(ogTitle[1])
            .replace(/\s*\|\s*hstream\.moe\s*$/i, "")
            .replace(/\s*-\s*English Subbed.*$/i, "")
            .trim();
    }
    if (!title) {
        var h1 = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
        if (h1) title = PluginUtils.cleanText(h1[1]);
    }
    var poster = "";
    var ogImg = html.match(/property="og:image" content="([^"]+)"/i);
    if (ogImg) poster = PluginUtils.absolutize(ogImg[1], HS);
    var desc = "";
    var descM = html.match(/name="description" content="([^"]*)"/i);
    if (descM) desc = PluginUtils.decodeEntities(descM[1]).substring(0, 700);

    // Tags: the page's own /search?tags[0]=<tag> links.
    var tags = [];
    var tagRe = /tags%5B0%5D=([a-z0-9-]+)/gi, tm;
    while ((tm = tagRe.exec(html)) !== null) {
        var t = tm[1];
        if (tags.indexOf(t) === -1 && !/^(4k|48fps|4k-48fps)$/.test(t)) tags.push(t);
    }

    // Episodes: sibling /hentai/<stem>-<n> links + this episode.
    var stem = hsStem(slug);
    var epMap = {};
    var epRe = new RegExp('href="https://hstream\\.moe/hentai/(' + stem.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '-(\\d+))"', 'gi');
    var em;
    while ((em = epRe.exec(html)) !== null) epMap[em[1]] = parseInt(em[2]);
    if (slug) {
        var selfNum = slug.match(/-(\d+)$/);
        epMap[slug] = selfNum ? parseInt(selfNum[1]) : 1;
    }
    var episodes = Object.keys(epMap).map(function (s) {
        return { id: HS + "/hentai/" + s, name: "Episode " + epMap[s], slug: s, num: epMap[s] };
    }).sort(function (a, b) { return a.num - b.num; });
    episodes.forEach(function (e) { delete e.num; });
    if (episodes.length === 0 && slug) {
        episodes = [{ id: HS + "/hentai/" + slug, name: "Episode 1", slug: slug }];
    }

    return {
        id: "hs:" + slug,
        title: title || slug,
        posterUrl: poster,
        backdropUrl: poster,
        description: desc,
        servers: [{ name: "HStream", episodes: episodes }],
        category: tags.map(titleCaseSlug).join(", "),
        quality: "HD",
        lang: "Engsub",
        status: ""
    };
}

function parseHahoDetail(html, url) {
    var idM = (url || "").match(/\/anime\/([a-z0-9]+)\/?(?:[?#]|$)/i) || (url || "").match(/\/anime\/([a-z0-9]+)/i);
    var sid = idM ? idM[1] : "";
    var title = "";
    var ogTitle = html.match(/property="og:title" content="([^"]+)"/i);
    if (ogTitle) title = PluginUtils.decodeEntities(ogTitle[1]).replace(/\s*—\s*Hentai AHO Streaming\s*$/i, "").trim();
    if (!title) {
        var h1 = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
        if (h1) title = PluginUtils.cleanText(h1[1]);
    }
    var poster = "";
    var ogImg = html.match(/property="og:image" content="([^"]+)"/i);
    if (ogImg) poster = ogImg[1];
    var desc = "";
    var descM = html.match(/property="og:description" content="([^"]*)"/i) || html.match(/name="description" content="([^"]*)"/i);
    if (descM) desc = PluginUtils.decodeEntities(descM[1]).substring(0, 700);

    // Genres: this page's /genre/<id> anchors carry title attributes.
    var genres = [];
    var gRe = /href="https:\/\/haho\.moe\/genre\/[a-z0-9]+"[^>]*title="([^"]+)"/gi, gm;
    while ((gm = gRe.exec(html)) !== null) {
        var gname = PluginUtils.decodeEntities(gm[1]);
        if (genres.indexOf(gname) === -1) genres.push(gname);
    }

    // Episodes: /anime/<id>/<n> links (with or without ?v=).
    var epMap = {};
    if (sid) {
        var epRe = new RegExp('href="https://haho\\.moe/anime/' + sid + '/(\\d+)', 'gi');
        var em;
        while ((em = epRe.exec(html)) !== null) epMap[em[1]] = parseInt(em[1]);
    }
    var episodes = Object.keys(epMap).map(function (n) {
        return { id: HAHO + "/anime/" + sid + "/" + n, name: "Episode " + n, slug: "ep-" + n, num: parseInt(n) };
    }).sort(function (a, b) { return a.num - b.num; });
    episodes.forEach(function (e) { delete e.num; });

    return {
        id: "haho:" + sid,
        title: title || sid,
        posterUrl: poster,
        backdropUrl: poster,
        description: desc,
        servers: [{ name: "HAHO", episodes: episodes }],
        category: genres.join(", "),
        quality: "HD",
        lang: "Engsub",
        status: ""
    };
}

function parseHhDetail(html, url) {
    var slugM = (url || "").match(/\/watch\/([a-z0-9-]+)\/?/i);
    var slug = slugM ? slugM[1] : "";
    var title = "";
    var ogTitle = html.match(/property="og:title" content="([^"]+)"/i);
    if (ogTitle) title = PluginUtils.decodeEntities(ogTitle[1]).replace(/\s*\|\s*Hentai Haven\s*$/i, "").trim();
    var poster = "";
    var ogImg = html.match(/property="og:image" content="([^"]+)"/i);
    if (ogImg) poster = PluginUtils.absolutize(ogImg[1], HH);
    var desc = "";
    var descM = html.match(/property="og:description" content="([^"]*)"/i);
    if (descM) {
        desc = PluginUtils.decodeEntities(descM[1]);
        if (/^Watch .* on Hentai Haven\./.test(desc)) desc = "";
        desc = desc.substring(0, 700);
    }

    // Episodes: same-stem /watch/<stem>-episode-<n>/ links. The page
    // is a Next.js payload, so unescape before scanning hrefs.
    var u = html.replace(/\\"/g, '"').replace(/\\\//g, '/');
    var stemM = slug.match(/^(.*?)-episode-\d+$/i);
    var stem = stemM ? stemM[1] : slug;
    var epMap = {};
    var epRe = new RegExp('href="(/watch/(' + stem.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '-episode-(\\d+))/?)"', 'gi');
    var em;
    while ((em = epRe.exec(u)) !== null) epMap[em[2]] = parseInt(em[3]);
    if (slug) {
        var selfNum = slug.match(/-episode-(\d+)$/i);
        epMap[slug] = selfNum ? parseInt(selfNum[1]) : 1;
    }
    var episodes = Object.keys(epMap).map(function (s) {
        return { id: HH + "/watch/" + s + "/", name: "Episode " + epMap[s], slug: s, num: epMap[s] };
    }).sort(function (a, b) { return a.num - b.num; });
    episodes.forEach(function (e) { delete e.num; });
    if (episodes.length === 0 && slug) {
        episodes = [{ id: HH + "/watch/" + slug + "/", name: "Episode 1", slug: slug }];
    }

    return {
        id: "hh:" + slug,
        title: title || slug,
        posterUrl: poster,
        backdropUrl: poster,
        description: desc,
        servers: [{ name: "HentaiHaven", episodes: episodes }],
        category: "",
        quality: "HD",
        lang: "Engsub",
        status: ""
    };
}

function parseMovieDetail(html, url) {
    try {
        var src = sniffSource(html);
        var detail;
        if (src === "haho" || (url || "").indexOf("haho.moe") !== -1) detail = parseHahoDetail(html, url);
        else if (src === "hh" || (url || "").indexOf("hentaihaven") !== -1) detail = parseHhDetail(html, url);
        else detail = parseHsDetail(html, url);
        return JSON.stringify(detail);
    } catch (e) {
        return "null";
    }
}

// =============================================================================
// STREAM RESOLUTION
// Resolver order in the app: parseEmbedResponse is tried FIRST on
// every hop, parseDetailResponse second. Both dispatch by content.
// =============================================================================

// hstream player/api JSON -> direct MP4 + subtitles (verified chain).
function hsStreamFromApi(text) {
    try {
        var data = JSON.parse(text);
        if (!data || !data.stream_url) return null;
        var domains = (data.stream_domains && data.stream_domains.length ? data.stream_domains : data.asia_stream_domains) || [];
        if (!domains.length) return null;
        var base = domains[0] + "/" + data.stream_url;
        return {
            url: base + "/x264.720p.mp4",
            isEmbed: false,
            headers: { "Referer": HS + "/", "User-Agent": DESKTOP_UA },
            subtitles: [
                { lang: "en", url: base + "/eng.vtt", label: "English" },
                { lang: "en", url: base + "/eng.ass", label: "English (ASS)" }
            ]
        };
    } catch (e) { return null; }
}

// hstream detail page -> POST config for /player/api. The session
// CSRF token is embedded in the page (Livewire data-csrf; a meta
// csrf-token is the fallback shape). Measured: the token works BOTH
// as the X-CSRF-TOKEN header and as _token in the JSON body (200);
// as X-XSRF-TOKEN it 419s — that header is reserved for the cookie
// value, which a plugin cannot read. The app's POST rides the shared
// cookie jar, so the session cookie is present either way.
function hsPostConfig(html, url) {
    var eid = html.match(/id="e_id"[^>]*value="(\d+)"/i) || html.match(/value="(\d+)"[^>]*id="e_id"/i);
    if (!eid) return null;
    var tok = html.match(/data-csrf="([^"]+)"/i) ||
        html.match(/<meta[^>]+name="csrf-token"[^>]+content="([^"]+)"/i) ||
        html.match(/<meta[^>]+content="([^"]+)"[^>]+name="csrf-token"/i);
    var token = tok ? tok[1] : "";
    var body = JSON.stringify({ episode_id: parseInt(eid[1]), _token: token });
    var headers = { "Content-Type": "application/json", "Referer": url || HS + "/" };
    if (token) headers["X-CSRF-TOKEN"] = token;
    return { url: HS + "/player/api", isEmbed: true, postBody: body, headers: headers };
}

// haho watch page -> the /embed?v=<vid> iframe hop.
function hahoEmbedHop(html) {
    var m = html.match(/<iframe[^>]+src="([^"]*\/embed\?v=[a-z0-9]+[^"]*)"/i) ||
        html.match(/(https:\/\/haho\.moe\/embed\?v=[a-z0-9]+)/i) ||
        html.match(/(\/embed\?v=[a-z0-9]+)/i);
    if (!m) return null;
    return { url: PluginUtils.absolutize(m[1], HAHO), isEmbed: true, headers: { "Referer": HAHO + "/" } };
}

// haho embed page -> the filegasm <source> ladder. Prefer the
// highest-labelled DIRECT token'd file; /watch/ host pages go back
// as embeds for the app's webview/sniffer path.
function hahoStreamFromEmbed(html, embedUrl) {
    var tags = html.match(/<source[^>]*>/gi) || [];
    var best = null, bestScore = -1, bestWatch = null, bestWatchScore = -1;
    for (var i = 0; i < tags.length; i++) {
        var tag = tags[i];
        var srcM = tag.match(/src="([^"]+)"/i);
        if (!srcM) continue;
        var src = PluginUtils.decodeEntities(srcM[1]);
        var labelM = tag.match(/title="(\d+)p?"/i);
        var score = labelM ? parseInt(labelM[1]) : 0;
        var isDirect = /filegasm\.com\/[a-z0-9]+\?download_token=/i.test(src) || /^https:\/\/s\d+\.filegasm\.com\//i.test(src);
        if (isDirect) {
            if (score > bestScore) { bestScore = score; best = src; }
        } else if (src.indexOf("filegasm.com/watch/") !== -1) {
            if (score > bestWatchScore) { bestWatchScore = score; bestWatch = src; }
        }
    }
    if (best) {
        return { url: best, isEmbed: false, headers: { "Referer": embedUrl || (HAHO + "/"), "User-Agent": DESKTOP_UA } };
    }
    if (bestWatch) {
        return { url: bestWatch, isEmbed: true, headers: { "Referer": embedUrl || (HAHO + "/") } };
    }
    return null;
}

// hh: watch page -> nhplayer embed; embed page -> player.php. v1
// hands player.php to the app's sniffing WebView player, whose real
// page executes the proof-of-work itself. (v2: implement the PoW
// in-plugin and resolve the direct MP4 — see header note.)
function hhEmbedHop(html, url) {
    var m = html.match(/(https:\/\/nhplayer\.com\/v\/[a-z0-9]+\/?)/i);
    if (m) return { url: m[1], isEmbed: true, headers: { "Referer": HH + "/" } };
    var p = html.match(/data-id="(\/player\.php\?[^"]+)"/i) || html.match(/(\/player\.php\?vid=[^"'\s]+)/i);
    if (p) return { url: "https://nhplayer.com" + PluginUtils.decodeEntities(p[1]), isEmbed: true, headers: { "Referer": url || "https://nhplayer.com/" } };
    if ((url || "").indexOf("nhplayer.com") !== -1) {
        // Embed page without a server entry: hand the page itself to
        // the webview player (self-embed in the resolver).
        return { url: url, isEmbed: true, headers: { "Referer": HH + "/" } };
    }
    return null;
}

function parseDetailResponse(html, url) {
    try {
        if (!html) return JSON.stringify({ url: "", isEmbed: false, headers: {} });
        if (html.indexOf('"stream_url"') !== -1) {
            var s = hsStreamFromApi(html);
            if (s) return JSON.stringify(s);
        }
        if (html.indexOf('id="e_id"') !== -1) {
            var cfg = hsPostConfig(html, url);
            if (cfg) return JSON.stringify(cfg);
        }
        var src = sniffSource(html);
        if (src === "haho" || (url || "").indexOf("haho.moe") !== -1) {
            var hop = hahoEmbedHop(html);
            if (hop) return JSON.stringify(hop);
            var st = hahoStreamFromEmbed(html, url);
            if (st) return JSON.stringify(st);
        }
        if (src === "hh" || (url || "").indexOf("hentaihaven") !== -1 || (url || "").indexOf("nhplayer") !== -1) {
            var hh = hhEmbedHop(html, url);
            if (hh) return JSON.stringify(hh);
        }
        return JSON.stringify({ url: "", isEmbed: false, headers: {} });
    } catch (e) {
        return JSON.stringify({ url: "", isEmbed: false, headers: {} });
    }
}

function parseEmbedResponse(html, url) {
    try {
        if (!html) return JSON.stringify({ url: "", isEmbed: false, headers: {} });
        if (html.indexOf('"stream_url"') !== -1) {
            var s = hsStreamFromApi(html);
            if (s) return JSON.stringify(s);
        }
        if (html.indexOf("filegasm") !== -1) {
            var st = hahoStreamFromEmbed(html, url);
            if (st) return JSON.stringify(st);
        }
        if (html.indexOf("nhplayer.com") !== -1 || html.indexOf("player.php?vid=") !== -1 || (url || "").indexOf("nhplayer") !== -1) {
            var hh = hhEmbedHop(html, url);
            if (hh) return JSON.stringify(hh);
        }
        if ((url || "").indexOf("haho.moe") !== -1 || html.indexOf("haho.moe") !== -1) {
            var hop = hahoEmbedHop(html);
            if (hop) return JSON.stringify(hop);
        }
        return JSON.stringify({ url: "", isEmbed: false, headers: {} });
    } catch (e) {
        return JSON.stringify({ url: "", isEmbed: false, headers: {} });
    }
}

function parseCategoriesResponse(html) {
    try {
        var cats = [];
        var seen = {};
        if (html.indexOf("haho.moe/genre/") !== -1) {
            var re = /href="https:\/\/haho\.moe\/genre\/([a-z0-9]+)"[^>]*title="([^"]+)"/gi, m;
            while ((m = re.exec(html)) !== null) {
                if (!seen[m[1]]) { seen[m[1]] = true; cats.push({ name: "HAHO · " + PluginUtils.decodeEntities(m[2]), slug: "haho:g:" + m[1] }); }
            }
        }
        return JSON.stringify(cats);
    } catch (e) { return "[]"; }
}

function parseCountriesResponse(html) { return "[]"; }
function parseYearsResponse(html) { return "[]"; }
