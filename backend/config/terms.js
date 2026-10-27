const fs = require("fs");
const path = require("path");

// The Terms of Service everyone has to accept. Bump the version when the Terms change materially, so everyone
// is asked to accept them again
const TERMS_VERSION = "2026-10-24";
const TERMS_UPDATED = "October 24, 2026";

// The Privacy Policy. Nobody accepts it, so its version is only for reference
const PRIVACY_VERSION = "2026-10-26";
const PRIVACY_UPDATED = "October 26, 2026";

// Filled into the Terms and Privacy Policy text; TERMS_COMPANY_NAME and TERMS_CONTACT_EMAIL override them
const COMPANY_NAME = "Blended Bits";
const CONTACT_EMAIL = "marquee.blendedbits@proton.me";

const cached = new Map();

// A document in legal/ as markdown, with the company name and contact email filled in. Read once, then kept
// in memory
function loadDocument(name) {
    if (!cached.has(name)) {
        const company = process.env.TERMS_COMPANY_NAME || COMPANY_NAME;
        const email = process.env.TERMS_CONTACT_EMAIL || CONTACT_EMAIL;
        cached.set(name, fs.readFileSync(path.join(__dirname, "..", "legal", `${name}.md`), "utf8")
            .replaceAll("{{COMPANY_NAME}}", company)
            .replaceAll("{{CONTACT_EMAIL}}", email));
    }
    return cached.get(name);
}

const loadTerms = () => loadDocument("terms");
const loadPrivacy = () => loadDocument("privacy");

const escapeHTML = (text) =>
    text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");

// Bold, italic and links within a line, on text that's already escaped. Only http(s) and mailto links are kept
function renderInline(text) {
    return text
        .replace(/\[([^\]]+)\]\(((?:https?:\/\/|mailto:)[^)\s]+)\)/g, '<a href="$2">$1</a>')
        .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
        .replace(/__(.+?)__/g, "<strong>$1</strong>")
        .replace(/(^|[^*])\*([^*\s][^*]*?)\*/g, "$1<em>$2</em>")
        .replace(/(^|[^\w])_([^_\s][^_]*?)_(?!\w)/g, "$1<em>$2</em>");
}

// Just enough markdown for the Terms and Privacy Policy: headings, paragraphs, bullet and numbered lists, bold, italic and links.
// Everything is escaped first, so the file can't add its own HTML
function renderMarkdown(markdown) {
    const html = [];
    let paragraph = [];
    let list = null;
    const endParagraph = () => {
        if (paragraph.length) html.push(`<p>${renderInline(paragraph.join(" "))}</p>`);
        paragraph = [];
    };
    const endList = () => {
        if (list) html.push(`<${list.tag}>${list.items.map((item) => `<li>${renderInline(item)}</li>`).join("")}</${list.tag}>`);
        list = null;
    };
    for (const line of escapeHTML(markdown).split(/\r?\n/)) {
        const heading = line.match(/^(#{1,6})\s+(.*)$/);
        const bullet = line.match(/^\s*[-*+]\s+(.*)$/);
        const numbered = line.match(/^\s*\d+[.)]\s+(.*)$/);
        if (!line.trim()) {
            endParagraph();
            endList();
        } else if (heading) {
            endParagraph();
            endList();
            const level = heading[1].length;
            html.push(`<h${level}>${renderInline(heading[2].replace(/\s+#+\s*$/, ""))}</h${level}>`);
        } else if (/^\s*(-{3,}|\*{3,}|_{3,})\s*$/.test(line)) {
            endParagraph();
            endList();
            html.push("<hr>");
        } else if (bullet || numbered) {
            endParagraph();
            const tag = bullet ? "ul" : "ol";
            if (list?.tag !== tag) endList();
            list ??= { tag, items: [] };
            list.items.push((bullet ?? numbered)[1]);
        } else if (list && /^\s+/.test(line)) {
            // An indented line carries on the list item above it
            list.items[list.items.length - 1] += ` ${line.trim()}`;
        } else {
            endList();
            paragraph.push(line.trim());
        }
    }
    endParagraph();
    endList();
    return html.join("\n");
}

// A legal document as a web page, for the App Store listing and the website
function documentPage(title, markdown, updated) {
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHTML(title)}</title>
<style>
    :root { color-scheme: light dark; }
    body { margin: 0; padding: 24px 16px 48px; font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #fff; color: #1c1c1e; }
    main { max-width: 720px; margin: 0 auto; }
    h1 { font-size: 1.8em; line-height: 1.2; }
    h2 { font-size: 1.3em; margin-top: 2em; }
    h3 { font-size: 1.1em; }
    a { color: #0a64d8; }
    .updated { color: #6e6e73; }
    ul, ol { padding-left: 1.4em; }
    li { margin: 0.3em 0; }
    hr { border: 0; border-top: 1px solid #d1d1d6; margin: 2em 0; }
    @media (prefers-color-scheme: dark) {
        body { background: #000; color: #f2f2f7; }
        a { color: #4da3ff; }
        .updated { color: #98989d; }
        hr { border-top-color: #38383a; }
    }
</style>
</head>
<body>
<main>
${renderMarkdown(markdown).replace("</h1>", `</h1>
<p class="updated">Last updated ${escapeHTML(updated)}</p>`)}
</main>
</body>
</html>`;
}

const termsPage = () => documentPage("Marquee Terms of Service", loadTerms(), TERMS_UPDATED);
const privacyPage = () => documentPage("Marquee Privacy Policy", loadPrivacy(), PRIVACY_UPDATED);

module.exports = {
    TERMS_VERSION, TERMS_UPDATED, PRIVACY_VERSION, PRIVACY_UPDATED,
    loadTerms, loadPrivacy, renderMarkdown, termsPage, privacyPage,
};
