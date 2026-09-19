// Browser replacements for the Tauri APIs used by reSpeaker Console.
// Every @tauri-apps/* import is aliased to this file (see vite.config.ts).

// --- @tauri-apps/api/core: commands go to server.py over HTTP ---------------

// The console falls back to its in-memory mock when this is missing
(window as unknown as { __TAURI_INTERNALS__?: object }).__TAURI_INTERNALS__ ??= {};

// Desktop-only commands without a backend counterpart
const LOCAL_COMMANDS: Record<string, unknown> = { update_tray_menu: null };

export async function invoke<T>(cmd: string, args: Record<string, unknown> = {}): Promise<T> {
  if (cmd in LOCAL_COMMANDS) return LOCAL_COMMANDS[cmd] as T;
  let response: Response;
  try {
    response = await fetch(`api/invoke/${cmd}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(args),
    });
  } catch (error) {
    throw `backend unreachable: ${error}`;
  }
  const data = await response.json().catch(() => ({ error: response.statusText }));
  // Tauri rejects with the command's error string
  if (!response.ok) throw data.error ?? response.statusText;
  return data.result as T;
}

// --- @tauri-apps/api/event: server events over SSE, page events locally -----

export type UnlistenFn = () => void;
export interface Event<T> {
  event: string;
  id: number;
  payload: T;
}
type Handler = (event: Event<unknown>) => void;

const handlers = new Map<string, Set<Handler>>();
let source: EventSource | null = null;
let nextId = 0;

function dispatch(event: string, payload: unknown) {
  for (const handler of handlers.get(event) ?? []) handler({ event, id: nextId++, payload });
}

export async function listen<T>(event: string, handler: (event: Event<T>) => void): Promise<UnlistenFn> {
  if (!source) {
    source = new EventSource("api/events");
    source.onmessage = (message) => {
      const { event, payload } = JSON.parse(message.data);
      dispatch(event, payload);
    };
  }
  if (!handlers.has(event)) handlers.set(event, new Set());
  const set = handlers.get(event)!;
  set.add(handler as Handler);
  return () => set.delete(handler as Handler);
}

export async function once<T>(event: string, handler: (event: Event<T>) => void): Promise<UnlistenFn> {
  const unlisten = await listen<T>(event, (e) => {
    unlisten();
    handler(e);
  });
  return unlisten;
}

export async function emit(event: string, payload?: unknown): Promise<void> {
  dispatch(event, payload);
}

// --- @tauri-apps/api/window, webviewWindow, dpi: the page is the only window --

const noopWindow: Record<string, unknown> = new Proxy(
  {},
  { get: (_, prop) => (prop === "then" ? undefined : async () => undefined) }
);

export function getCurrentWindow() {
  return noopWindow;
}

export class WebviewWindow {
  constructor() {
    return noopWindow as unknown as WebviewWindow;
  }
  static async getByLabel() {
    return null;
  }
  static getCurrent() {
    return noopWindow;
  }
}

export class LogicalPosition {
  constructor(
    public x: number,
    public y: number
  ) {}
}

// --- @tauri-apps/api/app ------------------------------------------------------

declare const __CONSOLE_VERSION__: string;

export async function getVersion(): Promise<string> {
  return __CONSOLE_VERSION__;
}

// --- @tauri-apps/plugin-dialog and plugin-fs: file picker and downloads -------

interface DialogOptions {
  filters?: { name: string; extensions: string[] }[];
  defaultPath?: string;
}

const pickedFiles = new Map<string, File>();

export async function open(options: DialogOptions = {}): Promise<string | null> {
  const input = document.createElement("input");
  input.type = "file";
  input.accept = (options.filters ?? [])
    .flatMap((f) => f.extensions)
    .filter((ext) => ext !== "*")
    .map((ext) => `.${ext}`)
    .join(",");
  const file = await new Promise<File | null>((resolve) => {
    input.onchange = () => resolve(input.files?.[0] ?? null);
    input.oncancel = () => resolve(null);
    input.click();
  });
  if (!file) return null;
  const path = `upload://${file.name}`;
  pickedFiles.set(path, file);
  return path;
}

// The returned "path" only names the download in writeTextFile()
export async function save(options: DialogOptions = {}): Promise<string | null> {
  return options.defaultPath ?? "download.json";
}

export async function readTextFile(path: string): Promise<string> {
  const file = pickedFiles.get(path);
  if (!file) throw `file not available: ${path}`;
  return file.text();
}

export async function writeTextFile(path: string, contents: string): Promise<void> {
  const url = URL.createObjectURL(new Blob([contents], { type: "application/json" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = path.split(/[\\/]/).pop() || "download.json";
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// --- @tauri-apps/plugin-opener ------------------------------------------------

export async function openUrl(url: string): Promise<void> {
  window.open(url, "_blank", "noopener");
}

// --- @tauri-apps/plugin-updater and plugin-process: updated by Home Assistant -

export type Update = never;

export async function check(): Promise<Update | null> {
  return null;
}

export async function relaunch(): Promise<void> {
  window.location.reload();
}

// --- @tauri-apps/plugin-global-shortcut: no global shortcuts in a browser -----

export async function register(): Promise<void> {}

export async function unregister(): Promise<void> {}

export async function unregisterAll(): Promise<void> {}

export async function isRegistered(): Promise<boolean> {
  return false;
}
