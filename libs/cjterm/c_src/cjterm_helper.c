/**
 * cjterm C 辅助库：绕过 Cangjie FFI 对变参 ioctl 的支持问题
 * 提供非变参的终端尺寸查询函数
 */
#include <sys/ioctl.h>
#include <unistd.h>

/**
 * 查询终端尺寸（非变参封装）
 * 返回值：0=成功，-1=失败
 */
int cj_get_winsize(int fd, unsigned short* rows, unsigned short* cols) {
    struct winsize ws;
    ws.ws_row = 0;
    ws.ws_col = 0;
    int r = ioctl(fd, TIOCGWINSZ, &ws);
    if (r == 0) {
        *rows = ws.ws_row;
        *cols = ws.ws_col;
    }
    return r;
}
