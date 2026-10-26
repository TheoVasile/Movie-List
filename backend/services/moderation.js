const { DataSet, RegExpMatcher, englishDataset, englishRecommendedTransformers, parseRawPattern } = require("obscenity");
const terms = require("../moderation/terms.json");
const allowlist = require("../moderation/allowlist.json");

// Finds slurs and offensive words in text people write: names, @usernames, list names, notes and messages. Film
// titles, overviews and anything else from TMDb are never checked. The words are data (moderation/terms.json and
// moderation/allowlist.json), on top of the obscenity package's English list, which also sees through leetspeak
// (sh1t), look-alike letters, repeated letters and words hidden inside others (Scunthorpe)

const SEVERITIES = ["low", "medium", "high"];
const atLeast = (severity, minimum) => SEVERITIES.indexOf(severity) >= SEVERITIES.indexOf(minimum);

// What each kind of text does with a match at or above its severity. Names everyone sees are blocked on save,
// with a message the app shows by the field. Free text is saved but flagged: hidden from everyone but its author
// until someone reviews it. Only @usernames are checked against the reserved names
const FIELDS = {
    handle: { action: "block", severity: "low", reserved: true, message: "That username isn't allowed. Try another one." },
    display_name: { action: "block", severity: "medium", message: "That name isn't allowed. Try another one." },
    list_name: { action: "block", severity: "medium", message: "That list name isn't allowed. Try another one." },
    list_description: { action: "block", severity: "medium", message: "That description isn't allowed. Try rewording it." },
    group_name: { action: "block", severity: "medium", message: "That group name isn't allowed. Try another one." },
    note: { action: "flag", severity: "high" },
    recommendation_note: { action: "flag", severity: "high" },
};
const RESERVED_MESSAGE = "That username is reserved. Try another one.";

// The report reason a flagged category files under; anything else is "other"
const REPORT_REASONS = { hate: "hate", harassment: "harassment", sexual: "sexual" };

// The matcher for a set of terms and allowed phrases. Our own terms are added to obscenity's English dataset, and
// our allowed phrases to its own
function buildMatcher(extraTerms, allowed) {
    const dataset = new DataSet().addAll(englishDataset);
    for (const term of extraTerms) {
        dataset.addPhrase((phrase) => phrase.setMetadata({ originalWord: term.word }).addPattern(parseRawPattern(term.pattern)));
    }
    const built = dataset.build();
    const matcher = new RegExpMatcher({
        ...built,
        whitelistedTerms: [...built.whitelistedTerms, ...allowed.map((phrase) => phrase.toLowerCase())],
        ...englishRecommendedTransformers,
    });
    const ours = new Map(extraTerms.map((term) => [term.word, term]));
    // Each matched word's category and severity
    const describe = (word) => {
        const info = terms.dataset[word] ?? ours.get(word) ?? terms.datasetDefault;
        return { word, category: info.category, severity: info.severity };
    };
    return { dataset, matcher, describe };
}

let current = buildMatcher(terms.terms, allowlist.phrases);

/// Extension point for a future moderation_terms table, so terms can be added without a deploy: load its rows
/// (at startup and every few minutes, say) and pass them here, as [{ word, pattern, category, severity }] and
/// [allowed phrase]. They're used on top of the JSON files. Not built yet: the JSON files are the whole list
function addOverlay(extraTerms = [], allowed = []) {
    current = buildMatcher([...terms.terms, ...extraTerms], [...allowlist.phrases, ...allowed]);
}

// Accented and full-width letters as plain ones (ｆück -> fuck)
const plain = (text) => text.normalize("NFKD").replace(/\p{M}/gu, "");

// Three or more single letters split by spaces or punctuation ("f u c k", "f.u.c.k"), joined back into a word
const SPACED_LETTERS = /(?<![\p{L}\p{N}])[\p{L}\p{N}](?:[^\p{L}\p{N}\n]{1,3}[\p{L}\p{N}](?![\p{L}\p{N}])){2,}/gu;
const joinSpacedLetters = (text) => text.replace(SPACED_LETTERS, (run) => run.replace(/[^\p{L}\p{N}]/gu, ""));

/// Every listed word in the text, as [{ word, category, severity }], each once
function findTerms(text) {
    if (typeof text !== "string" || !text.trim()) return [];
    const cleaned = plain(text);
    const found = new Map();
    for (const variant of new Set([cleaned, joinSpacedLetters(cleaned)])) {
        for (const match of current.matcher.getAllMatches(variant)) {
            const word = current.dataset.getPayloadWithPhraseMetadata(match).phraseMetadata?.originalWord;
            if (word && !found.has(word)) found.set(word, current.describe(word));
        }
    }
    return [...found.values()];
}

const reserved = new Set(terms.reservedHandles);

/// Whether an @username is kept for us (admin, support, marquee...), ignoring dots, underscores and a number at
/// the end, so admin_1 and marquee.app count too
function isReservedHandle(handle) {
    const bare = String(handle).toLowerCase().replace(/[._]/g, "").replace(/\d+$/, "");
    return reserved.has(bare) || terms.reservedHandlePrefixes.some((prefix) => bare.startsWith(prefix));
}

/// What to do with text for a field in FIELDS: { action: "ok" } or { action: "block" | "flag", category, reason,
/// words, message }. reason is the report reason for a flag; message is what to show for a block
function check(field, text) {
    const policy = FIELDS[field];
    if (!policy) throw new Error(`No moderation policy for ${field}`);
    if (typeof text !== "string" || !text.trim()) return { action: "ok" };
    if (policy.reserved && isReservedHandle(text)) {
        return { action: "block", category: "reserved", reason: "impersonation", words: [], message: RESERVED_MESSAGE };
    }
    const hits = findTerms(text).filter((hit) => atLeast(hit.severity, policy.severity));
    if (!hits.length) return { action: "ok" };
    const worst = hits.reduce((a, b) => (SEVERITIES.indexOf(b.severity) > SEVERITIES.indexOf(a.severity) ? b : a));
    return {
        action: policy.action,
        category: worst.category,
        reason: REPORT_REASONS[worst.category] ?? "other",
        words: hits.map((hit) => hit.word),
        message: policy.message,
    };
}

/// For routes: the first of { field: text } that's blocked, as the 400 body { error, field }, or null when they're
/// all fine. Fields left undefined are skipped
function blockedField(fields) {
    for (const [field, text] of Object.entries(fields)) {
        const result = check(field, text);
        if (result.action === "block") return { error: result.message, field };
    }
    return null;
}

/// The moderation_status free text is saved with ("ok" or "flagged"), and the report reason when it's flagged
function reviewStatus(field, text) {
    const result = check(field, text);
    return result.action === "flag" ? { status: "flagged", reason: result.reason } : { status: "ok" };
}

module.exports = { FIELDS, findTerms, isReservedHandle, check, blockedField, reviewStatus, addOverlay };
