const test = require("node:test");
const assert = require("node:assert");
const express = require("express");
const { createPublicRouter, canShowList, canShowProfile } = require("../routes/publicRoutes");

// The public pages with a stand-in for the database, served on a random port
const PUBLIC_ID = "3f2b8c1e-0a4d-4c55-9e7b-2f1a6b9c0d11";
const PRIVATE_ID = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d";
const FOLLOWERS_ID = "11111111-2222-4333-8444-555555555555";
const PRIVATE_OWNER_ID = "66666666-7777-4888-9999-000000000000";

const list = (publicId, extra = {}) => ({
    public_id: publicId, name: "Best of <2026>", overview: "", visibility: "public", is_ranked: true,
    owner_handle: "sam", owner_name: "Sam", owner_private: false, film_count: 2,
    films: [
        { tmdb_id: "603", title: "The Matrix", release_date: "1999-03-31", poster_path: "/matrix.jpg", rank: 1 },
        { tmdb_id: "550", title: "Fight Club", release_date: "1999-10-15", poster_path: "/fc.jpg", rank: 2 },
    ],
    ...extra,
});

// Like the real model, except it hands back rows the SQL would have left out, so the route's own check is tested too
const data = {
    async publicList(id) {
        return {
            [PUBLIC_ID]: list(PUBLIC_ID),
            [PRIVATE_ID]: list(PRIVATE_ID, { visibility: "private", name: "Secret list" }),
            [FOLLOWERS_ID]: list(FOLLOWERS_ID, { visibility: "followers", name: "Friends only" }),
            [PRIVATE_OWNER_ID]: list(PRIVATE_OWNER_ID, { owner_private: true, name: "Private owner" }),
        }[id] ?? null;
    },
    async publicProfile(handle) {
        const base = { display_name: "Sam Lee", has_avatar: false, avatar_version: null, followers: 4, following: 2, list_count: 1,
            lists: [{ public_id: PUBLIC_ID, name: "Best of 2026", film_count: 2, posters: ["/matrix.jpg"] }] };
        if (handle === "sam") return { handle: "sam", is_private: false, ...base };
        if (handle === "hidden") return { handle: "hidden", is_private: true, ...base, display_name: "Hidden Person", email: "hidden@example.com" };
        return null;
    },
    async publicAvatar() { return null; },
    async publicFilm(id) {
        return id === "603" ? { tmdb_id: 603, title: "The Matrix", release_date: "1999-03-31", overview: "A hacker learns the truth.", poster_path: "/matrix.jpg" } : null;
    },
    async invitingUser(handle) {
        if (handle === "sam") return { handle: "sam", display_name: "Sam Lee", is_private: false };
        if (handle === "hidden") return { handle: "hidden", display_name: "Hidden Person", is_private: true };
        return null;
    },
    async groupInvite(token) {
        return token === "goodtoken_goodtoken_goodtoken_00" ? { group_id: 1, group_name: "Friday crew", member_count: 3, inviter_handle: "sam" } : null;
    },
};

async function withServer(run) {
    const app = express();
    app.use(createPublicRouter(data, { limiter: (req, res, next) => next() }));
    // Anything behind a sign-in, to check the public routes never reach it
    app.use("/users", (req, res) => res.status(401).json({ error: "Unauthorized" }));
    const server = app.listen(0);
    await new Promise((resolve) => server.once("listening", resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    try {
        await run((path) => fetch(base + path, { redirect: "manual" }));
    } finally {
        server.close();
    }
}

test("a public list shows its name, owner, films and link preview tags, escaped", async () => {
    await withServer(async (get) => {
        const res = await get(`/l/${PUBLIC_ID}`);
        assert.strictEqual(res.status, 200);
        assert.match(res.headers.get("content-type"), /text\/html/);
        const html = await res.text();
        assert.ok(html.includes("Best of &lt;2026&gt;"));
        assert.ok(!html.includes("Best of <2026>"));
        assert.ok(html.includes("@sam"));
        assert.ok(html.includes("The Matrix") && html.includes("Fight Club"));
        assert.match(html, /<meta property="og:title" content="[^"]+">/);
        assert.match(html, /<meta property="og:description" content="[^"]+">/);
        assert.match(html, /<meta property="og:image" content="https:\/\/image\.tmdb\.org\/t\/p\/w500\/matrix\.jpg">/);
        assert.match(html, /<meta name="twitter:card" content="summary_large_image">/);
        assert.ok(html.includes("Open in Marquee") && html.includes("Get the app"));
        assert.ok(html.includes(`marquee://l/${PUBLIC_ID}`));
        assert.ok(!/<script/i.test(html));
        assert.match(res.headers.get("content-security-policy"), /default-src 'none'/);
    });
});

test("private, followers-only and private-profile lists are a plain 404 that gives nothing away", async () => {
    await withServer(async (get) => {
        for (const [id, name] of [[PRIVATE_ID, "Secret list"], [FOLLOWERS_ID, "Friends only"], [PRIVATE_OWNER_ID, "Private owner"], ["not-a-uuid", ""], ["00000000-0000-4000-8000-000000000000", ""]]) {
            const res = await get(`/l/${id}`);
            assert.strictEqual(res.status, 404, id);
            const html = await res.text();
            if (name) assert.ok(!html.includes(name), name);
            assert.ok(!html.includes("@sam"));
            assert.ok(!html.includes("The Matrix"));
            assert.strictEqual(res.headers.get("cache-control"), "no-store");
        }
    });
});

test("a public profile shows; a private one is a 404 without its name or email", async () => {
    await withServer(async (get) => {
        const shown = await get("/u/sam");
        assert.strictEqual(shown.status, 200);
        const html = await shown.text();
        assert.ok(html.includes("@sam") && html.includes("Sam Lee") && html.includes("Best of 2026"));
        assert.ok(html.includes(`/l/${PUBLIC_ID}`));

        const hidden = await get("/u/hidden");
        assert.strictEqual(hidden.status, 404);
        const page = await hidden.text();
        assert.ok(!page.includes("Hidden Person") && !page.includes("hidden@example.com"));

        assert.strictEqual((await get("/u/nobody")).status, 404);
    });
});

test("films, invites and personal invites", async () => {
    await withServer(async (get) => {
        const film = await get("/f/603");
        assert.strictEqual(film.status, 200);
        const filmHTML = await film.text();
        assert.ok(filmHTML.includes("The Matrix") && filmHTML.includes("1999") && filmHTML.includes("A hacker learns the truth."));
        assert.strictEqual((await get("/f/999999")).status, 404);

        const invite = await get("/join/group/goodtoken_goodtoken_goodtoken_00");
        assert.strictEqual(invite.status, 200);
        const inviteHTML = await invite.text();
        assert.ok(inviteHTML.includes("Friday crew") && inviteHTML.includes("@sam"));
        assert.ok(inviteHTML.includes("marquee://join/group/goodtoken_goodtoken_goodtoken_00"));
        assert.strictEqual((await get("/join/group/expiredtoken_expiredtoken_00000")).status, 404);

        const personal = await get("/i/sam");
        assert.strictEqual(personal.status, 200);
        assert.ok((await personal.text()).includes("Join @sam on Marquee"));
        // A private profile's invite shows only the @handle
        const privateInvite = await get("/i/hidden");
        assert.strictEqual(privateInvite.status, 200);
        assert.ok(!(await privateInvite.text()).includes("Hidden Person"));
        assert.strictEqual((await get("/i/nobody")).status, 404);
    });
});

test("apple-app-site-association is JSON at both locations, with no redirect", async () => {
    await withServer(async (get) => {
        for (const path of ["/.well-known/apple-app-site-association", "/apple-app-site-association"]) {
            const res = await get(path);
            assert.strictEqual(res.status, 200, path);
            assert.match(res.headers.get("content-type"), /^application\/json/);
            const body = await res.json();
            const details = body.applinks.details[0];
            assert.deepStrictEqual(details.appIDs, ["MQB3MHVNQQ.Theodor-Vasile.Movie-List"]);
            assert.strictEqual(details.appID, "MQB3MHVNQQ.Theodor-Vasile.Movie-List");
            for (const p of ["/l/*", "/u/*", "/f/*", "/i/*", "/join/*"]) {
                assert.ok(details.paths.includes(p), p);
                assert.ok(details.components.some((c) => c["/"] === p), p);
            }
        }
    });
});

test("public routes need no sign-in and don't open signed-in ones", async () => {
    await withServer(async (get) => {
        assert.strictEqual((await get(`/l/${PUBLIC_ID}`)).status, 200);
        assert.strictEqual((await get("/users/me")).status, 401);
    });
});

test("the privacy checks themselves", () => {
    assert.ok(canShowList(list(PUBLIC_ID)));
    assert.ok(!canShowList(list(PRIVATE_ID, { visibility: "private" })));
    assert.ok(!canShowList(list(PRIVATE_ID, { visibility: "followers" })));
    assert.ok(!canShowList(list(PRIVATE_ID, { owner_private: true })));
    assert.ok(!canShowList(list(PRIVATE_ID, { owner_private: undefined })));
    assert.ok(!canShowList(null));
    assert.ok(canShowProfile({ handle: "sam", is_private: false }));
    assert.ok(!canShowProfile({ handle: "sam", is_private: true }));
    assert.ok(!canShowProfile({ handle: "sam" }));
    assert.ok(!canShowProfile(null));
});

test("the public address comes from PUBLIC_BASE_URL", () => {
    const { publicBaseURL, links, shortDomain } = require("../config/publicLinks");
    const before = process.env.PUBLIC_BASE_URL;
    try {
        delete process.env.PUBLIC_BASE_URL;
        assert.strictEqual(publicBaseURL(), "https://movie-list-backend-dgct.onrender.com");
        process.env.PUBLIC_BASE_URL = "https://onmarquee.app/";
        assert.strictEqual(links.list(PUBLIC_ID), `https://onmarquee.app/l/${PUBLIC_ID}`);
        assert.strictEqual(shortDomain(), "onmarquee.app");
    } finally {
        if (before === undefined) delete process.env.PUBLIC_BASE_URL;
        else process.env.PUBLIC_BASE_URL = before;
    }
});
