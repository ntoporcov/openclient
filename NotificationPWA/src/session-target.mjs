const IDENTIFIER = /^[A-Za-z0-9._:-]{1,256}$/;

function identifier(value, name) {
  if (typeof value !== "string" || !IDENTIFIER.test(value)) throw new TypeError(`${name} is invalid.`);
  return value;
}

function optionalLocationValue(session, key) {
  const direct = session?.[key];
  if (typeof direct === "string" && direct) return direct;
  const location = session?.location;
  if (location && typeof location === "object" && typeof location[key] === "string" && location[key]) return location[key];
  return undefined;
}

export function canonicalSessionTarget(session) {
  if (!session || typeof session !== "object") throw new TypeError("Session metadata is missing.");
  const target = {
    sessionID: identifier(session.id, "sessionID"),
    projectID: identifier(optionalLocationValue(session, "projectID"), "projectID")
  };
  const directory = optionalLocationValue(session, "directory");
  const workspaceID = optionalLocationValue(session, "workspaceID");
  if (directory !== undefined) {
    if (directory.length > 2_048 || !directory.startsWith("/") || directory.includes("\0")) throw new TypeError("directory is invalid.");
    target.directory = directory;
  }
  if (workspaceID !== undefined) target.workspaceID = identifier(workspaceID, "workspaceID");
  return target;
}

export function validateDestination(value, { allowDisabled = true } = {}) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new TypeError("Destination is invalid.");
  const optIn = value.optIn === true;
  if (typeof value.optIn !== "boolean") throw new TypeError("optIn must be a boolean.");
  if (value.profile !== "legacy" && value.profile !== "v2") throw new TypeError("profile must be legacy or v2.");
  if (typeof value.username !== "string" || value.username.length > 128 || /[\u0000-\u001f\u007f]/.test(value.username)) throw new TypeError("username is invalid.");
  if (typeof value.delaySeconds !== "number" || !Number.isInteger(value.delaySeconds) || value.delaySeconds < 5 || value.delaySeconds > 120) throw new TypeError("delaySeconds must be between 5 and 120.");
  if (typeof value.baseURL !== "string" || value.baseURL.length > 2_048 || /[\u0000-\u001f\u007f]/.test(value.baseURL)) throw new TypeError("baseURL is invalid.");
  if (value.baseURL === "") {
    if (optIn || !allowDisabled) throw new TypeError("baseURL is required before opting in.");
  } else {
    let parsed;
    try { parsed = new URL(value.baseURL); } catch { throw new TypeError("baseURL must be a valid HTTP or HTTPS URL."); }
    if (!["http:", "https:"].includes(parsed.protocol) || parsed.username || parsed.password || parsed.search || parsed.hash || /[?#]/.test(value.baseURL)) {
      throw new TypeError("baseURL must be HTTP or HTTPS without credentials, query, or fragment.");
    }
  }
  return { optIn, baseURL: value.baseURL, username: value.username, profile: value.profile, delaySeconds: value.delaySeconds };
}

export function defaultDestination() {
  return { optIn: false, baseURL: "", username: "opencode", profile: "legacy", delaySeconds: 15 };
}

export function buildHandoffTarget(destination, canonical) {
  const cleanDestination = validateDestination(destination, { allowDisabled: false });
  if (!cleanDestination.optIn) throw new TypeError("Destination is not enabled.");
  const cleanTarget = canonicalSessionTarget({
    id: canonical?.sessionID,
    projectID: canonical?.projectID,
    directory: canonical?.directory,
    workspaceID: canonical?.workspaceID
  });
  const serverID = `${cleanDestination.baseURL.trim().toLowerCase()}|${cleanDestination.username.trim().toLowerCase()}`;
  const result = { v: 1, profile: cleanDestination.profile, serverID, sessionID: cleanTarget.sessionID, projectID: cleanTarget.projectID };
  if (cleanTarget.directory && !(cleanDestination.profile === "legacy" && cleanTarget.directory === "/")) result.directory = cleanTarget.directory;
  if (cleanTarget.workspaceID) result.workspaceID = cleanTarget.workspaceID;
  return result;
}

export function buildOpenClientURL(target) {
  if (!target || target.v !== 1 || !["legacy", "v2"].includes(target.profile)) throw new TypeError("Handoff target is invalid.");
  if (typeof target.serverID !== "string" || !target.serverID.includes("|") || target.serverID.length > 2_177 || /[\u0000-\u001f\u007f]/.test(target.serverID)) throw new TypeError("serverID is invalid.");
  for (const key of ["sessionID", "projectID"]) identifier(target[key], key);
  const pairs = [
    ["profile", target.profile], ["serverID", target.serverID], ["sessionID", target.sessionID], ["projectID", target.projectID]
  ];
  if (target.directory !== undefined) {
    if (typeof target.directory !== "string" || !target.directory.startsWith("/") || target.directory.length > 2_048) throw new TypeError("directory is invalid.");
    pairs.push(["directory", target.directory]);
  }
  if (target.workspaceID !== undefined) pairs.push(["workspaceID", identifier(target.workspaceID, "workspaceID")]);
  return `openclient://widget/session?${pairs.map(([key, value]) => `${key}=${encodeURIComponent(value)}`).join("&")}`;
}
