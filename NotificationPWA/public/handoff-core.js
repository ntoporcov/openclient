(function (scope) {
  "use strict";
  const id = (value) => typeof value === "string" && /^[A-Za-z0-9._:-]{1,256}$/.test(value);
  function validate(target) {
    if (!target || target.v !== 1 || !["legacy", "v2"].includes(target.profile)) return null;
    if (typeof target.serverID !== "string" || !target.serverID.includes("|") || target.serverID.length > 2_177 || /[\u0000-\u001f\u007f]/.test(target.serverID)) return null;
    if (!id(target.sessionID) || !id(target.projectID)) return null;
    if (target.directory !== undefined && (typeof target.directory !== "string" || !target.directory.startsWith("/") || target.directory.length > 2_048 || target.directory.includes("\0"))) return null;
    if (target.workspaceID !== undefined && !id(target.workspaceID)) return null;
    return { v: 1, profile: target.profile, serverID: target.serverID, sessionID: target.sessionID, projectID: target.projectID,
      ...(target.directory !== undefined ? { directory: target.directory } : {}), ...(target.workspaceID !== undefined ? { workspaceID: target.workspaceID } : {}) };
  }
  function openClientURL(value) {
    const target = validate(value); if (!target) return "openclient://";
    const pairs = [["profile", target.profile], ["serverID", target.serverID], ["sessionID", target.sessionID], ["projectID", target.projectID]];
    if (target.directory !== undefined) pairs.push(["directory", target.directory]);
    if (target.workspaceID !== undefined) pairs.push(["workspaceID", target.workspaceID]);
    return `openclient://widget/session?${pairs.map(([key, value]) => `${key}=${encodeURIComponent(value)}`).join("&")}`;
  }
  function fragment(value) {
    const target = validate(value); if (!target) return "";
    const bytes = new TextEncoder().encode(JSON.stringify(target));
    let binary = ""; for (const byte of bytes) binary += String.fromCharCode(byte);
    return `#handoff=${btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")}`;
  }
  function fromFragment(hash) {
    if (!hash.startsWith("#handoff=") || hash.length > 6_000) return null;
    try {
      const value = hash.slice(9).replace(/-/g, "+").replace(/_/g, "/");
      const binary = atob(value + "=".repeat((4 - value.length % 4) % 4));
      return validate(JSON.parse(new TextDecoder().decode(Uint8Array.from(binary, (char) => char.charCodeAt(0)))));
    } catch { return null; }
  }
  scope.NotificationHandoff = { validate, openClientURL, fragment, fromFragment };
})(typeof self !== "undefined" ? self : globalThis);
