"use strict";
const { spawn } = require("node:child_process");
const { windows, environment } = require("./paths.cjs");
const env = environment();
delete env.ELECTRON_RUN_AS_NODE;
Object.assign(process.env, env);
require("./runtime.cjs")
  .main()
  .then((executable) => {
    const child = spawn(executable, [windows, ...process.argv.slice(2)], {
      env,
      stdio: "inherit",
      windowsHide: true,
    });
    child.on("error", (error) => {
      console.error(error.message);
      process.exitCode = 1;
    });
    child.on("exit", (code) => {
      process.exitCode = code ?? 1;
    });
  })
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
