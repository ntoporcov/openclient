import assert from "node:assert/strict";
import test from "node:test";
import { buildHandoffTarget, buildOpenClientURL, canonicalSessionTarget, defaultDestination, validateDestination } from "../src/session-target.mjs";

test("destination preserves exact URL spelling and derives native recentServerID", () => {
  const destination = validateDestination({ optIn: true, baseURL: "HTTP://Mac.Local:4096/", username: " OpenCode ", profile: "legacy", delaySeconds: 15 });
  assert.equal(destination.baseURL, "HTTP://Mac.Local:4096/");
  const target = buildHandoffTarget(destination, canonicalSessionTarget({ id: "ses_1", projectID: "project_1", directory: "/", workspaceID: "work_1" }));
  assert.deepEqual(target, { v: 1, profile: "legacy", serverID: "http://mac.local:4096/|opencode", sessionID: "ses_1", projectID: "project_1", workspaceID: "work_1" });
});

test("v2 preserves root directory and route uses percent encoding rather than plus", () => {
  const target = buildHandoffTarget({ optIn: true, baseURL: "https://host/path/", username: "user name", profile: "v2", delaySeconds: 20 }, { sessionID: "ses_1", projectID: "project_1", directory: "/", workspaceID: "work_1" });
  const route = buildOpenClientURL(target);
  assert.equal(route, "openclient://widget/session?profile=v2&serverID=https%3A%2F%2Fhost%2Fpath%2F%7Cuser%20name&sessionID=ses_1&projectID=project_1&directory=%2F&workspaceID=work_1");
  assert.ok(!route.includes("+"));
});

test("invalid destinations and noncanonical session metadata are rejected", () => {
  assert.throws(() => validateDestination({ ...defaultDestination(), optIn: true }), /baseURL/);
  assert.throws(() => validateDestination({ ...defaultDestination(), baseURL: "https://user:pass@example.com" }), /credentials/);
  assert.throws(() => validateDestination({ ...defaultDestination(), profile: "automatic" }), /profile/);
  assert.throws(() => canonicalSessionTarget({ id: "ses_1", directory: "/tmp" }), /projectID/);
  assert.doesNotThrow(() => validateDestination({ ...defaultDestination(), baseURL: "http://localhost:4096", username: "" }));
  assert.throws(() => validateDestination({ ...defaultDestination(), baseURL: "http://localhost:4096\n" }), /baseURL/);
});
