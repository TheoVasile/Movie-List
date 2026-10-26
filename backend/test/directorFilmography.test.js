const test = require("node:test");
const assert = require("node:assert");
const fixture = require("./fixtures/directorCredits.json");
const { directedFilms, directingCandidates, isFeature } = require("../services/directorFilmography");

// TMDb movie_credits and film lengths saved from the real API (trimmed), answered without the network
const runtimeOf = async (id) => fixture.runtimes[id] ?? null;
const directed = async (personId) => directedFilms(fixture.people[personId].credits, runtimeOf, { on: fixture.asOf });
const titles = (films) => films.map((film) => `${film.title} (${film.release_date.slice(0, 4)})`);

test("Taika Waititi's directed features include Boy and his other early films, oldest first", async () => {
    assert.deepStrictEqual(titles(await directed(55934)), [
        "Eagle vs Shark (2007)",
        "Boy (2010)",
        "What We Do in the Shadows (2014)",
        "Hunt for the Wilderpeople (2016)",
        "Thor: Ragnarok (2017)",
        "Jojo Rabbit (2019)",
        "Thor: Love and Thunder (2022)",
        "Next Goal Wins (2023)",
        "Klara and the Sun (2026)",
    ]);
});

test("Greta Gerwig's directed features include her co-directed debut and none of her acting or writing", async () => {
    assert.deepStrictEqual(titles(await directed(45400)), [
        "Nights and Weekends (2008)",
        "Lady Bird (2017)",
        "Little Women (2019)",
        "Barbie (2023)",
    ]);
});

test("Bong Joon-ho's directed features include Barking Dogs Never Bite, without his shorts", async () => {
    assert.deepStrictEqual(titles(await directed(21684)), [
        "Barking Dogs Never Bite (2000)",
        "Memories of Murder (2003)",
        "The Host (2006)",
        "Tokyo! (2008)",
        "Mother (2009)",
        "Snowpiercer (2013)",
        "Okja (2017)",
        "Parasite (2019)",
        "Mickey 17 (2025)",
    ]);
});

test("each film appears once, whatever other jobs the person had on it", async () => {
    const credits = {
        cast: [{ id: 1, title: "Boy", release_date: "2010-03-25", poster_path: "/b.jpg", vote_count: 500, character: "Alamein" }],
        crew: [
            { id: 1, title: "Boy", release_date: "2010-03-25", poster_path: "/b.jpg", vote_count: 500, job: "Writer", department: "Writing" },
            { id: 1, title: "Boy", release_date: "2010-03-25", poster_path: "/b.jpg", vote_count: 500, job: "Director", department: "Directing" },
            { id: 1, title: "Boy", release_date: "2010-03-25", poster_path: "/b.jpg", vote_count: 500, job: "Director", department: "Directing" },
            { id: 2, title: "Someone else's", release_date: "2011-01-01", poster_path: "/s.jpg", vote_count: 500, job: "Assistant Director", department: "Directing" },
            { id: 3, title: "Written only", release_date: "2012-01-01", poster_path: "/w.jpg", vote_count: 500, job: "Screenplay", department: "Writing" },
        ],
    };
    const films = await directedFilms(credits, async () => 90, { on: "2026-01-01" });
    assert.deepStrictEqual(films.map((film) => film.id), [1]);
});

test("unreleased, posterless and adult films are left out, and an unknown length falls back to votes", async () => {
    const film = (id, extra) => ({ id, title: `Film ${id}`, release_date: "2020-01-01", poster_path: "/p.jpg", vote_count: 100, job: "Director", ...extra });
    const credits = { crew: [
        film(1),
        film(2, { release_date: "2030-01-01" }),
        film(3, { release_date: "" }),
        film(4, { poster_path: null }),
        film(5, { adult: true }),
        film(6, { vote_count: 20 }), // unknown length, too few votes to count
        film(7, { vote_count: 60 }), // unknown length, enough votes
    ] };
    const runtimes = { 1: 95 };
    const films = await directedFilms(credits, async (id) => runtimes[id] ?? 0, { on: "2026-01-01" });
    assert.deepStrictEqual(films.map((f) => f.id), [1, 7]);
    assert.strictEqual(directingCandidates(credits, "2026-01-01").length, 3);
});

test("a failed length lookup doesn't fail the filmography", async () => {
    const credits = { crew: [{ id: 1, title: "Boy", release_date: "2010-03-25", poster_path: "/b.jpg", vote_count: 515, job: "Director" }] };
    const films = await directedFilms(credits, async () => { throw new Error("TMDb is down"); }, { on: "2026-01-01" });
    assert.deepStrictEqual(films.map((f) => f.id), [1]);
    assert.strictEqual(isFeature({ vote_count: 600 }, 3), false);
    assert.strictEqual(isFeature({ vote_count: 20 }, 88), true);
});
