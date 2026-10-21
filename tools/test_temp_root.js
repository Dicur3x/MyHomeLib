"use strict";
// Register only a freshly created empty child of this process's TEMP folder.
// Each test owns its one random directory; existing folders cannot be adopted.
const fs = require("node:fs"), os = require("node:os"), path = require("node:path");
const crypto = require("node:crypto");
module.exports = function registerTestTempRoot(root, prefix) {
  const temporary = fs.realpathSync(os.tmpdir());
  const absolute = fs.realpathSync(root);
  if (fs.lstatSync(root).isSymbolicLink() ||
      path.dirname(absolute).toLowerCase() !== temporary.toLowerCase() ||
      !path.basename(absolute).startsWith(prefix) || fs.readdirSync(absolute).length !== 0)
    throw new Error("Refusing to register an existing or unowned temporary test folder");
  const marker = path.join(absolute, ".homelib-test-owner");
  const owner = crypto.randomUUID();
  fs.writeFileSync(marker, owner, {flag: "wx"});
  process.once("exit", () => {
    if (process.argv.includes("--keep")) { console.log("RETAINED " + absolute); return; }
    try {
      if (!fs.existsSync(absolute)) return;
      if (fs.lstatSync(absolute).isSymbolicLink() ||
          fs.realpathSync(absolute) !== absolute || fs.readFileSync(marker, "utf8") !== owner)
        throw new Error("Temporary test ownership changed; folder left untouched");
      fs.rmSync(absolute, {recursive: true, force: true, maxRetries: 4, retryDelay: 100});
      console.log("CLEANED " + absolute);
    } catch (error) {
      console.error("Could not clean owned test files: " + absolute + ": " + error.message);
      process.exitCode = 1;
    }
  });
};
