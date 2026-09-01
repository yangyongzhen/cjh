# 坏代理：发内容帧后持续发 keep-alive 空帧（不关连接、无 [DONE]/finish_reason）
# 精确模拟 taotoken.net 行为——read 一直有数据（空帧）→ parser 预算被绕过
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
    # 持续 keep-alive 空帧（每 1s 一个空 data 帧）——模拟代理挂起不结束
    n = 0
    while n < 120:
        ka = "data: {}\n\n"
        kbytes = ka.encode()
        conn.sendall((hex(len(kbytes))[2:] + "\r\n" + ka + "\r\n").encode())
        time.sleep(1)
        n += 1
except Exception as e:
    print("proxy err:", e, flush=True)
