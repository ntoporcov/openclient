import path from "node:path";

const BIDI_CONTROLS = /[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/gu;
const TEXT_CONTROLS = /[\u0000-\u001f\u007f-\u009f]/gu;

export function cleanDisplayText(value, maxCharacters) {
  if (typeof value !== "string") return undefined;
  const clean = value.replace(TEXT_CONTROLS, " ").replace(BIDI_CONTROLS, "").replace(/\s+/gu, " ").trim();
  if (!clean) return undefined;
  return Array.from(clean).slice(0, maxCharacters).join("");
}

function basename(value) {
  const clean = cleanDisplayText(value, 2_048);
  if (!clean || !clean.startsWith("/")) return undefined;
  const name = path.posix.basename(clean);
  return name === "/" || name === "." ? undefined : cleanDisplayText(name, 80);
}

export function displayContextForSession(session, projects = new Map()) {
  const project = projects.get(session?.projectID);
  const projectName = cleanDisplayText(project?.name, 80) || basename(project?.worktree) || basename(session?.directory);
  const sessionTitle = cleanDisplayText(session?.title, 120);
  const result = { ...(projectName ? { projectName } : {}), ...(sessionTitle ? { sessionTitle } : {}) };
  return Object.keys(result).length ? result : undefined;
}

export function validateDisplayContext(value) {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "object" || Array.isArray(value)) throw new TypeError("Invalid display context.");
  if (Object.keys(value).some((key) => !["projectName", "sessionTitle"].includes(key))) throw new TypeError("Invalid display context fields.");
  const result = {};
  for (const [key, limit] of [["projectName", 80], ["sessionTitle", 120]]) {
    const field = value[key];
    if (field === undefined || field === null) continue;
    if (typeof field !== "string") throw new TypeError("Invalid display context values.");
    const clean = cleanDisplayText(field, limit);
    if (clean) result[key] = clean;
  }
  return Object.keys(result).length ? result : undefined;
}
