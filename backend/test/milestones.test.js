const test = require("node:test");
const assert = require("node:assert");
const pool = require("../config/db");
const { MILESTONES, recordMilestone, UnknownMilestoneError, MilestoneNotReachedError } = require("../models/milestonesModel");

// No test database: pool.query is stood in for, answering by the SQL it's sent

const realQuery = pool.query;
test.afterEach(() => { pool.query = realQuery; });

/// A user with `count` different films in their lists, and a user_milestones table held in memory
function fakeDB(count, recorded = new Set()) {
    pool.query = async (sql, params = []) => {
        if (/COUNT\(DISTINCT lm\.movie_id\)/.test(sql)) return { rows: [{ count }] };
        if (/INSERT INTO user_milestones/.test(sql)) {
            const key = `${params[0]}:${params[1]}`;
            if (recorded.has(key)) return { rows: [], rowCount: 0 };
            recorded.add(key);
            return { rows: [], rowCount: 1 };
        }
        throw new Error(`Unexpected query: ${sql}`);
    };
    return recorded;
}

test("the milestones are 10, 50, 100, 1000 and 10000 films", () => {
    assert.deepStrictEqual(Object.values(MILESTONES), [10, 50, 100, 1000, 10000]);
});

test("a milestone is created once, then reported as already reached", async () => {
    fakeDB(120);
    assert.strictEqual((await recordMilestone("u1", "films_100")).created, true);
    assert.strictEqual((await recordMilestone("u1", "films_100")).created, false);
    // Lower milestones can still be recorded (the app marks them silently)
    assert.strictEqual((await recordMilestone("u1", "films_10")).created, true);
});

test("each user gets their own milestones", async () => {
    fakeDB(10);
    assert.strictEqual((await recordMilestone("u1", "films_10")).created, true);
    assert.strictEqual((await recordMilestone("u2", "films_10")).created, true);
});

test("a milestone the user hasn't reached is refused", async () => {
    const recorded = fakeDB(49);
    await assert.rejects(recordMilestone("u1", "films_50"), MilestoneNotReachedError);
    assert.strictEqual(recorded.size, 0);
});

test("unknown milestone ids are refused before the database is asked", async () => {
    pool.query = async () => { throw new Error("should not query"); };
    for (const id of ["films_5", "films_100 ", "", undefined, null, 100, "__proto__", "toString"]) {
        await assert.rejects(recordMilestone("u1", id), UnknownMilestoneError);
    }
});
