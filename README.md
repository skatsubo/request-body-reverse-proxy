# Reverse proxy by request body - comparison of HAProxy, Nginx, OpenResty

<!-- TOC -->

- [About](#about)
- [Reverse proxies](#reverse-proxies)
- [Motivation: Immich ML routing](#motivation-immich-ml-routing)
- [Testing](#testing)
- [Comparison](#comparison)
- [Links](#links)

<!-- /TOC -->

## About

Reverse proxies forwarding requests based on the request body. Implemented with: HAProxy, Nginx, OpenResty.

For the comparison and limitations see [Comparison](#comparison) below.

## Reverse proxies

So far I've experimented with the following proxies:

- `haproxy1`: pure HAProxy (simple and sweet, recommended for the Immich ML use case)
- `nginx1`: pure Nginx
- `openresty1`: OpenResty and the `lua-nginx-module` for buffered processing using `get_body_data()`
- `openresty2`: OpenResty and the `lua-resty-upload` for streaming processing, with large `chunk_size`
- `openresty3`: OpenResty and the `lua-resty-upload` for streaming processing, with small `chunk_size` (thus causing buffering to a temporary file on disk)

See [compose.yaml](./compose.yaml) for the services definitions.

## Motivation: Immich ML routing

Motivation/case: routing [Immich](https://github.com/immich-app/immich/) machine learning requests to different ML servers depending on the type of the query in the request body. See details in https://github.com/immich-app/immich/discussions/17045.

At the moment, Immich server specifies the query/task type in the request body. Example smart search POST request from Immich server to Immich ML (captured using `docker run --rm -ti --net container:"immich-ml" nicolaka/netshoodshoot ngrep -dany -Wbyline '' 'port 3003'`):

```
POST /predict HTTP/1.1
host: ml:3003
connection: keep-alive
content-type: multipart/form-data; boundary=----formdata-undici-043847285935
accept: */*
accept-language: *
sec-fetch-mode: cors
accept-encoding: gzip, deflate
content-length: 265

------formdata-undici-043847285935
Content-Disposition: form-data; name="entries"

{"clip":{"textual":{"modelName":"ViT-B-32__openai"}}}

------formdata-undici-043847285935
Content-Disposition: form-data; name="text"

cat

------formdata-undici-043847285935--
```

Therefore, unless it is changed in the code to be path/URI-based, we have to perform the POST request body inspection to determine the type of the query and choose a backend/target accordingly.

There is no _simple_ config/solution with request routing based on the body inspection. (Otherwise let me know). So I implemented a few routers based on HAProxy, Nginx, OpenResty.

## Testing

Minimal curl to create a multipart/form-data request for testing:

```sh
# possible ROUTER values: haproxy1, nginx1, openresty1, openresty2, openresty3

# text
ROUTER=haproxy1
docker compose exec client curl -F 'entries={"clip":{"textual":{"modelName":"ViT-B-32__openai"}}}' -F 'text=cat' http://$ROUTER/predict

# image from file, limit throughput to 1000 kB/s
docker compose exec client sh
truncate -s 10M testfile
ROUTER=haproxy1
curl -F 'entries={"clip":{"textual":{"modelName":"ViT-B-32__openai"}}}' -F 'image=@testfile' --limit-rate 1000k --progress-bar http://$ROUTER/predict | cat
```

## Comparison

This section is work in progress.

| name       | description       | body scan mode  | config                            | memory for 1 request | memory baseline | disk  |
| :--------- | :---------------- | --------------- | --------------------------------- | :------------------- | --------------- | :---- |
| haproxy1   | HAProxy           | partial         | default tune.bufsize = 16 KiB     | 16 k                 | 70 m            | -     |
| nginx1     | Nginx             | full            |                                   | body                 | 8 m             | -     |
| openresty1 | lua get_body_data | full or partial |                                   | body                 | 13 m            | -     |
| openresty2 | lua-resty-upload  | full            | chunk_size = client_max_body_size | body + 2\*chunk ?    | 13 m            | -     |
| openresty3 | lua-resty-upload  | full            | default small chunk_size          | body + 2\*chunk ?    | 13 m            | spool |

See the following subsections for details, caveats, limitations...

### RAM or disk?

Current assumption: requests are either processed in-memory (without spooling to disk), or dropped.

Exception: `openresty3` configured to show how small chunk size in lua-resty-upload causes buffering to disk.

### Max body size

Maximum body size is set to an arbitrary value of 32MB.

### RAM usage

Performance-wise, memory is the main concern, as we read the entire request body buffered into RAM. Although it can be spooled to disk, I'd rather avoid touching disk. Anyway, buffering is required for the dynamic backend selection, so we have to read the request body (in theory, some custom streaming can be implemented with Lua to keep only small chunk of the request body in memory).

In the comparison table above, memory usage is for proxying a 10 MB image file. Values captured with docker stats:

```sh
watch -n1 "docker stats --format='{{ json .Container }} Mem usage/total: {{json .MemUsage}} Net rx/tx: {{json .NetIO}}' --no-stream haproxy1 nginx1 openresty1 openresty2 openresty3"
```

### Partial request body scan

Partial scan (checking only the first 16K bytes) is totally fine for this case of Immich ML proxying because the interesting data is at the beginning of the request body. Other use cases may require large buffer or full body scan.

HAProxy log: `... "POST /predict HTTP/1.1" req_body_size=10486128 req_body_len=15056`

### Content matching criteria

Possible content matching criteria depend on the chosen platform/stack.

- HAProxy: regex, substring, ...
- Nginx: regex, substring, ...
- OpenResty/Lua: virtually anything with lua. Additionally, `lua-resty-upload` allows for precise body inspection without re-implementing it in lua.

### Buffering to a temporary file - Nginx/OpenResty

Buffering to a temporary file (spool to disk) happens in these 2 cases:

- when `request body size > client_body_buffer_size`

- when `request body size > chunk_size (buffer_size)` and `preserve_body = true`. Because `lua-resty-upload` calls [ngx.req.init_body](https://github.com/openresty/lua-nginx-module?tab=readme-ov-file#ngxreqinit_body) which behaves in the following way:

> If the buffer_size argument is specified, then its value will be used for the size of the memory buffer for body writing with ngx.req.append_body. If the argument is omitted, then the value specified by the standard client_body_buffer_size directive will be used instead.
> When the data can no longer be hold in the memory buffer for the request body, then the data will be flushed onto a temporary file just like the standard request body reader in the Nginx core.

### Errors with lua-resty-upload (OpenResty)

When a request gets buffered to a temp file by `lua-resty-upload` I got `alert sendfile() failed (9: Bad file descriptor)`, but did not investigate further. Log lines:

```
a client request body is buffered to a temporary file
an upstream response is buffered to a temporary file while reading upstream
alert sendfile() failed (9: Bad file descriptor) while sending request to upstream
```

Related: https://github.com/openresty/openresty/issues/802

## Links

HAProxy

- https://www.haproxy.com/documentation/haproxy-configuration-manual/latest/#4.2-option%20http-buffer-request
- https://www.haproxy.com/documentation/haproxy-configuration-manual/latest/#tune.bufsize
- https://stackoverflow.com/questions/23259843/how-to-route-traffic-reverse-proxy-with-haproxy-based-on-request-body
- https://gist.github.com/lazywithclass/f8615742e876237a051eb64476fd71dd
- https://medium.com/@leen15/how-to-handle-haproxy-log-format-33daa87ce7f1
- https://www.haproxy.com/documentation/haproxy-configuration-manual/latest/#8.2.6

Nginx

- https://nginx.org/en/docs/http/ngx_http_core_module.html#client_body_buffer_size
- https://nginx.org/en/docs/http/ngx_http_core_module.html#client_body_in_single_buffer
- https://nginx.org/en/docs/http/ngx_http_core_module.html#client_max_body_size
- https://www.f5.com/company/blog/nginx/deploying-nginx-plus-as-an-api-gateway-part-2-protecting-backend-services
- https://nginx.org/en/docs/http/ngx_http_mirror_module.html
- https://dev.to/danielkun/nginx-everything-about-proxypass-2ona#better-logging-format-for-proxypass
- https://serverfault.com/questions/453106/set-a-default-variable-in-nginx-with-set
- https://stackoverflow.com/questions/21866477/nginx-use-environment-variables
- https://docs.nginx.com/nginx/admin-guide/monitoring/debugging/
- https://nginx.org/en/docs/debugging_log.html

OpenResty

- https://github.com/openresty/lua-resty-upload
- https://github.com/openresty/lua-nginx-module?tab=readme-ov-file#ngxreqget_body_data
- https://github.com/openresty/lua-nginx-module?tab=readme-ov-file#ngxreqinit_body
- https://github.com/adrianbrad/nginx-request-body-reverse-proxy
