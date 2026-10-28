const express = require("express");
const { rateLimit } = require("../middleware/rateLimit");
const { appSiteAssociation, links, publicBaseURL } = require("../config/publicLinks");
const pages = require("../views/publicPages");

// The pages behind shared links, for anyone with the link (no sign-in): /l/<list>, /u/<handle>, /f/<tmdb id>,
// /i/<handle> and /join/group/<token>, plus the apple-app-site-association file that lets iOS open those links in
// the app instead. Mounted in server.js before any route that needs a sign-in, and never behind verifyToken.
// Anything that isn't public (a private or followers-only list, a private profile, an expired invite, a typo)
// gets the same "not found" page, so a link never tells anyone whether something private exists

/// Whether a list may be shown to anyone: public, and its owner's profile isn't private
const canShowList = (list) => Boolean(list && list.visibility === "public" && list.owner_private === false && list.owner_handle);
/// Whether a profile may be shown to anyone
const canShowProfile = (profile) => Boolean(profile && profile.is_private === false && profile.handle);

// Page views a minute from one address. Lower than the app's limits: these are read by people, and by the few
// link preview services (iMessage, X, ...) fetching a card
const publicLimit = rateLimit({ limit: Number(process.env.RATE_LIMIT_PUBLIC_PER_MINUTE) || 60, message: "Too many requests. Try again in a minute." });

/// The router, reading through data (models/publicModel.js; the tests pass a stand-in)
function createPublicRouter(data = require("../models/publicModel"), { limiter = publicLimit } = {}) {
    const router = express.Router();

    // iOS fetches this (through Apple's CDN) to learn which paths the app opens. Must be JSON, served directly
    // with no redirect, at either location
    const association = (req, res) => {
        res.set("Cache-Control", "public, max-age=3600");
        res.type("application/json").send(JSON.stringify(appSiteAssociation()));
    };
    router.get("/.well-known/apple-app-site-association", association);
    router.get("/apple-app-site-association", association);

    const send = (res, html, status = 200) => {
        res.status(status);
        res.set({
            "Content-Security-Policy": pages.CONTENT_SECURITY_POLICY,
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "strict-origin-when-cross-origin",
            // Shared pages can be cached for a few minutes; a missing one isn't, so a list made public shows straight away
            "Cache-Control": status === 200 ? "public, max-age=300" : "no-store",
        });
        res.type("html").send(html);
    };
    const notFound = (res) => send(res, pages.notFoundPage(), 404);
    // Wraps a page so an error shows a page rather than Express's own
    const page = (name, handler) => async (req, res) => {
        try {
            await handler(req, res);
        } catch (error) {
            console.error(`Error showing ${name} page:`, error);
            send(res, pages.notFoundPage(), 500);
        }
    };
    const avatarURL = (profile) => (profile.has_avatar ? `${publicBaseURL()}/u/${encodeURIComponent(profile.handle)}/avatar.jpg?v=${Math.round(profile.avatar_version ?? 0)}` : null);

    router.get("/l/:publicId", limiter, page("list", async (req, res) => {
        const list = await data.publicList(req.params.publicId);
        if (!canShowList(list)) return notFound(res);
        send(res, pages.listPage(list, links.list(list.public_id)));
    }));

    router.get("/u/:handle", limiter, page("profile", async (req, res) => {
        const profile = await data.publicProfile(req.params.handle);
        if (!canShowProfile(profile)) return notFound(res);
        send(res, pages.profilePage(profile, links.profile(profile.handle), avatarURL(profile)));
    }));

    // A public profile's picture, for its page and link previews
    router.get("/u/:handle/avatar.jpg", limiter, async (req, res) => {
        try {
            const avatar = await data.publicAvatar(req.params.handle);
            if (!avatar) return res.status(404).set("Cache-Control", "no-store").end();
            res.set({ "Cache-Control": "public, max-age=86400", "X-Content-Type-Options": "nosniff" });
            res.type("image/jpeg").send(avatar);
        } catch (error) {
            console.error("Error showing public avatar:", error);
            res.status(500).end();
        }
    });

    router.get("/f/:tmdbId", limiter, page("film", async (req, res) => {
        const film = await data.publicFilm(req.params.tmdbId);
        if (!film) return notFound(res);
        send(res, pages.filmPage(film, links.film(film.tmdb_id)));
    }));

    router.get("/i/:handle", limiter, page("invite", async (req, res) => {
        const person = await data.invitingUser(req.params.handle);
        if (!person?.handle) return notFound(res);
        // A private profile's picture stays private
        const avatar = person.is_private ? null : avatarURL(await data.publicProfile(person.handle) ?? {});
        send(res, pages.personalInvitePage(person, links.personalInvite(person.handle), avatar));
    }));

    router.get("/join/group/:token", limiter, page("group invite", async (req, res) => {
        const invite = await data.groupInvite(req.params.token);
        if (!invite) return notFound(res);
        send(res, pages.groupInvitePage(invite, links.groupInvite(req.params.token), req.params.token));
    }));

    return router;
}

module.exports = { createPublicRouter, canShowList, canShowProfile };
