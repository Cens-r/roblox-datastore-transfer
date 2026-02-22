--!strict

local fs = zune.fs
local process = zune.process
local serde = zune.serde

local ENV_FILE_PATH: string = ".env"

type Environment = { API_KEY: string, [string]: unknown }

local exists = fs.stat(ENV_FILE_PATH).kind == "file"
local env = exists and serde.toml.decode(fs.readFile(ENV_FILE_PATH))

return setmetatable((env or {}) :: Environment, {
	__index = process.env,
	__newindex = process.env,
})
