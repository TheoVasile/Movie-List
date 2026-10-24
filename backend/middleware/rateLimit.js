// Request limits per address or per signed-in user, so one client can't use up the server, the database or our
// TMDb and AI allowance for everyone. Counts are kept in this server's memory, so each instance limits on its own:
// with several instances someone could make up to instances x the limit. Good enough against floods and runaway
// clients; a shared store (Redis) would be needed for an exact limit across instances
//
// Each limit counts requests in fixed windows (a minute by default). Expired counts are swept away every window,
// and at most MAX_KEYS are kept, oldest dropped first, so memory stays bounded however many addresses show up

const MAX_KEYS = 50000;

/// The client's address. Render's proxy adds the real one as the last X-Forwarded-For entry; earlier entries come
/// from the client and can be made up
function clientAddress(req) {
    return String(req.headers["x-forwarded-for"] ?? req.ip ?? "").split(",").pop().trim();
}

/// Middleware allowing `limit` requests per `windowMs` for each key (by default the client's address). Over the
/// limit it answers 429 with Retry-After (seconds) and { error: message }. Requests without a key aren't counted
function rateLimit({ limit, windowMs = 60 * 1000, key = clientAddress, message = "Too many requests. Try again in a minute." }) {
    const counts = new Map();
    // unref so the timer never keeps the process alive on shutdown
    setInterval(() => {
        const now = Date.now();
        for (const [k, entry] of counts) {
            if (entry.resetAt <= now) counts.delete(k);
        }
    }, windowMs).unref();

    return (req, res, next) => {
        const k = key(req);
        if (!k) return next();
        const now = Date.now();
        let entry = counts.get(k);
        if (!entry || entry.resetAt <= now) {
            // Maps keep insertion order, so the first keys are the oldest
            if (counts.size >= MAX_KEYS) {
                for (const old of counts.keys()) {
                    counts.delete(old);
                    if (counts.size < MAX_KEYS * 0.9) break;
                }
            }
            entry = { count: 0, resetAt: now + windowMs };
            counts.set(k, entry);
        }
        entry.count++;
        if (entry.count > limit) {
            res.set("Retry-After", String(Math.ceil((entry.resetAt - now) / 1000)));
            return res.status(429).json({ error: message });
        }
        next();
    };
}

// Requests a minute from one address to the routes that don't need a sign-in (sign-up, Terms, Privacy). Generous,
// since people on the same mobile network or Wi-Fi can share an address
const perAddress = rateLimit({ limit: Number(process.env.RATE_LIMIT_IP_PER_MINUTE) || 120 });

// Requests a minute from one signed-in user, by their Firebase uid. Goes after verifyToken. The app can make a
// burst of requests when it opens (lists, info, discover), so this only stops clients that keep going
const perUser = rateLimit({ limit: Number(process.env.RATE_LIMIT_USER_PER_MINUTE) || 300, key: (req) => req.user?.uid });

module.exports = { rateLimit, perAddress, perUser, clientAddress };
