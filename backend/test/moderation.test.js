const test = require("node:test");
const assert = require("node:assert");
const fixture = require("./fixtures/moderation.json");
const { FIELDS, findTerms, isReservedHandle, check, blockedField, reviewStatus } = require("../services/moderation");

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
});

test("names are blocked and free text is flagged, each from its own severity", () => {
    const { low, medium, high } = fixture.policy;
    // @usernames are strictest
    assert.strictEqual(check("handle", low).action, "block");
    // Names everyone sees: strong words, not mild ones
    for (const field of ["display_name", "list_name", "list_description", "group_name"]) {
        assert.strictEqual(FIELDS[field].action, "block");
        assert.strictEqual(check(field, low).action, "ok", field);
        assert.strictEqual(check(field, medium).action, "block", field);
    }
    // Notes and messages: saved, and only slurs are flagged for review
    for (const field of ["note", "recommendation_note"]) {
        assert.strictEqual(check(field, medium).action, "ok", field);
        assert.strictEqual(check(field, high).action, "flag", field);
    }
    assert.deepStrictEqual(reviewStatus("note", `Great film, ${high}`), { status: "flagged", reason: "hate" });
    assert.deepStrictEqual(reviewStatus("note", "Rewatch with Sam"), { status: "ok" });
});

test("blockedField gives the first blocked field and skips ones left out", () => {
    assert.strictEqual(blockedField({ list_name: "Best of 2026", list_description: undefined }), null);
    assert.deepStrictEqual(blockedField({ list_name: "Best of 2026", list_description: fixture.policy.medium }),
        { error: FIELDS.list_description.message, field: "list_description" });
});
