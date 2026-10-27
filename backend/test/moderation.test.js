const test = require("node:test");
const assert = require("node:assert");
const fixture = require("./fixtures/moderation.json");
const terms = require("../moderation/terms.json");
const { FIELDS, THRESHOLDS, findTerms, isReservedHandle, check, blockedField, reviewStatus } = require("../services/moderation");

const words = (text) => findTerms(text).map((term) => term.word);

test("finds listed words, from obscenity's dataset and our own terms", () => {
    for (const { text, word } of fixture.matches) assert.ok(words(text).includes(word), `${text} -> ${word}`);
});

test("sees through leetspeak, repeated letters and letters split by spaces or punctuation", () => {
    for (const { text, word } of fixture.evasions) assert.ok(words(text).includes(word), `${text} -> ${word}`);
});

test("sees through look-alike letters", () => {
    for (const { text, word, about } of fixture.confusables) assert.ok(words(text).includes(word), about);
});

test("leaves alone words that only contain a listed word (Scunthorpe)", () => {
    for (const text of fixture.clean) assert.deepStrictEqual(words(text), [], text);
});

test("reserves @usernames like admin and marquee, with dots, underscores and numbers too", () => {
    for (const handle of fixture.reserved) assert.ok(isReservedHandle(handle), handle);
    for (const handle of fixture.notReserved) assert.ok(!isReservedHandle(handle), handle);
    assert.deepStrictEqual(blockedField({ handle: "admin" }), { error: "That username is reserved. Try another one.", field: "handle" });
});

test("reserved names only apply to @usernames", () => {
    for (const field of ["display_name", "list_name", "group_name"]) assert.strictEqual(check(field, "Support").action, "ok");
    assert.strictEqual(check("handle", "marquee_official").category, "reserved");
});

test("only slurs, hate and harassment are acted on, in every field", () => {
    for (const field of Object.keys(FIELDS)) assert.strictEqual(THRESHOLDS[field], "high", field);
    // Every word that's acted on is a slur, hate or harassment, never profanity or a sexual word
    for (const [word, info] of Object.entries({ ...terms.dataset, ...Object.fromEntries(terms.terms.map((term) => [term.word, term])) })) {
        if (info.severity === "high") assert.ok(["hate", "harassment"].includes(info.category), word);
    }
    assert.notStrictEqual(terms.datasetDefault.severity, "high");
});

test("profanity and sexual words are allowed in @usernames, names, notes and messages", () => {
    for (const text of fixture.policy.allowed) {
        assert.ok(findTerms(text).length, `${text} is still found`);
        for (const field of Object.keys(FIELDS)) assert.strictEqual(check(field, text).action, "ok", `${field}: ${text}`);
    }
    assert.strictEqual(blockedField({ handle: "shithead", display_name: "fuck mondays", list_name: "Bitchin' 80s" }), null);
});

test("slurs are blocked in names and flagged in notes and messages, evasions included", () => {
    for (const text of fixture.policy.slurs) {
        for (const field of ["handle", "display_name", "list_name", "list_description", "group_name"]) {
            assert.strictEqual(FIELDS[field].action, "block");
            assert.strictEqual(check(field, text).action, "block", `${field}: ${text}`);
        }
        for (const field of ["note", "recommendation_note"]) assert.strictEqual(check(field, text).action, "flag", `${field}: ${text}`);
    }
    assert.deepStrictEqual(reviewStatus("note", `Great film, ${fixture.policy.slur}`), { status: "flagged", reason: "hate" });
    assert.deepStrictEqual(reviewStatus("recommendation_note", "kys"), { status: "flagged", reason: "harassment" });
    assert.deepStrictEqual(reviewStatus("note", "Rewatch with Sam"), { status: "ok" });
});

test("blockedField gives the first blocked field and skips ones left out", () => {
    assert.strictEqual(blockedField({ list_name: "Best of 2026", list_description: undefined }), null);
    assert.deepStrictEqual(blockedField({ list_name: "Best of 2026", list_description: fixture.policy.slur }),
        { error: FIELDS.list_description.message, field: "list_description" });
});
