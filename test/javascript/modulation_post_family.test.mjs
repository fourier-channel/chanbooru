// The post family's strips (modulation_post_family.js) show only while the
// address is their own post's: the post view steps client-side and never
// redraws them, so on any other address they would offer one post's parent
// and children under another post. Pure, so it runs under Node's own test
// runner: `npm run test-js`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { isOwnPath } from "../../app/interfaces/modulation/javascript/modulation_post_family.js";

test("isOwnPath: the post's own address, with or without a trailing slash", () => {
  assert.equal(isOwnPath("/posts/42", "42"), true);
  assert.equal(isOwnPath("/posts/42/", "42"), true);
  assert.equal(isOwnPath("/posts/42", 42), true);
});

test("isOwnPath: another post, a longer id sharing the prefix, or a sub-page is not", () => {
  assert.equal(isOwnPath("/posts/43", "42"), false);
  assert.equal(isOwnPath("/posts/420", "42"), false);
  assert.equal(isOwnPath("/posts/4", "42"), false);
  assert.equal(isOwnPath("/posts/42/edit", "42"), false);
  assert.equal(isOwnPath("/posts", "42"), false);
});

test("isOwnPath: no address or no id is not the post's (fail closed)", () => {
  assert.equal(isOwnPath("", "42"), false);
  assert.equal(isOwnPath(undefined, "42"), false);
  assert.equal(isOwnPath("/posts/42", undefined), false);
  assert.equal(isOwnPath("/posts/42", ""), false);
});
