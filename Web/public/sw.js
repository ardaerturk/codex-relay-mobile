// Only the shell works offline. Conversation data and authentication never enter Cache Storage.
const CACHE = "relay-shell-v1";
self.addEventListener("install", (event) =>
  event.waitUntil(
    caches
      .open(CACHE)
      .then((c) =>
        c.addAll([
          "/",
          "/manifest.webmanifest",
          "/icon-192.png",
          "/icon-512.png",
        ]),
      ),
  ),
);
self.addEventListener("activate", (event) =>
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((k) => k.startsWith("relay-shell-") && k !== CACHE)
            .map((k) => caches.delete(k)),
        ),
      )
      .then(() => self.clients.claim()),
  ),
);
self.addEventListener("fetch", (event) => {
  const u = new URL(event.request.url);
  if (
    event.request.method !== "GET" ||
    u.origin !== location.origin ||
    u.pathname.startsWith("/v1/") ||
    u.pathname.startsWith("/auth/")
  )
    return;
  const shell =
    u.pathname === "/" ||
    u.pathname.startsWith("/assets/") ||
    ["/manifest.webmanifest", "/icon-192.png", "/icon-512.png"].includes(
      u.pathname,
    );
  if (!shell) return;
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        if (response.ok) {
          const copy = response.clone();
          event.waitUntil(
            caches.open(CACHE).then((cache) => cache.put(event.request, copy)),
          );
        }
        return response;
      })
      .catch(
        async () => (await caches.match(event.request)) || Response.error(),
      ),
  );
});
