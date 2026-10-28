const { shortDomain, appStoreID, appStoreURL } = require("../config/publicLinks");

// The public web pages people see when they open a shared Marquee link without the app: server-rendered,
// mobile-first and dark like the app, with no scripts. Every value from the database is escaped. Each page has
// Open Graph and Twitter tags for link previews, Apple's Smart App Banner (once APP_STORE_ID is set), an
// "Open in Marquee" button and a "Get the app" button

const POSTER = "https://image.tmdb.org/t/p/";

const escapeHTML = (value) =>
    String(value ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");

/// A TMDb poster at a size (w185, w342, w500), or null without one
const posterURL = (path, size = "w342") => (typeof path === "string" && /^\/[A-Za-z0-9_.-]+$/.test(path) ? `${POSTER}${size}${path}` : null);

const year = (date) => (typeof date === "string" && /^\d{4}/.test(date) ? date.slice(0, 4) : "");

/// Shortened to about max characters on a word boundary, for descriptions
function clip(text, max = 180) {
    const clean = String(text ?? "").replace(/\s+/g, " ").trim();
    if (clean.length <= max) return clean;
    return clean.slice(0, max).replace(/\s+\S*$/, "") + "…";
}

// The page's security headers: no scripts at all, images only from TMDb and this server
const CONTENT_SECURITY_POLICY = "default-src 'none'; img-src 'self' https://image.tmdb.org data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

const STYLE = `
:root{color-scheme:dark;--bg:#0a0a12;--surface:#1a1a24;--raised:#262633;--text:#f5f5f7;--muted:#a1a1b0;--faint:#6e6e7d;--gold:#fac245;--rose:#ed4a5c}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--text);font:16px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}
a{color:inherit}
.wrap{max-width:560px;margin:0 auto;padding:20px 16px 48px}
.brand{display:flex;align-items:center;gap:8px;font-weight:800;letter-spacing:.02em;text-decoration:none;margin-bottom:22px}
.brand i{width:26px;height:26px;border-radius:8px;background:linear-gradient(135deg,var(--gold),var(--rose));display:inline-block}
.eyebrow{font-size:12px;font-weight:800;letter-spacing:.14em;text-transform:uppercase;background:linear-gradient(90deg,var(--gold),var(--rose));-webkit-background-clip:text;background-clip:text;color:transparent}
h1{font-size:30px;line-height:1.15;margin:6px 0 6px;font-weight:850;letter-spacing:-.01em;overflow-wrap:anywhere}
.sub{color:var(--muted);margin:0 0 18px;overflow-wrap:anywhere}
.actions{display:flex;flex-direction:column;gap:10px;margin:22px 0 26px}
.btn{display:block;text-align:center;padding:14px 18px;border-radius:14px;font-weight:700;text-decoration:none}
.btn.primary{background:linear-gradient(90deg,var(--gold),var(--rose));color:#14141c}
.btn.secondary{background:var(--raised);color:var(--text);border:1px solid #33333f}
.films{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:10px}
.film{display:flex;align-items:center;gap:14px}
.rank{width:30px;text-align:center;font-weight:850;font-size:20px;color:var(--faint);font-variant-numeric:tabular-nums}
.film:nth-child(-n+3) .rank{color:var(--gold)}
.poster{width:46px;height:69px;border-radius:8px;background:var(--raised);object-fit:cover;flex:none}
.ftitle{font-weight:650;overflow-wrap:anywhere}
.fyear{font-size:13px;color:var(--muted)}
.more{color:var(--muted);font-size:14px;margin-top:14px}
.hero{display:flex;gap:18px;align-items:flex-start}
.hero img{width:132px;height:198px;border-radius:14px;object-fit:cover;background:var(--raised);flex:none;box-shadow:0 12px 40px rgba(0,0,0,.5)}
.overview{color:#d8d8e0}
.avatar{width:84px;height:84px;border-radius:50%;object-fit:cover;background:var(--raised);display:flex;align-items:center;justify-content:center;font-size:34px;font-weight:800;color:var(--muted)}
.counts{display:flex;gap:18px;color:var(--muted);font-size:14px;margin:4px 0 0}
.counts b{color:var(--text)}
.card{display:block;text-decoration:none;background:var(--surface);border:1px solid #24242f;border-radius:16px;padding:14px;margin-top:12px}
.card .posters{display:flex;gap:6px;margin-top:10px}
.card .posters img{width:25%;max-width:84px;aspect-ratio:2/3;border-radius:8px;object-fit:cover;background:var(--raised)}
.card .name{font-weight:750;overflow-wrap:anywhere}
.card .meta{font-size:13px;color:var(--muted)}
.footer{margin-top:40px;color:var(--faint);font-size:13px;text-align:center}
.footer a{color:var(--muted)}
.notfound{text-align:center;padding-top:40px}
`;

/// The whole page. meta: { title, description, image, url, appLink (marquee:// link the app opens), type }
function layout(meta, body) {
    const banner = appStoreID()
        ? `<meta name="apple-itunes-app" content="app-id=${escapeHTML(appStoreID())}${meta.url ? `, app-argument=${escapeHTML(meta.url)}` : ""}">`
        : "";
    const image = meta.image ? escapeHTML(meta.image) : "";
    const tags = [
        `<meta property="og:site_name" content="Marquee">`,
        `<meta property="og:type" content="${escapeHTML(meta.type || "website")}">`,
        `<meta property="og:title" content="${escapeHTML(meta.title)}">`,
        `<meta property="og:description" content="${escapeHTML(meta.description)}">`,
        meta.url ? `<meta property="og:url" content="${escapeHTML(meta.url)}">` : "",
        image ? `<meta property="og:image" content="${image}">` : "",
        `<meta name="twitter:card" content="${image ? "summary_large_image" : "summary"}">`,
        `<meta name="twitter:title" content="${escapeHTML(meta.title)}">`,
        `<meta name="twitter:description" content="${escapeHTML(meta.description)}">`,
        image ? `<meta name="twitter:image" content="${image}">` : "",
        meta.url ? `<link rel="canonical" href="${escapeHTML(meta.url)}">` : "",
    ].filter(Boolean).join("\n");
    const actions = meta.appLink
        ? `<div class="actions">
<a class="btn primary" href="${escapeHTML(meta.appLink)}">Open in Marquee</a>
<a class="btn secondary" href="${escapeHTML(appStoreURL())}">Get the app</a>
</div>`
        : "";
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0a0a12">
<title>${escapeHTML(meta.title)}</title>
<meta name="description" content="${escapeHTML(meta.description)}">
${meta.noindex ? `<meta name="robots" content="noindex">` : ""}
${banner}
${tags}
<style>${STYLE}</style>
</head>
<body>
<main class="wrap">
<div class="brand"><i></i>Marquee</div>
${body.replace("<!--actions-->", () => actions)}
<p class="footer">Rank every film you love on <a href="${escapeHTML(appStoreURL())}">Marquee</a> · ${escapeHTML(shortDomain())}<br><a href="/terms">Terms</a> · <a href="/privacy">Privacy</a></p>
</main>
</body>
</html>`;
}

const posterImg = (path, cls = "poster", size = "w185") => {
    const url = posterURL(path, size);
    return url ? `<img class="${cls}" src="${escapeHTML(url)}" alt="" loading="lazy">` : `<span class="${cls}"></span>`;
};

/// /l/<id>: a list's name, owner and top films
function listPage(list, url) {
    const ranked = list.is_ranked !== false;
    const films = list.films.map((film, index) => `<li class="film">
${ranked ? `<span class="rank">${escapeHTML(film.rank ?? index + 1)}</span>` : ""}
${posterImg(film.poster_path)}
<div><div class="ftitle">${escapeHTML(film.title)}</div>${year(film.release_date) ? `<div class="fyear">${escapeHTML(year(film.release_date))}</div>` : ""}</div>
</li>`).join("\n");
    const rest = list.film_count - list.films.length;
    const names = list.films.slice(0, 3).map((f) => f.title).join(", ");
    const description = list.overview
        ? clip(list.overview)
        : `${list.film_count} ${list.film_count === 1 ? "film" : "films"} by @${list.owner_handle}${names ? `: ${names}${list.film_count > 3 ? "…" : ""}` : ""}`;
    return layout({
        title: `${list.name} · @${list.owner_handle} on Marquee`,
        description,
        image: posterURL(list.films.find((f) => f.poster_path)?.poster_path, "w500"),
        url,
        appLink: `marquee://l/${list.public_id}`,
    }, `<div class="eyebrow">${ranked ? "Ranked list" : "List"}</div>
<h1>${escapeHTML(list.name)}</h1>
<p class="sub">by <a href="/u/${escapeHTML(encodeURIComponent(list.owner_handle))}">@${escapeHTML(list.owner_handle)}</a> · ${escapeHTML(list.film_count)} ${list.film_count === 1 ? "film" : "films"}</p>
${list.overview ? `<p class="overview">${escapeHTML(clip(list.overview, 400))}</p>` : ""}
<!--actions-->
<ol class="films">${films}</ol>
${rest > 0 ? `<p class="more">+ ${escapeHTML(rest)} more in the app</p>` : ""}`);
}

const initial = (name) => escapeHTML((String(name ?? "").trim()[0] ?? "?").toUpperCase());

/// /u/<handle>: a profile's name, picture, counts and a few public lists
function profilePage(profile, url, avatarURL) {
    const lists = profile.lists.map((list) => `<a class="card" href="/l/${escapeHTML(list.public_id)}">
<div class="name">${escapeHTML(list.name)}</div>
<div class="meta">${escapeHTML(list.film_count)} ${list.film_count === 1 ? "film" : "films"}</div>
${list.posters.length ? `<div class="posters">${list.posters.map((p) => posterImg(p, "", "w185")).join("")}</div>` : ""}
</a>`).join("\n");
    const firstPoster = profile.lists.flatMap((l) => l.posters)[0];
    return layout({
        title: `${profile.display_name} (@${profile.handle}) on Marquee`,
        description: `See @${profile.handle}'s film rankings and lists on Marquee.`,
        image: avatarURL || posterURL(firstPoster, "w500"),
        url,
        type: "profile",
        appLink: `marquee://u/${encodeURIComponent(profile.handle)}`,
    }, `<div class="hero" style="align-items:center">
${avatarURL ? `<img class="avatar" style="width:84px;height:84px;border-radius:50%;box-shadow:none" src="${escapeHTML(avatarURL)}" alt="">` : `<div class="avatar">${initial(profile.display_name)}</div>`}
<div>
<h1 style="font-size:26px;margin:0">@${escapeHTML(profile.handle)}</h1>
<div class="sub" style="margin:0">${escapeHTML(profile.display_name)}</div>
<div class="counts"><span><b>${escapeHTML(profile.followers)}</b> followers</span><span><b>${escapeHTML(profile.following)}</b> following</span><span><b>${escapeHTML(profile.list_count)}</b> lists</span></div>
</div>
</div>
<!--actions-->
${lists ? `<div class="eyebrow" style="margin-top:8px">Lists</div>${lists}` : `<p class="sub">No public lists yet.</p>`}`);
}

/// /f/<tmdb id>: a film's poster, title, year and overview
function filmPage(film, url) {
    const y = year(film.release_date);
    return layout({
        title: `${film.title}${y ? ` (${y})` : ""} · Marquee`,
        description: clip(film.overview) || `${film.title} on Marquee.`,
        image: posterURL(film.poster_path, "w500"),
        url,
        type: "video.movie",
        appLink: `marquee://f/${film.tmdb_id}`,
    }, `<div class="hero">
${posterImg(film.poster_path, "", "w342")}
<div>
<div class="eyebrow">${film.tmdb_id < 0 ? "Series" : "Film"}</div>
<h1>${escapeHTML(film.title)}</h1>
${y ? `<p class="sub">${escapeHTML(y)}</p>` : ""}
</div>
</div>
<!--actions-->
${film.overview ? `<p class="overview">${escapeHTML(film.overview)}</p>` : ""}`);
}

/// /join/group/<token>: a movie night group someone was invited to
function groupInvitePage(invite, url, token) {
    const from = invite.inviter_handle ? `@${invite.inviter_handle}` : "A friend";
    return layout({
        title: `Join ${invite.group_name} on Marquee`,
        description: `${from} invited you to their movie night group, ${invite.group_name} (${invite.member_count} ${invite.member_count === 1 ? "person" : "people"}).`,
        url,
        appLink: `marquee://join/group/${token}`,
        noindex: true,
    }, `<div class="eyebrow">Movie night invite</div>
<h1>${escapeHTML(invite.group_name)}</h1>
<p class="sub">${escapeHTML(from)} invited you · ${escapeHTML(invite.member_count)} ${invite.member_count === 1 ? "person" : "people"} in the group</p>
<p class="overview">Pick films together, vote on what to watch and plan your next movie night.</p>
<!--actions-->`);
}

/// /i/<handle>: someone invited a friend to Marquee
function personalInvitePage(person, url, avatarURL) {
    const name = person.is_private ? `@${person.handle}` : `${person.display_name} (@${person.handle})`;
    return layout({
        title: `Join @${person.handle} on Marquee`,
        description: `${name} invited you to Marquee: rank every film you love and see what your friends are watching.`,
        image: avatarURL,
        url,
        appLink: `marquee://u/${encodeURIComponent(person.handle)}`,
    }, `<div class="hero" style="align-items:center">
${avatarURL ? `<img class="avatar" style="width:84px;height:84px;border-radius:50%;box-shadow:none" src="${escapeHTML(avatarURL)}" alt="">` : `<div class="avatar">${initial(person.is_private ? person.handle : person.display_name)}</div>`}
<div>
<div class="eyebrow">You're invited</div>
<h1 style="font-size:26px;margin:2px 0 0">Join @${escapeHTML(person.handle)} on Marquee</h1>
</div>
</div>
<p class="overview" style="margin-top:16px">Rank every film you love, head to head, and see what your friends are watching.</p>
<!--actions-->`);
}

/// The page for a link that doesn't lead anywhere (or anywhere the visitor may see). Says nothing about why
function notFoundPage() {
    return layout({
        title: "Not found · Marquee",
        description: "This link doesn't lead anywhere on Marquee.",
        noindex: true,
    }, `<div class="notfound">
<h1>Nothing to see here</h1>
<p class="sub">This link may have expired, been turned off, or be private.</p>
<div class="actions"><a class="btn secondary" href="${escapeHTML(appStoreURL())}">Get the app</a></div>
</div>`);
}

module.exports = { escapeHTML, posterURL, CONTENT_SECURITY_POLICY, layout, listPage, profilePage, filmPage, groupInvitePage, personalInvitePage, notFoundPage };
