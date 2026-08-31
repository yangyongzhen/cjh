# 坏代理：OpenAI 兼容流式响应，发 2 个 content 帧后停滞
# （keep-alive 不关连接、无 [DONE]、无 finish_reason:stop、不再发数据）
import socket, time, sys
port = int(sys.argv[1])
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
conn, _ = srv.accept()
try:
    conn.recv(65536)
    body = (
        'data: {"choices":[{"delta":{"content":"第一段内容"},"finish_reason":null}]}\n\n'
        'data: {"choices":[{"delta":{"content":"第二段内容"},"finish_reason":null}]}\n\n'
    )
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
    chunk = hex(len(body.encode()))[2:] + "\r\n" + body + "\r\n"
    conn.sendall(chunk.encode())
    print("stalled: sent content, no [DONE], no finish_reason", flush=True)
    time.sleep(300)
except Exception as e:
    print("proxy err:", e, flush=True)
