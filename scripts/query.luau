--!strict

local sqlite = zune.sqlite
local process = zune.process

local db = sqlite.open("./output/transfers.db")

local query = process.args[2]
print(db:query(query):all())

db:close()
