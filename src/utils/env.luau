--!strict

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local ENV_FILE_PATH: string = ".env"

type Environment = { API_KEY: string }

local env = serde.decode("toml", fs.readFile(ENV_FILE_PATH))
return setmetatable(env :: Environment, {
	__index = process.env,
	__newindex = process.env,
})
