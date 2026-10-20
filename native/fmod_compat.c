/*
 * glibc 兼容 shim：自实现 fmod / fmodf
 *
 * 背景（AtomGit issue #5 第 2 条）：cjh 的 Linux 产物在 glibc ≥2.38 的机器上构建时，
 * 动态符号表里 fmod / fmodf 会被打上 GLIBC_2.38 版本标记（其余符号最高只到 2.34）。
 * 于是产物拿到 Ubuntu 22.04（glibc 2.35）/ Debian 12（2.36）上，动态加载器直接报
 *   version `GLIBC_2.38' not found
 * 进程连 main 都进不去，用户看到的就是"启动即挂"。
 *
 * 这两个符号唯一来源是仓颉标准库的 libcangjie-std-math.a / libcangjie-std-mathFFI.a，
 * 无法从源码侧改写。因此这里提供功能等价的实现，在链接期无条件注入（见
 * scripts/glibc_compat.sh）：可执行文件自带 fmod/fmodf 定义，就不再从 libm 导入，
 * 版本要求随之消失，最低 glibc 需求回落到 GLIBC_2.34。
 *
 * 算法取自 musl libc（MIT 许可，Copyright © 2005-2020 Rich Felker），
 * 只做与 libm fmod 完全一致的 IEEE-754 语义实现（含 inf / nan / 负零），不调用任何 libm。
 */

#include <stdint.h>

typedef union {
    double f;
    uint64_t i;
} cjh_double_bits;

typedef union {
    float f;
    uint32_t i;
} cjh_float_bits;

/* isnan 用位运算判定，避免为了一个宏去依赖 libm/数学头 */
#define CJH_DBL_IS_NAN(bits)  (((bits) << 1) > 0x7ff0000000000000ULL)
#define CJH_FLT_IS_NAN(bits)  (((bits) << 1) > 0xff000000U)

double fmod(double x, double y)
{
    cjh_double_bits ux = {x}, uy = {y};
    int ex = (int)((ux.i >> 52) & 0x7ffULL);
    int ey = (int)((uy.i >> 52) & 0x7ffULL);
    int sx = (int)(ux.i >> 63);
    uint64_t i;

    /* 复制到局部变量：直接在 ux.i 上做内层循环会被编译器插入 float load/store */
    uint64_t uxi = ux.i;

    /* y == 0、y 是 nan、x 是 inf/nan → nan */
    if ((uy.i << 1) == 0 || CJH_DBL_IS_NAN(uy.i) || ex == 0x7ff) {
        return (x * y) / (x * y);
    }
    /* |x| <= |y|：相等时 x mod y == ±0，否则就是 x 本身 */
    if ((uxi << 1) <= (uy.i << 1)) {
        if ((uxi << 1) == (uy.i << 1)) {
            return 0 * x;
        }
        return x;
    }

    /* 规格化 x、y：把有效数对齐到最高位 */
    if (!ex) {
        for (i = uxi << 12; (i >> 63) == 0; ex--, i <<= 1) {
        }
        uxi <<= -ex + 1;
    } else {
        uxi &= (-1ULL >> 12);
        uxi |= 1ULL << 52;
    }
    if (!ey) {
        for (i = uy.i << 12; (i >> 63) == 0; ey--, i <<= 1) {
        }
        uy.i <<= -ey + 1;
    } else {
        uy.i &= (-1ULL >> 12);
        uy.i |= 1ULL << 52;
    }

    /* 逐位做有余数减法 */
    for (; ex > ey; ex--) {
        i = uxi - uy.i;
        if ((i >> 63) == 0) {
            if (i == 0) {
                return 0 * x;
            }
            uxi = i;
        }
        uxi <<= 1;
    }
    i = uxi - uy.i;
    if ((i >> 63) == 0) {
        if (i == 0) {
            return 0 * x;
        }
        uxi = i;
    }
    for (; (uxi >> 52) == 0; uxi <<= 1, ex--) {
    }

    /* 还原指数并带回符号 */
    if (ex > 0) {
        uxi -= 1ULL << 52;
        uxi |= ((uint64_t)ex << 52);
    } else {
        uxi >>= -ex + 1;
    }
    uxi |= ((uint64_t)sx << 63);
    ux.i = uxi;
    return ux.f;
}

float fmodf(float x, float y)
{
    cjh_float_bits ux = {x}, uy = {y};
    int ex = (int)((ux.i >> 23) & 0xffU);
    int ey = (int)((uy.i >> 23) & 0xffU);
    int sx = (int)(ux.i >> 31);
    uint32_t i;

    /* y == 0、y 是 nan、x 是 inf/nan → nan */
    if ((uy.i << 1) == 0 || CJH_FLT_IS_NAN(uy.i) || ex == 0xff) {
        return (x * y) / (x * y);
    }
    if ((ux.i << 1) <= (uy.i << 1)) {
        if ((ux.i << 1) == (uy.i << 1)) {
            return 0 * x;
        }
        return x;
    }

    /* 规格化 x、y */
    if (!ex) {
        for (i = ux.i << 9; (i >> 31) == 0; ex--, i <<= 1) {
        }
        ux.i <<= -ex + 1;
    } else {
        ux.i &= (0xffffffffU >> 9);
        ux.i |= 1U << 23;
    }
    if (!ey) {
        for (i = uy.i << 9; (i >> 31) == 0; ey--, i <<= 1) {
        }
        uy.i <<= -ey + 1;
    } else {
        uy.i &= (0xffffffffU >> 9);
        uy.i |= 1U << 23;
    }

    /* 逐位做有余数减法 */
    for (; ex > ey; ex--) {
        i = ux.i - uy.i;
        if ((i >> 31) == 0) {
            if (i == 0) {
                return 0 * x;
            }
            ux.i = i;
        }
        ux.i <<= 1;
    }
    i = ux.i - uy.i;
    if ((i >> 31) == 0) {
        if (i == 0) {
            return 0 * x;
        }
        ux.i = i;
    }
    for (; (ux.i >> 23) == 0; ux.i <<= 1, ex--) {
    }

    /* 还原指数并带回符号 */
    if (ex > 0) {
        ux.i -= 1U << 23;
        ux.i |= ((uint32_t)ex << 23);
    } else {
        ux.i >>= -ex + 1;
    }
    ux.i |= ((uint32_t)sx << 31);
    return ux.f;
}
