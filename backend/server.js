const express = require("express");
const authRoutes = require("./routes/authRoutes");
const listRoutes = require("./routes/listRoutes");
const movieRoutes = require("./routes/movieRoutes");
const letterboxdRoutes = require("./routes/letterboxdRoutes");
const userRoutes = require("./routes/userRoutes");
const createTables = require("./migrations/setupDB");
const verifyToken = require("./middleware/authMiddleware");
const cors = require("cors");
const pool = require("./config/db");
const { sendDailyDigests } = require("./services/digestService");
const { sendStreamingAlerts } = require("./services/streamingAlerts");

const app = express();
// Letterboxd imports can carry thousands of films in one request
app.use(express.json({ limit: "5mb" }));
app.use(cors());

// Then closes movie night votes on time, which needs their tables
createTables().then(() => require("./models/pollModel").scheduleOpenPolls());

// For the host's health checks, so it needs no sign-in
app.get("/health", (req, res) => res.send("ok"));

// Sends the daily friends digest. Called once a day by a scheduled GitHub Action, since the free host
// sleeps and can't keep its own timer. Needs the DIGEST_SECRET shared with that workflow
app.post("/internal/digest", async (req, res) => {
    const secret = process.env.DIGEST_SECRET;
    if (!secret) return res.status(503).json({ error: "The digest isn't set up." });
    if (req.get("x-digest-secret") !== secret) return res.status(401).json({ error: "Unauthorized" });
    try {
        res.json(await sendDailyDigests());
    } catch (error) {
        console.error("Error sending digests:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// Sends the day's streaming alerts, from the same daily GitHub Action as the digest, with the same secret
app.post("/internal/streaming-alerts", async (req, res) => {
    const secret = process.env.DIGEST_SECRET;
    if (!secret) return res.status(503).json({ error: "Alerts aren't set up." });
    if (req.get("x-digest-secret") !== secret) return res.status(401).json({ error: "Unauthorized" });
    try {
        res.json(await sendStreamingAlerts());
    } catch (error) {
        console.error("Error sending streaming alerts:", error);
        res.status(500).json({ error: "Internal server error" });
    }
});

app.use("/auth", authRoutes);
// Everything except account setup needs a signed-in user; /auth checks tokens per route
app.use("/lists", verifyToken, listRoutes);
app.use("/movies", verifyToken, movieRoutes);
app.use("/letterboxd", verifyToken, letterboxdRoutes);
app.use("/users", verifyToken, userRoutes);

// Hosts like Render choose the port; locally it's 3000
const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`Server running on port ${port}`));

const shutdown = () => {
    console.log("\n🔻 Closing database connection pool...");
    pool.end(() => {
        console.log("✅ Pool closed. Exiting process...");
        process.exit(0);
    });
};

process.on("SIGINT", shutdown); // Ctrl + C
process.on("SIGTERM", shutdown);