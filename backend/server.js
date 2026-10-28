const express = require("express");
const authRoutes = require("./routes/authRoutes");
const listRoutes = require("./routes/listRoutes");
const movieRoutes = require("./routes/movieRoutes");
const letterboxdRoutes = require("./routes/letterboxdRoutes");
const importRoutes = require("./routes/importRoutes");
const userRoutes = require("./routes/userRoutes");
const { createPublicRouter } = require("./routes/publicRoutes");
const { createInviteRouters, notifyJoinedByPush } = require("./routes/inviteRoutes");
const createTables = require("./migrations/setupDB");
const verifyToken = require("./middleware/authMiddleware");
const { perAddress, perUser } = require("./middleware/rateLimit");
const cors = require("cors");
const pool = require("./config/db");
const { termsPage, privacyPage } = require("./config/terms");
const { sendDailyDigests } = require("./services/digestService");
const { sendStreamingAlerts } = require("./services/streamingAlerts");
const { sendSeasonAlerts } = require("./services/tvEpisodes");

// Whether to create and update tables when the server starts. In production the host runs npm run migrate once
// before each deploy (render.yaml's preDeployCommand) instead, so several servers starting at once don't all
// migrate. Locally it's on unless MIGRATE_ON_BOOT=false
const MIGRATE_ON_BOOT = (process.env.MIGRATE_ON_BOOT ?? (process.env.NODE_ENV === "production" ? "false" : "true")) === "true";

const app = express();
// Letterboxd imports can carry thousands of films in one request
app.use(express.json({ limit: "5mb" }));
app.use(cors());

// For the host's health checks, so it needs no sign-in
app.get("/health", (req, res) => res.send("ok"));

// The Terms of Service as a web page, for the App Store listing and the website
app.get("/terms", perAddress, (req, res) => {
    try {
        res.type("html").send(termsPage());
    } catch (error) {
        console.error("Error showing terms:", error);
        res.status(500).send("The Terms of Service couldn't be loaded.");
    }
});

// The Privacy Policy as a web page, for the App Store listing and the website
app.get("/privacy", perAddress, (req, res) => {
    try {
        res.type("html").send(privacyPage());
    } catch (error) {
        console.error("Error showing privacy policy:", error);
        res.status(500).send("The Privacy Policy couldn't be loaded.");
    }
});

// The daily jobs, called once a day by a scheduled GitHub Action with the DIGEST_SECRET shared with that workflow.
// Each answers 202 straight away and carries on here, so the Action doesn't sit waiting (and time out) while
// thousands of people are notified; the result is logged when it's done. A job that's still running isn't started
// again. ?wait=1 waits and answers with the result instead, for trying one out. Every job can safely run again
// after being cut short (by a deploy, say), since each person's last digest and every alert sent are recorded
const running = new Set();

function dailyJob(path, name, notSetUp, job) {
    app.post(path, async (req, res) => {
        const secret = process.env.DIGEST_SECRET;
        if (!secret) return res.status(503).json({ error: notSetUp });
        if (req.get("x-digest-secret") !== secret) return res.status(401).json({ error: "Unauthorized" });
        if (running.has(name)) return res.status(202).json({ started: false, running: true });
        running.add(name);
        const started = Date.now();
        const run = job()
            .then((result) => {
                console.log(`✅ ${name} done in ${Math.round((Date.now() - started) / 1000)}s:`, JSON.stringify(result));
                return result;
            })
            .finally(() => running.delete(name));
        if (req.query.wait !== "1") {
            run.catch((error) => console.error(`Error sending ${name}:`, error));
            return res.status(202).json({ started: true });
        }
        try {
            res.json(await run);
        } catch (error) {
            console.error(`Error sending ${name}:`, error);
            res.status(500).json({ error: "Internal server error" });
        }
    });
}

// The daily friends digest
dailyJob("/internal/digest", "digests", "The digest isn't set up.", sendDailyDigests);
// The day's streaming alerts
dailyJob("/internal/streaming-alerts", "streaming alerts", "Alerts aren't set up.", sendStreamingAlerts);
// Tells people when a new season of a show in their lists starts
dailyJob("/internal/season-alerts", "season alerts", "Alerts aren't set up.", sendSeasonAlerts);

// Shared links' web pages (/l, /u, /f, /i, /join) and the apple-app-site-association file, for anyone with the
// link: no sign-in, their own request limit
app.use(createPublicRouter());

app.use("/auth", perAddress, authRoutes);
// Everything except account setup needs a signed-in user; /auth checks tokens per route
app.use("/lists", verifyToken, perUser, listRoutes);
app.use("/movies", verifyToken, perUser, movieRoutes);
app.use("/letterboxd", verifyToken, perUser, letterboxdRoutes);
app.use("/import", verifyToken, perUser, importRoutes);
app.use("/users", verifyToken, perUser, userRoutes);
// Movie night group invite links
const inviteRouters = createInviteRouters({ invites: require("./models/publicModel").invites, notifyJoined: notifyJoinedByPush });
app.use("/groups", verifyToken, perUser, inviteRouters.groups);
app.use("/invites", verifyToken, perUser, inviteRouters.invites);

// Hosts like Render choose the port; locally it's 3000
const port = process.env.PORT || 3000;

// Takes requests only once the database answers, so the host's health check (and a deploy) only passes when the
// server can actually serve. Supabase can take a few tries to answer from a fresh server
async function start() {
    for (let attempt = 1; ; attempt++) {
        try {
            await pool.query("SELECT 1");
            break;
        } catch (error) {
            if (attempt >= 5) throw error;
            console.error(`Database not reachable (try ${attempt} of 5):`, error.message);
            await new Promise((resolve) => setTimeout(resolve, 3000));
        }
    }
    if (MIGRATE_ON_BOOT) {
        // Locally a failed migration is logged and the server starts anyway, as before
        await createTables().catch(() => {});
    }
    app.listen(port, () => console.log(`Server running on port ${port}`));
    // Closes movie night votes on time
    require("./models/pollModel").scheduleOpenPolls();
}

start().catch((error) => {
    console.error("Couldn't start the server:", error);
    process.exit(1);
});

const shutdown = () => {
    console.log("\n🔻 Closing database connection pool...");
    pool.end(() => {
        console.log("✅ Pool closed. Exiting process...");
        process.exit(0);
    });
};

process.on("SIGINT", shutdown); // Ctrl + C
process.on("SIGTERM", shutdown);
