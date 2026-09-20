export function reconcile(current, event) {
  if (event.type === "conversation") return event.conversation;
  if (event.type !== "conversationPatch" || !current)
    throw new Error("A fresh conversation is required.");
  if (event.patch.metadata.id !== current.id)
    throw new Error("Conversation changed.");
  const items = new Map(current.messages.map((item) => [item.id, item]));
  for (const item of event.patch.upserts) items.set(item.id, item);
  const messages = event.patch.order.map((id) => {
    if (!items.has(id)) throw new Error("An update is missing. Reconnecting…");
    return items.get(id);
  });
  return { ...current, ...event.patch.metadata, messages };
}
export async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    credentials: "same-origin",
    cache: "no-store",
    headers: { "Content-Type": "application/json", ...options.headers },
  });
  let data;
  try {
    data = await response.json();
  } catch {
    const e = new Error(
      "The server returned an unreadable response. Reconnect to your VM.",
    );
    e.status = response.ok ? 502 : response.status;
    throw e;
  }
  if (!response.ok) {
    const e = new Error(data.error || `Request failed (${response.status})`);
    e.status = response.status;
    throw e;
  }
  return data;
}
export function readStored(key, fallback) {
  try {
    return JSON.parse(localStorage.getItem(key)) ?? fallback;
  } catch {
    return fallback;
  }
}
export function writeStored(key, value) {
  try {
    if (value == null) localStorage.removeItem(key);
    else localStorage.setItem(key, JSON.stringify(value));
    return true;
  } catch {
    return false;
  }
}
