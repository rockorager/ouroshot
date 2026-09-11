# Ouro capture MCP contract

The endpoint is `$XDG_RUNTIME_DIR/ouro/capture.mcp.sock`. Frames are JSON-RPC
2.0 objects encoded as compact JSON followed by one newline, at most 4 MiB
(4194304 bytes) including the newline. Each request has a string or integer `id`, echoed
unchanged in its response. Connections support multiple requests. There is no
initialize handshake, streaming, or subscription support.

Every request includes `params._meta` with
`io.modelcontextprotocol/protocolVersion: "2026-07-28"` and
`io.modelcontextprotocol/clientCapabilities: {}`. `server/discover` and
`tools/list` take no other parameters. Unsupported versions return -32022;
unknown methods return -32601; unknown tools or invalid arguments return -32602.

`tools/call` takes `name` (`Screenshot` or `PickColor`) and `arguments`:

```json
{"context":{"app_id":"org.example.Native","parent_window":"","origin":"native","require_confirmation":true,"permission_store_checked":false},"modal":true,"interactive":true}
```

Context is attribution and hints, never authorization. The service checks peer
credentials and requires native consent for every Screenshot. Without a target,
the user drags a region. Screenshot also accepts an optional Wayland output name
as `monitor` and an optional logical rectangle as
`region: {"x":100,"y":60,"width":210,"height":130}`. Region coordinates are
desktop-global without `monitor`, and monitor-relative with it; monitor-relative
regions must fit entirely within the output and are never clipped. `monitor`
alone targets the entire output. A preset requires Enter or a pointer press and
release inside it; Escape or right click cancels. PickColor does not accept
targets and is currently unavailable, returning Failed without opening UI.

A successful response contains `result` with `resultType: "complete"`,
`isError: false`, `structuredContent`, and one `content` item of type `text` whose
`text` is the JSON serialization of `structuredContent`. Screenshot data is
`{"uri":"file:///..."}` for a private PNG; PickColor data is `{"color":[r,g,b]}`
with three finite sRGB components in [0,1]. Execution errors set `isError: true`
and return `{"error":{"code":"Cancelled","message":"Cancelled"}}` as data.
Other error codes are `Denied`, `Busy`, and `Failed`.

EOF or `notifications/cancelled` with `params.requestId` matching the active
capture cancels work before artifact commit. Cancellation notifications have no
`id` and receive no response. Already committed files remain available even if a
client disconnects without reading the result. Only one worker runs at a time.

The installed `share/ouro/mcp/apps/ouroshot.json` descriptor has
`schema_version: 1`, `application_id: "ouroshot"`, the relative runtime endpoint,
and the same tools as `tools/list`. Export it without starting the service with
`ouroshot-service --export-mcp-descriptor`.
