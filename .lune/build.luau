--!strict

local process = require("@lune/process")

local EXEC_OPTIONS: process.ExecOptions = {
	stdio = "inherit",
}

local result = process.exec("darklua", { "process", "src/init.luau", "output/bundled.luau" }, EXEC_OPTIONS)
assert(result.ok, "Failed to bundle!")
process.exec("lune", { "build", "output/bundled.luau", "-o", "output/transfer.exe" }, EXEC_OPTIONS)
