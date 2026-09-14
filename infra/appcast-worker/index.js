/**
 * Skein's Sparkle update feed.
 *
 * Sparkle reads SUFeedURL from a value baked into every shipped binary, so
 * pointing it straight at a GitHub repository means renaming or moving that
 * repository silently cuts off updates for everything already installed —
 * which is exactly what happened to Frost. This worker owns the address
 * instead, so the backing store can move without stranding anyone.
 *
 * It proxies rather than stores: GitHub Releases stays the source of truth,
 * and the appcast and its zips are served straight from there.
 */

const RELEASE_BASE = "https://github.com/bavanchun/Skein/releases/latest/download";

export default {
  async fetch(request) {
    const { pathname } = new URL(request.url);

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405 });
    }

    if (pathname === "/appcast.xml") {
      const upstream = await fetch(`${RELEASE_BASE}/appcast.xml`, {
        redirect: "follow",
        cf: { cacheTtl: 300, cacheEverything: true },
      });

      // Surface the upstream status rather than inventing one. Sparkle treats a
      // non-200 as "no update available", which is the correct behaviour before
      // the first release exists.
      return new Response(upstream.body, {
        status: upstream.status,
        headers: {
          "content-type": "application/xml; charset=utf-8",
          "cache-control": "public, max-age=300",
        },
      });
    }

    if (pathname === "/health") {
      return new Response("ok\n", {
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }

    // Anything else belongs to the repository, not to this worker.
    return Response.redirect("https://github.com/bavanchun/Skein", 302);
  },
};
