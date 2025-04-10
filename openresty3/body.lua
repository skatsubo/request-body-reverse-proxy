local upload = require "resty.upload"

local payload_names = "text image"
local payload_name

-- preserve_body is required to send the request body to upstream
local preserve_body = true

-- default value is 4096. It causes "a client request body is buffered to a temporary file" when the request body is bigger than 4 KiB
local chunk_size = 4096

local upload_handler = upload:new(chunk_size, nil, preserve_body)

while true do
    local typ, res, err = upload_handler:read()
    if not typ then
        ngx.status = ngx.HTTP_BAD_REQUEST
        ngx.say("Failed to parse multipart form data: ", err)
        ngx.exit(ngx.status)
    end

    if typ == "header" then
        -- res[1]   Content-Disposition
        -- res[2]   form-data; name="text"
        -- res[3]   Content-Disposition: form-data; name="text"
        local key, val = res[1], res[2]
        if key:lower() == 'content-disposition' then
            local name = val:match(' name="([^"]+)"')
            ngx.log(ngx.DEBUG, "Processing name: " .. name)
            if name then
                if payload_names:match(name) then
                    payload_name = name
                    ngx.log(ngx.DEBUG, "Set payload_name: " .. payload_name)
                    -- do not break, otherwise remaining content data will be lost
                    -- break
                end
            end
        end
    elseif typ == "eof" then
        break
    end
end

if not payload_name or payload_name == "" then
    ngx.log(ngx.DEBUG, "Payload name is missing or empty. Cannot find any of: [" .. payload_names .. "]. Fall back to default.")
    payload_name = "default"
end

ngx.var.payload_name = payload_name
ngx.log(ngx.INFO, "Payload name: " .. ngx.var.payload_name)
