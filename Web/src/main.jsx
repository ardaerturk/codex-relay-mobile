import React, { useState, useEffect, useRef, memo } from "react";
import { createRoot } from "react-dom/client";
import {
  ArrowUp,
  ArrowDown,
  ChevronRight,
  Copy,
  Check,
  Search,
  PanelLeft,
  X,
  Settings,
  Terminal,
  Folder,
  Pin,
  Square,
  RefreshCw,
  WifiOff,
  FileDiff,
  LogOut,
  Smartphone,
  ShieldCheck,
  CircleHelp,
} from "lucide-react";
import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { api, reconcile, readStored, writeStored } from "./protocol";
import "./style.css";

const join = (...values) => values.filter(Boolean).join(" ");
function IconButton({ label, children, ...props }) {
  return (
    <button
      type="button"
      title={label}
      aria-label={label}
      className="icon-button"
      {...props}
    >
      {children}
    </button>
  );
}
function Mark({ small = false }) {
  return (
    <span className={join("mark", small && "small")} aria-hidden="true">
      <Terminal size={small ? 19 : 30} />
    </span>
  );
}
function CopyButton({ text }) {
  const [copied, setCopied] = useState(false);
  return (
    <IconButton
      label={copied ? "Copied" : "Copy"}
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(text);
          setCopied(true);
          setTimeout(() => setCopied(false), 1500);
        } catch {
          setCopied(false);
        }
      }}
    >
      {copied ? <Check size={15} /> : <Copy size={15} />}
    </IconButton>
  );
}
const components = {
  a: ({ href, children }) => (
    <a href={href} target="_blank" rel="noreferrer noopener">
      {children}
    </a>
  ),
  img: ({ alt }) => (
    <span className="muted">[Image{alt ? `: ${alt}` : ""} — view on VM]</span>
  ),
  pre: ({ children }) => (
    <div className="code-block">
      <div className="code-top">
        <span>Code</span>
        <CopyButton
          text={React.Children.toArray(children)
            .map((c) => c.props?.children || "")
            .join("")}
        />
      </div>
      <pre>{children}</pre>
    </div>
  ),
};
const Message = memo(function Message({ item }) {
  if (item.kind === "userMessage")
    return (
      <article className="user-message">
        <div>{item.text}</div>
        <CopyButton text={item.text} />
      </article>
    );
  if (item.kind === "agentMessage")
    return (
      <article className="agent-message">
        <Markdown remarkPlugins={[remarkGfm]} components={components}>
          {item.text}
        </Markdown>
        {item.phase === "final" && <CopyButton text={item.text} />}
      </article>
    );
  return (
    <details className={join("tool", item.status === "failed" && "failed")}>
      <summary>
        <ChevronRight size={14} />
        {item.kind === "commandExecution" ? (
          <Terminal size={15} />
        ) : item.kind === "fileChange" ? (
          <FileDiff size={15} />
        ) : null}
        <span>{item.title || item.kind}</span>
        {item.status === "inProgress" ? (
          <span className="pulse-dot" />
        ) : (
          <span className="tool-status">
            {item.status === "completed" ? "Done" : item.status}
          </span>
        )}
      </summary>
      <div className="tool-output">
        <CopyButton text={item.text} />
        <pre>{item.text || "Waiting for output…"}</pre>
      </div>
    </details>
  );
});
function Request({ request, onCommand, disabled }) {
  const [answers, setAnswers] = useState({});
  const p = request.params || {};
  const command = request.method === "item/commandExecution/requestApproval";
  const file = request.method === "item/fileChange/requestApproval";
  const question = request.method === "item/tool/requestUserInput";
  return (
    <section className="request">
      <div className="request-heading">
        <ShieldCheck size={18} />
        <strong>
          {question
            ? "Codex needs your input"
            : command
              ? "Allow this command?"
              : file
                ? "Allow these file changes?"
                : "Action required on your VM"}
        </strong>
      </div>
      {p.reason && <p>{p.reason}</p>}
      {command && (
        <pre>
          {typeof p.command === "string"
            ? p.command
            : JSON.stringify(p.command)}
        </pre>
      )}
      {file && (
        <pre>{JSON.stringify(p.changes || p.grantRoot || {}, null, 2)}</pre>
      )}
      {question &&
        p.questions?.map((q) => (
          <fieldset key={q.id}>
            <legend>{q.question}</legend>
            {q.options?.map((o) => (
              <label className="option" key={o.label}>
                <input
                  type="radio"
                  name={q.id}
                  checked={answers[q.id] === o.label}
                  onChange={() => setAnswers({ ...answers, [q.id]: o.label })}
                />
                <span>
                  <b>{o.label}</b>
                  {o.description && <small>{o.description}</small>}
                </span>
              </label>
            ))}
            <input
              type={q.isSecret ? "password" : "text"}
              aria-label={`Answer: ${q.question}`}
              placeholder="Write an answer"
              value={answers[q.id] || ""}
              onChange={(e) =>
                setAnswers({ ...answers, [q.id]: e.target.value })
              }
            />
          </fieldset>
        ))}
      <div className="request-actions">
        {(command || file) && (
          <>
            <button
              disabled={disabled}
              onClick={() =>
                onCommand({
                  operation: command ? "approveCommand" : "approveFile",
                  requestId: request.id,
                  decision: "decline",
                })
              }
            >
              Decline
            </button>
            <button
              className="primary"
              disabled={disabled}
              onClick={() =>
                onCommand({
                  operation: command ? "approveCommand" : "approveFile",
                  requestId: request.id,
                  decision: "accept",
                })
              }
            >
              Allow once
            </button>
          </>
        )}
        {question && (
          <button
            className="primary"
            disabled={
              disabled || !p.questions?.every((q) => answers[q.id]?.trim())
            }
            onClick={() =>
              onCommand({
                operation: "answer",
                requestId: request.id,
                answers: Object.fromEntries(
                  Object.entries(answers).map(([key, value]) => [
                    key,
                    { answers: [value] },
                  ]),
                ),
              })
            }
          >
            Submit answer
          </button>
        )}
      </div>
    </section>
  );
}
function Login({ onConnected }) {
  const [token, setToken] = useState(""),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false);
  return (
    <main className="login">
      <div className="login-inner">
        <Mark />
        <h1>
          Your Codex.
          <br />
          From anywhere.
        </h1>
        <p>
          Connect to <strong>your VM</strong>.<br />
          Your tasks and Azure connection stay on the VM.
        </p>
        <form
          onSubmit={async (e) => {
            e.preventDefault();
            setBusy(true);
            setError("");
            try {
              await api("/auth/session", {
                method: "POST",
                body: JSON.stringify({ token: token.trim() }),
              });
              setToken("");
              onConnected();
            } catch (e) {
              setError(e.message);
            } finally {
              setBusy(false);
            }
          }}
        >
          <label htmlFor="pairing">Pairing code</label>
          <input
            id="pairing"
            type="password"
            autoComplete="off"
            autoCapitalize="none"
            spellCheck="false"
            value={token}
            onChange={(e) => setToken(e.target.value)}
            placeholder="Paste your private pairing code"
            required
          />
          <button className="primary" disabled={!token.trim() || busy}>
            {busy ? "Connecting…" : "Connect to your VM"}
            <ArrowUp size={17} />
          </button>
          {error && (
            <p role="alert" className="error-text">
              {error}
            </p>
          )}
        </form>
        <details className="setup-help">
          <summary>Where do I find my pairing code?</summary>
          <p>
            On your Mac, run <b>Scripts/copy-pairing-code.sh your-ssh-host</b>, then
            paste here. Keep Tailscale connected on your phone.
          </p>
          <p>Or, in a terminal on the VM:</p>
          <code>cat ~/.local/state/relay/pairing-token</code>
        </details>
        <div className="login-footer">
          <ShieldCheck size={15} /> Private connection over Tailscale
        </div>
      </div>
    </main>
  );
}
function App() {
  const [auth, setAuth] = useState(null),
    [health, setHealth] = useState(null),
    [authError, setAuthError] = useState("");
  const [threads, setThreads] = useState([]),
    [cursor, setCursor] = useState(null),
    [search, setSearch] = useState(""),
    [listError, setListError] = useState(""),
    [loadingList, setLoadingList] = useState(false);
  const [selected, setSelected] = useState(() =>
      readStored("relay-task", null),
    ),
    [conversation, setConversation] = useState(null),
    [streamStatus, setStreamStatus] = useState("connecting"),
    [streamError, setStreamError] = useState(""),
    [reload, setReload] = useState(0);
  const [sidebar, setSidebar] = useState(false),
    [settings, setSettings] = useState(false),
    [diff, setDiff] = useState(false),
    [theme, setTheme] = useState(() => readStored("relay-theme", "system"));
  const [text, setText] = useState(""),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [pending, setPending] = useState(() => readStored("relay-pending", null));
  const [visibleCount, setVisibleCount] = useState(100),
    [atBottom, setAtBottom] = useState(true),
    [notice, setNotice] = useState("");
  const listGeneration = useRef(0),
    current = useRef(null),
    timeline = useRef(null),
    textarea = useRef(null),
    lock = useRef(false),
    followBottom = useRef(true),
    socket = useRef(null),
    drafts = useRef({});
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    writeStored("relay-theme", theme);
  }, [theme]);
  useEffect(() => {
    const vp = window.visualViewport;
    const size = () => {
      document.documentElement.style.setProperty(
        "--app-height",
        `${vp?.height || innerHeight}px`,
      );
    };
    size();
    vp?.addEventListener("resize", size);
    return () => vp?.removeEventListener("resize", size);
  }, []);
  async function checkAuth() {
    try {
      const h = await api("/v1/health");
      setHealth(h);
      setAuth(true);
      setAuthError("");
    } catch (e) {
      if (e.status === 401) {
        setAuth(false);
        setConversation(null);
        setThreads([]);
      } else
        setAuthError("Cannot reach your VM. Check Tailscale and try again.");
    }
  }
  useEffect(() => {
    checkAuth();
  }, []);
  async function loadThreads(more = false) {
    const generation = ++listGeneration.current;
    setLoadingList(true);
    try {
      const data = await api(
        `/v1/threads?limit=50&search=${encodeURIComponent(search)}${more && cursor ? `&cursor=${cursor}` : ""}`,
      );
      if (generation !== listGeneration.current) return;
      setThreads((prev) =>
        more
          ? [
              ...prev,
              ...data.data.filter((t) => !prev.some((p) => p.id === t.id)),
            ]
          : data.data,
      );
      setCursor(data.nextCursor);
      setListError("");
    } catch (e) {
      if (e.status === 401) setAuth(false);
      else setListError(e.message);
    } finally {
      if (generation === listGeneration.current) setLoadingList(false);
    }
  }
  useEffect(() => {
    if (!auth) return;
    const timer = setTimeout(() => loadThreads(), 200);
    return () => {
      clearTimeout(timer);
      listGeneration.current++;
    };
  }, [auth, search]);
  function choose(id) {
    setSelected(id);
    writeStored("relay-task", id);
    setSidebar(false);
    setError("");
    setDiff(false);
    setText(drafts.current[id] || "");
  }
  useEffect(() => {
    if (!auth || !selected) return;
    let alive = true,
      timer,
      attempt = 0;
    current.current = null;
    setConversation(null);
    setVisibleCount(100);
    setStreamError("");
    followBottom.current = true;
    setText(drafts.current[selected] || "");
    function open() {
      if (!alive) return;
      setStreamStatus("connecting");
      const ws = new WebSocket(
        `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/v1/threads/${encodeURIComponent(selected)}/stream`,
      );
      socket.current = ws;
      ws.onmessage = (e) => {
        if (!alive || socket.current !== ws) return;
        try {
          const next = reconcile(current.current, JSON.parse(e.data));
          current.current = next;
          setConversation(next);
          setStreamStatus(next.ownerAvailable ? "live" : "disconnected");
          setStreamError(
            next.ownerAvailable ? "" : "Codex on your VM is disconnected.",
          );
          attempt = 0;
          if (!next.ownerAvailable) ws.close();
        } catch (e) {
          setStreamError(e.message);
          ws.close();
        }
      };
      ws.onclose = async () => {
        if (!alive || socket.current !== ws) return;
        setStreamStatus("disconnected");
        try {
          await api("/v1/health");
        } catch (e) {
          if (e.status === 401) {
            setAuth(false);
            return;
          }
        }
        if (attempt === 0) {
          try {
            await api(`/v1/threads/${selected}`);
          } catch (e) {
            if (alive) setStreamError(e.message);
          }
        }
        if (alive && socket.current === ws)
          timer = setTimeout(open, Math.min(15000, 1000 * 2 ** attempt++));
      };
    }
    const wake = () => {
      if (document.visibilityState === "visible") {
        clearTimeout(timer);
        if (socket.current) {
          socket.current.onclose = null;
          socket.current.close();
        }
        open();
        loadThreads();
      }
    };
    open();
    window.addEventListener("online", wake);
    document.addEventListener("visibilitychange", wake);
    return () => {
      alive = false;
      clearTimeout(timer);
      if (socket.current) {
        socket.current.onclose = null;
        socket.current.close();
      }
      window.removeEventListener("online", wake);
      document.removeEventListener("visibilitychange", wake);
    };
  }, [selected, auth, reload]);
  useEffect(() => {
    if (followBottom.current && timeline.current)
      timeline.current.scrollTop = timeline.current.scrollHeight;
  }, [conversation?.messages]);
  useEffect(() => {
    if (textarea.current) {
      textarea.current.style.height = "auto";
      textarea.current.style.height = `${Math.min(180, textarea.current.scrollHeight)}px`;
    }
  }, [text]);
  useEffect(() => {
    if (!settings && !diff && !sidebar) return;
    const root = document.querySelector(
      settings || diff ? ".modal" : ".sidebar",
    );
    const previous = document.activeElement;
    const controls = () =>
      Array.from(
        root?.querySelectorAll(
          "button:not(:disabled), input, select, textarea, a[href]",
        ) || [],
      ).filter(
        (el) =>
          el.getClientRects().length &&
          getComputedStyle(el).visibility !== "hidden",
      );
    controls()[0]?.focus();
    const key = (e) => {
      if (e.key === "Escape") {
        setSettings(false);
        setDiff(false);
        setSidebar(false);
      }
      if (e.key === "Tab") {
        const items = controls(),
          first = items[0],
          last = items.at(-1);
        if (e.shiftKey && document.activeElement === first) {
          e.preventDefault();
          last?.focus();
        } else if (!e.shiftKey && document.activeElement === last) {
          e.preventDefault();
          first?.focus();
        }
      }
    };
    document.addEventListener("keydown", key);
    return () => {
      document.removeEventListener("keydown", key);
      previous?.focus();
    };
  }, [settings, diff, sidebar]);
  async function resolvePending() {
    if (!pending) return;
    try {
      const result = await api(`/v1/delivery/${pending.id}`);
      if (result.status === "accepted") {
        clearPending();
        setNotice("Your previous action was received by Codex.");
      } else
        setError(
          result.status === "sending"
            ? "Codex is still receiving that action. Check again shortly."
            : "Delivery could not be confirmed. Check the task before dismissing this notice and trying again.",
        );
    } catch (e) {
      setError(e.message);
    }
  }
  function clearPending() {
    writeStored("relay-pending", null);
    setPending(null);
    setError("");
  }
  useEffect(() => {
    if (auth && pending) resolvePending();
  }, [auth]);
  async function command(body) {
    if (lock.current || pending || !selected) return;
    lock.current = true;
    setBusy(true);
    setError("");
    const id = crypto.randomUUID();
    const record = { id, thread: selected, operation: body.operation };
    if (!writeStored("relay-pending", record)) {
      setError(
        "Private browser storage is unavailable. Enable it before sending.",
      );
      lock.current = false;
      setBusy(false);
      return;
    }
    setPending(record);
    try {
      const result = await api(`/v1/threads/${selected}/commands`, {
        method: "POST",
        body: JSON.stringify({ id, ...body }),
      });
      if (result.status === "accepted") {
        clearPending();
        if (body.operation === "send") {
          setText("");
          drafts.current[selected] = "";
          followBottom.current = true;
        }
        setNotice(
          body.operation === "send"
            ? "Sent to Codex"
            : body.operation === "stop"
              ? "Stop requested"
              : "Action received",
        );
      } else
        setError("Delivery is uncertain. Check the task before trying again.");
    } catch (e) {
      if (e.status && e.status < 500) {
        clearPending();
        setError(e.message);
      } else
        setError(
          "Connection interrupted. Your action may have arrived. Check delivery before trying again.",
        );
    } finally {
      lock.current = false;
      setBusy(false);
    }
  }
  async function logout() {
    try {
      await api("/auth/logout", { method: "POST", body: "{}" });
      setAuth(false);
      setConversation(null);
      current.current = null;
      setThreads([]);
      setSettings(false);
      setText("");
      drafts.current = {};
    } catch (e) {
      setError(e.message);
    }
  }
  const task = conversation || threads.find((t) => t.id === selected);
  const connected = streamStatus === "live";
  const active =
    conversation?.status === "active" || !!conversation?.activeTurnId;
  const disabled = !connected || busy || !!pending;
  if (auth !== true)
    return (
      <>
        {auth === false ? (
          <Login onConnected={checkAuth} />
        ) : (
          <main className="login">
            <div className="login-inner">
              <Mark />
              <h1>Connecting to your VM</h1>
              <p>{authError || "Opening your private workspace…"}</p>
              {authError && <button onClick={checkAuth}>Try again</button>}
            </div>
          </main>
        )}
      </>
    );
  return (
    <div className="app-shell">
      {sidebar && (
        <button
          className="scrim sidebar-scrim"
          aria-label="Close task list"
          onClick={() => setSidebar(false)}
        />
      )}
      <aside
        inert={settings || diff ? true : undefined}
        className={join("sidebar", sidebar && "open")}
        aria-label="Tasks"
      >
        <div className="sidebar-top">
          <div className="brand">
            <Mark small />
            <strong>Relay</strong>
          </div>
          <IconButton label="Close task list" onClick={() => setSidebar(false)}>
            <PanelLeft size={18} />
          </IconButton>
        </div>
        <div className="search">
          <Search size={16} />
          <input
            aria-label="Search tasks"
            placeholder="Search tasks"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
          {search && (
            <IconButton label="Clear search" onClick={() => setSearch("")}>
              <X size={14} />
            </IconButton>
          )}
        </div>
        <div className="list-heading">
          <span>Tasks on your VM</span>
          <IconButton
            label="Refresh tasks"
            onClick={() => loadThreads()}
            disabled={loadingList}
          >
            <RefreshCw size={14} className={loadingList ? "spin" : ""} />
          </IconButton>
        </div>
        <nav className="task-list">
          {listError && (
            <p role="alert" className="error-text">
              {listError}
            </p>
          )}
          {!loadingList && !threads.length && (
            <p className="muted">No matching tasks.</p>
          )}
          {threads.map((t) => (
            <button
              key={t.id}
              className={join("task-row", selected === t.id && "selected")}
              aria-current={selected === t.id ? "page" : undefined}
              onClick={() => choose(t.id)}
            >
              <span className="task-title">{t.title}</span>
              <span className="task-meta">
                {t.isPinned ? <Pin size={11} /> : <Folder size={11} />}
                <span>
                  {t.cwd?.split("/").filter(Boolean).pop() || "Workspace"}
                </span>
                {t.status === "active" && <span className="pulse-dot" />}
              </span>
            </button>
          ))}
          {cursor && (
            <button
              className="load-more"
              disabled={loadingList}
              onClick={() => loadThreads(true)}
            >
              {loadingList ? "Loading…" : "Show more tasks"}
            </button>
          )}
        </nav>
        <button className="host-button" onClick={() => setSettings(true)}>
          <span
            className={join("host-dot", health?.desktopConnected && "online")}
          />
          <span>
            <b>your VM</b>
            <small>Connected through Tailscale</small>
          </span>
          <Settings size={17} />
        </button>
      </aside>
      <main className="workspace" inert={settings || diff ? true : undefined}>
        <header className="topbar">
          <IconButton label="Open task list" onClick={() => setSidebar(true)}>
            <PanelLeft size={19} />
          </IconButton>
          <div className="task-heading">
            <h1>{task?.title || "Your workspace"}</h1>
            <span>
              {task?.cwd?.split("/").filter(Boolean).pop() ||
                "your VM"}
            </span>
          </div>
          {conversation?.diff && (
            <IconButton
              label="Review latest changes"
              onClick={() => setDiff(true)}
            >
              <FileDiff size={19} />
            </IconButton>
          )}
          <IconButton
            label="Connection and settings"
            onClick={() => setSettings(true)}
          >
            <Settings size={18} />
          </IconButton>
        </header>
        {!selected ? (
          <div className="empty-state">
            <Mark />
            <h2>Pick up where you left off.</h2>
            <p>
              Your Codex tasks, running on your VM.
              <br />
              Choose a task to continue the conversation.
            </p>
            <button className="primary" onClick={() => setSidebar(true)}>
              Browse tasks <ChevronRight size={17} />
            </button>
          </div>
        ) : (
          <>
            {!connected && (
              <div className="connection-banner" role="status">
                <WifiOff size={15} />
                <span>
                  {streamError ||
                    (streamStatus === "connecting"
                      ? "Connecting to Codex…"
                      : "Reconnecting… Your work continues on the VM.")}
                </span>
                <IconButton
                  label="Reconnect"
                  onClick={() => setReload((x) => x + 1)}
                >
                  <RefreshCw size={15} />
                </IconButton>
              </div>
            )}
            <div
              className="timeline"
              ref={timeline}
              onScroll={(e) => {
                const el = e.currentTarget;
                followBottom.current =
                  el.scrollHeight - el.scrollTop - el.clientHeight < 120;
                setAtBottom(followBottom.current);
              }}
            >
              <div className="conversation-inner">
                {conversation && !conversation.historyComplete && (
                  <button
                    className="history-button"
                    disabled={disabled}
                    onClick={() => command({ operation: "loadHistory" })}
                  >
                    Load complete history
                  </button>
                )}
                {conversation?.messages.length > visibleCount && (
                  <button
                    className="history-button"
                    onClick={() => {
                      followBottom.current = false;
                      setVisibleCount((x) => x + 100);
                    }}
                  >
                    Show earlier messages
                  </button>
                )}
                {conversation?.messages.slice(-visibleCount).map((m) => (
                  <Message key={m.id} item={m} />
                ))}
                {conversation?.requests.map((r) => (
                  <Request
                    key={r.id}
                    request={r}
                    disabled={disabled}
                    onCommand={command}
                  />
                ))}
                {active && (
                  <div className="working">
                    <span className="pulse-dot" />
                    Codex is working
                  </div>
                )}
                {conversation && !conversation.messages.length && (
                  <p className="muted">
                    This task is ready. Send a message to continue.
                  </p>
                )}
              </div>
            </div>
            <div className="composer-zone">
              {!atBottom && (
                <button
                  className="jump-bottom"
                  onClick={() => {
                    followBottom.current = true;
                    timeline.current?.scrollTo({
                      top: timeline.current.scrollHeight,
                      behavior: "smooth",
                    });
                  }}
                >
                  <ArrowDown size={16} /> Latest
                </button>
              )}
              {pending && (
                <div className="pending" role="status">
                  <span>
                    An action needs a delivery check.
                    {pending.thread !== selected &&
                      " It belongs to another task."}
                  </span>
                  <button onClick={resolvePending} disabled={busy}>
                    Check delivery
                  </button>
                  {pending.thread !== selected && (
                    <button onClick={() => choose(pending.thread)}>
                      Open task
                    </button>
                  )}
                  <button
                    onClick={() => {
                      if (
                        window.confirm(
                          "Check the conversation first: this action may already have arrived. Dismiss the delivery notice?",
                        )
                      )
                        clearPending();
                    }}
                    disabled={busy}
                  >
                    Dismiss
                  </button>
                </div>
              )}
              {error && (
                <div className="error-banner" role="alert">
                  <span>{error}</span>
                  <IconButton
                    label="Dismiss error"
                    onClick={() => setError("")}
                  >
                    <X size={14} />
                  </IconButton>
                </div>
              )}
              <form
                className={join("composer", !connected && "unavailable")}
                onSubmit={(e) => {
                  e.preventDefault();
                  if (text.trim() && !disabled)
                    command({ operation: "send", text });
                }}
              >
                <textarea
                  ref={textarea}
                  aria-label="Message Codex"
                  placeholder={
                    active ? "Add a follow-up…" : "Ask Codex to do anything"
                  }
                  rows={2}
                  value={text}
                  maxLength={100000}
                  onChange={(e) => {
                    setText(e.target.value);
                    drafts.current[selected] = e.target.value;
                  }}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                      e.preventDefault();
                      if (text.trim() && !disabled)
                        command({ operation: "send", text });
                    }
                  }}
                />
                <div className="composer-bottom">
                  <span className="model-label">
                    {conversation?.model || "VM settings"}
                    {conversation?.effort && (
                      <span> · {conversation.effort}</span>
                    )}
                  </span>
                  <div className="composer-actions">
                    {active && (
                      <IconButton
                        label="Stop current task"
                        disabled={disabled || !conversation.activeTurnId}
                        onClick={() =>
                          command({
                            operation: "stop",
                            expectedTurnId: conversation.activeTurnId,
                          })
                        }
                      >
                        <Square size={15} />
                      </IconButton>
                    )}
                    <button
                      className="send-button"
                      type="submit"
                      aria-label={active ? "Send follow-up" : "Send message"}
                      disabled={disabled || !text.trim()}
                    >
                      {busy ? (
                        <RefreshCw size={19} className="spin" />
                      ) : (
                        <ArrowUp size={20} />
                      )}
                    </button>
                  </div>
                </div>
              </form>
              <div className="composer-caption">
                <span className={join("status-dot", connected && "online")} />
                {connected
                  ? "Live on your VM"
                  : "Waiting for your VM"}
                <span className="caption-right">
                  {conversation?.permissions || "Host permissions"}
                </span>
              </div>
              <span className="sr-only" role="status">
                {notice}
              </span>
            </div>
          </>
        )}
      </main>
      {settings && (
        <div className="modal-backdrop" onClick={() => setSettings(false)}>
          <section
            className="modal"
            role="dialog"
            aria-modal="true"
            aria-labelledby="settings-title"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="modal-heading">
              <h2 id="settings-title">Your connection</h2>
              <IconButton
                label="Close settings"
                onClick={() => setSettings(false)}
              >
                <X size={19} />
              </IconButton>
            </div>
            <div className="connection-card">
              <Mark small />
              <div>
                <b>your VM</b>
                <p>Azure VM · Private Tailscale network</p>
              </div>
              <span className="host-dot online" />
            </div>
            <div className="settings-row">
              <label htmlFor="theme">Appearance</label>
              <select
                id="theme"
                value={theme}
                onChange={(e) => setTheme(e.target.value)}
              >
                <option value="system">System</option>
                <option value="dark">Dark</option>
                <option value="light">Light</option>
              </select>
            </div>
            <div className="setting-info">
              <Smartphone size={19} />
              <div>
                <b>Add to your iPhone Home Screen</b>
                <p>
                  Open this address in Safari, tap Share, then Add to Home
                  Screen. Enable “Open as Web App” if shown.
                </p>
              </div>
            </div>
            <div className="setting-info">
              <ShieldCheck size={19} />
              <div>
                <b>Your VM does the work</b>
                <p>
                  Azure keys, models and tools stay on the VM. Keep Tailscale
                  connected and Codex running there.
                </p>
              </div>
            </div>
            <div className="setting-info">
              <CircleHelp size={19} />
              <div>
                <b>Desktop companion</b>
                <p>
                  Continue existing desktop tasks here. Create new tasks and
                  change models on the VM. Voice and file uploads are not
                  available in this version.
                </p>
              </div>
            </div>
            <button className="signout" onClick={logout}>
              <LogOut size={17} /> Disconnect this device
            </button>
            <small className="muted">
              Relay 0.2 · Independent companion for Codex
            </small>
          </section>
        </div>
      )}
      {diff && (
        <div className="modal-backdrop" onClick={() => setDiff(false)}>
          <section
            className="modal diff-modal"
            role="dialog"
            aria-modal="true"
            aria-label="Latest changes"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="modal-heading">
              <h2>Latest changes</h2>
              <IconButton label="Close changes" onClick={() => setDiff(false)}>
                <X size={19} />
              </IconButton>
            </div>
            <pre>{conversation?.diff}</pre>
          </section>
        </div>
      )}
    </div>
  );
}
createRoot(document.getElementById("root")).render(<App />);
if ("serviceWorker" in navigator)
  window.addEventListener("load", () =>
    navigator.serviceWorker.register("/sw.js").catch(() => {}),
  );
