/*
 * cjh 终端原生层：termios 原始模式 + 按键读取 + 终端尺寸
 * 编译：gcc -shared -fPIC -fstack-protector-all term.c -o libcjterm.so
 */
#define _GNU_SOURCE
#include <termios.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>

static struct termios orig_termios;
static int raw_enabled = 0;

/* 进入原始模式（关闭回显、规范模式、信号） */
void cj_term_raw_on(void) {
    if (raw_enabled) return;
    tcgetattr(STDIN_FILENO, &orig_termios);
    struct termios raw = orig_termios;
    raw.c_lflag &= ~(ICANON | ECHO | ISIG | IEXTEN);
    raw.c_iflag &= ~(IXON | ICRNL | BRKINT | INPCK | ISTRIP);
    raw.c_oflag &= ~(OPOST);
    raw.c_cflag |= (CS8);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 1; /* 100ms 超时，便于轮询 */
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
    raw_enabled = 1;
}

/* 恢复终端 */
void cj_term_raw_off(void) {
    if (!raw_enabled) return;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig_termios);
    raw_enabled = 0;
}

/* 读取一个按键（原始模式），返回字符；无输入返回 -1 */
int cj_term_read_key(void) {
    unsigned char c;
    ssize_t n = read(STDIN_FILENO, &c, 1);
    if (n <= 0) return -1;
    return (int)c;
}

/* 终端尺寸（行, 列）；失败返回 0,0 */
void cj_term_size(int *rows, int *cols) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_row > 0) {
        *rows = (int)ws.ws_row;
        *cols = (int)ws.ws_col;
    } else {
        *rows = 24;
        *cols = 80;
    }
}

/* 是否有输入就绪（非阻塞） */
int cj_term_ready(void) {
    struct timeval tv = {0, 0};
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(STDIN_FILENO, &fds);
    return select(STDIN_FILENO + 1, &fds, NULL, NULL, &tv) > 0;
}
