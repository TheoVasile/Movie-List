const test = require("node:test");
const assert = require("node:assert");
const { mergeReactedFilms, describeRequest, describePlacementReactions, SYSTEM_PROMPT, PLACEMENT_PROMPT } = require("../services/aiDiscoverService");

const film = (title, year = "2000") => ({ title, year });

test("AI Picks knows likes and dislikes from swipes, and nothing about skips", () => {
    assert.doesNotMatch(SYSTEM_PROMPT, /skip/i);
    assert.match(SYSTEM_PROMPT, /rankings outweigh their likes/);
    assert.match(SYSTEM_PROMPT, /Adding a film to a list is separate/);
    const text = describeRequest({ liked: [film("A")], disliked: [film("B")], passed: [film("Passed film")], favoriteGenres: [], avoidedGenres: [], alreadySuggested: [] }, 10);
    assert.doesNotMatch(text, /skip|Passed film/i);
    assert.match(text, /A \(2000\)[\s\S]*B \(2000\)/);
});

test("the server's reactions win over the app's, leave out ranked films and are capped", () => {
    const lists = [
        { name: "Favourites", ranked: true, films: [film("Ranked")] },
        { name: "Watchlist", ranked: true, films: [film("Want to see")] },
        { name: "Pile", ranked: false, films: [film("Collected")] },
    ];
    const reacted = { liked: [film("Ranked"), film("Want to see"), film("Collected")], disliked: [film("Changed my mind"), { title: null, year: "" }] };
    const sent = { liked: [film("changed my mind"), film("Only on this phone")], disliked: [film("Ranked")] };
    assert.deepStrictEqual(mergeReactedFilms(sent, reacted, lists, 120), {
        liked: [film("Want to see"), film("Collected"), film("Only on this phone")],
        disliked: [film("Changed my mind")],
    });
    const many = Array.from({ length: 300 }, (_, i) => film(`Film ${i}`));
    const capped = mergeReactedFilms({ liked: many, disliked: [] }, { liked: many.slice(100), disliked: [] }, [], 120);
    assert.strictEqual(capped.liked.length, 120);
    assert.strictEqual(capped.liked[0].title, "Film 100");
});

test("Smart Placement hears about a few similar reactions, as weak hints", () => {
    assert.match(PLACEMENT_PROMPT, /weak hints/);
    assert.strictEqual(describePlacementReactions({}), "");
    const text = describePlacementReactions({ own: "dislike", liked: Array.from({ length: 12 }, (_, i) => film(`L${i}`)), disliked: [film("D")] });
    assert.match(text, /marked this film not for me/);
    assert.match(text, /L7 \(2000\)/);
    assert.doesNotMatch(text, /L8 /);
    assert.match(text, /not for me: D \(2000\)/);
});
