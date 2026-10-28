const test = require("node:test");
const assert = require("node:assert");
const express = require("express");
const { createInviteService, inviteState, newToken, isToken } = require("../models/inviteModel");
const { createInviteRouters } = require("../routes/inviteRoutes");

// Group 1 is owned by "owner" with "member" in it; "outsider" isn't in it; "blocker" blocked "owner"
function memoryStore() {
    const groups = new Map([[1, { id: 1, name: "Friday crew", owner_id: "owner", members: new Set(["member"]) }]]);
    const invites = new Map();
    const blocks = new Set(["blocker>owner"]);
    const handles = { owner: "olive", member: "max", outsider: "otto", blocker: "bo" };
    return {
        groups, invites,
        async isMember(g, u) { const group = groups.get(g); return Boolean(group && (group.owner_id === u || group.members.has(u))); },
        async activeInvite(g, now) { return [...invites.values()].find((i) => i.group_id === g && inviteState(i, now) === "ok") ?? null; },
        async insertInvite(invite) { invites.set(invite.token, { ...invite }); return invites.get(invite.token); },
        async revokeInvite(g, token) { const i = invites.get(token); if (!i || i.group_id !== g) return false; i.revoked = true; return true; },
        async findInvite(token) { return invites.get(token) ?? null; },
        async groupSummary(g) { const group = groups.get(g); return group && { id: g, name: group.name, owner_id: group.owner_id, member_count: 1 + group.members.size }; },
        async handleOf(u) { return handles[u] ?? null; },
        async blockedEitherWay(a, b) { return blocks.has(`${a}>${b}`) || blocks.has(`${b}>${a}`); },
        async useInvite(token, now) { const i = invites.get(token); if (!i || inviteState(i, now) !== "ok") return null; i.uses++; return i; },
        async addMember(g, u) { const group = groups.get(g); if (group.members.has(u)) return false; group.members.add(u); return true; },
        async removeUse(token) { invites.get(token).uses--; },
    };
}

// The invite routes on a random port, signed in as whoever the x-user header says
async function withServer(run, { now } = {}) {
    const store = memoryStore();
    const invites = createInviteService(store, { maxMembers: 7, now });
    const joined = [];
    const routers = createInviteRouters({ invites, notifyJoined: async (uid, result) => joined.push([uid, result.inviter_id, result.group_name]) });
    const app = express();
    app.use(express.json());
    const auth = (req, res, next) => (req.get("x-user") ? ((req.user = { uid: req.get("x-user") }), next()) : res.status(401).json({ error: "Unauthorized" }));
    app.use("/groups", auth, routers.groups);
    app.use("/invites", auth, routers.invites);
    const server = app.listen(0);
    await new Promise((resolve) => server.once("listening", resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    const call = async (method, path, user) => {
        const res = await fetch(base + path, { method, headers: user ? { "x-user": user } : {} });
        return { status: res.status, body: await res.json().catch(() => null) };
    };
    try {
        await run(call, { store, joined });
    } finally {
        server.close();
    }
}

test("tokens are long, random and URL-safe", () => {
    const tokens = new Set(Array.from({ length: 50 }, newToken));
    assert.strictEqual(tokens.size, 50);
    for (const token of tokens) {
        assert.match(token, /^[A-Za-z0-9_-]{32}$/); // 24 bytes = 192 bits
        assert.ok(isToken(token));
    }
    assert.ok(!isToken("short"));
    assert.ok(!isToken("../../etc/passwd/../../etc/passwd/.."));
});

test("a member makes a link, which is reused until it stops working", async () => {
    await withServer(async (call) => {
        const first = await call("POST", "/groups/1/invites", "member");
        assert.strictEqual(first.status, 201);
        assert.ok(isToken(first.body.token));
        assert.ok(first.body.url.endsWith(`/join/group/${first.body.token}`));
        const days = (new Date(first.body.expires_at) - Date.now()) / 86400000;
        assert.ok(days > 29.9 && days <= 30, `expires in ${days} days`);
        const again = await call("POST", "/groups/1/invites", "owner");
        assert.strictEqual(again.body.token, first.body.token);
    });
});

test("someone outside the group can't make a link", async () => {
    await withServer(async (call) => {
        assert.strictEqual((await call("POST", "/groups/1/invites", "outsider")).status, 403);
        assert.strictEqual((await call("POST", "/groups/99/invites", "owner")).status, 403);
        assert.strictEqual((await call("POST", "/groups/1/invites")).status, 401);
    });
});

test("preview and accept join the group once, and tell whoever made the link", async () => {
    await withServer(async (call, { store, joined }) => {
        const { token } = (await call("POST", "/groups/1/invites", "owner")).body;
        const preview = await call("GET", `/invites/${token}`, "outsider");
        assert.strictEqual(preview.status, 200);
        assert.deepStrictEqual([preview.body.group_name, preview.body.member_count, preview.body.inviter_handle], ["Friday crew", 2, "olive"]);

        const accepted = await call("POST", `/invites/${token}/accept`, "outsider");
        assert.strictEqual(accepted.status, 200);
        assert.deepStrictEqual([accepted.body.joined, accepted.body.group_id], [true, 1]);
        assert.ok(store.groups.get(1).members.has("outsider"));
        assert.deepStrictEqual(joined, [["outsider", "owner", "Friday crew"]]);

        // Again: nothing changes, still a success
        const again = await call("POST", `/invites/${token}/accept`, "outsider");
        assert.strictEqual(again.status, 200);
        assert.deepStrictEqual([again.body.joined, again.body.already_member], [false, true]);
        assert.strictEqual(store.invites.get(token).uses, 1);
        assert.strictEqual(joined.length, 1);
    });
});

test("an expired link doesn't work", async () => {
    let clock = new Date("2026-01-01T00:00:00Z");
    await withServer(async (call) => {
        const { token } = (await call("POST", "/groups/1/invites", "owner")).body;
        assert.strictEqual((await call("GET", `/invites/${token}`, "outsider")).status, 200);
        clock = new Date("2026-02-01T00:00:00Z"); // 31 days later
        assert.strictEqual((await call("GET", `/invites/${token}`, "outsider")).status, 404);
        assert.strictEqual((await call("POST", `/invites/${token}/accept`, "outsider")).status, 404);
        // A fresh link is made in its place
        const fresh = await call("POST", "/groups/1/invites", "owner");
        assert.notStrictEqual(fresh.body.token, token);
    }, { now: () => clock });
});

test("a revoked link doesn't work, and only people in the group can revoke", async () => {
    await withServer(async (call, { store }) => {
        const { token } = (await call("POST", "/groups/1/invites", "owner")).body;
        assert.strictEqual((await call("DELETE", `/groups/1/invites/${token}`, "outsider")).status, 404);
        assert.strictEqual((await call("DELETE", `/groups/1/invites/${token}`, "member")).status, 200);
        assert.strictEqual((await call("GET", `/invites/${token}`, "outsider")).status, 404);
        assert.strictEqual((await call("POST", `/invites/${token}/accept`, "outsider")).status, 404);
        assert.ok(!store.groups.get(1).members.has("outsider"));
    });
});

test("a used-up link, an unknown token, blocks and a full group are refused", async () => {
    await withServer(async (call, { store }) => {
        const { token } = (await call("POST", "/groups/1/invites", "owner")).body;
        // Blocked the person who made the link
        assert.strictEqual((await call("POST", `/invites/${token}/accept`, "blocker")).status, 403);
        assert.ok(!store.groups.get(1).members.has("blocker"));

        assert.strictEqual((await call("GET", "/invites/not-a-real-token-at-all-000000", "outsider")).status, 404);
        assert.strictEqual((await call("POST", "/invites/x/accept", "outsider")).status, 404);

        store.invites.get(token).max_uses = 1;
        assert.strictEqual((await call("POST", `/invites/${token}/accept`, "outsider")).status, 200);
        assert.strictEqual((await call("POST", `/invites/${token}/accept`, "someone_else")).status, 404);

        // Full: the owner plus 7 others
        const fresh = (await call("POST", "/groups/1/invites", "owner")).body.token;
        for (const name of ["a", "b", "c", "d", "e"]) store.groups.get(1).members.add(name);
        assert.strictEqual(store.groups.get(1).members.size, 7);
        assert.strictEqual((await call("POST", `/invites/${fresh}/accept`, "late")).status, 409);
    });
});
