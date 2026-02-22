--!strict

local process = zune.process

local PROCESS_OPTIONS: ProcessOptions = {
	stdout = "inherit",
}

process.run("zune", { "bundle", "src/init.luau", "src/**/*.luau", "--out=output/transfer.exe" }, PROCESS_OPTIONS)
