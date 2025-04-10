-- scan only first max_bytes of the request body, assuming the interesting fields are there
-- optional, has no effect to memory usage
local max_bytes = 16384
local payload_names = "text image"
local payload_name

ngx.req.read_body()
local data = ngx.req.get_body_data(max_bytes)

local names = data:gmatch(' name="([^"]+)"')

for name in names do
    ngx.log(ngx.DEBUG, "Processing name: " .. name)
    if payload_names:match(name) then
        payload_name = name
        break
    end
end

if not payload_name or payload_name == "" then
    ngx.log(ngx.DEBUG, "Payload name is missing or empty. Cannot find any of: [" .. payload_names .. "]. Fall back to default.")
    payload_name = "default"
end

ngx.var.payload_name = payload_name
ngx.log(ngx.INFO, "Payload name: " .. ngx.var.payload_name)
