param([int]$Port)
$ErrorActionPreference = 'Stop'
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Output 'READY'
try {
    $context = $listener.GetContext()
    $reader = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding)
    try { $null = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $payload = @'
data: {"choices":[{"delta":{"content":"fixture"},"finish_reason":null}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"query_player","arguments":"{}"}}]},"finish_reason":null}]}

data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]

'@
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $context.Response.StatusCode = 200
    $context.Response.ContentType = 'text/event-stream'
    $context.Response.ContentLength64 = $bytes.Length
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.Close()
} finally {
    $listener.Close()
}
