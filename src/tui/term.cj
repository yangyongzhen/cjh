package cjh.tui

/**
 * termios FFI 绑定（native/libcjterm.so）
 */
@C
foreign func cj_term_raw_on(): Unit

@C
foreign func cj_term_raw_off(): Unit

@C
foreign func cj_term_read_key(): Int32

@C
foreign func cj_term_size(rows: CPointer<Int32>, cols: CPointer<Int32>): Unit

@C
foreign func cj_term_ready(): Int32

/**
 * 按键事件
 */
public class KeyEvent {
    public let ch: Int32
    public let isEsc: Bool
    public let isEnter: Bool
    public let isCtrlC: Bool
    public let isBackspace: Bool
    public let isArrowUp: Bool
    public let isArrowDown: Bool
    public let isArrowLeft: Bool
    public let isArrowRight: Bool

    public init(ch: Int32) {
        this.ch = ch
        this.isEsc = (ch == 27)
        this.isEnter = (ch == 13 || ch == 10)
        this.isCtrlC = (ch == 3)
        this.isBackspace = (ch == 127 || ch == 8)
        this.isArrowUp = false
        this.isArrowDown = false
        this.isArrowLeft = false
        this.isArrowRight = false
    }
}

/**
 * 终端控制器：原始模式管理 + 按键读取 + 尺寸
 */
public class Term {
    private var rawOn: Bool = false

    public init() {}

    public func enableRaw(): Unit {
        unsafe { cj_term_raw_on() }
        this.rawOn = true
    }

    public func disableRaw(): Unit {
        if (this.rawOn) {
            unsafe { cj_term_raw_off() }
            this.rawOn = false
        }
    }

    public func hasInput(): Bool {
        unsafe { return cj_term_ready() != 0 }
    }

    /**
     * 非阻塞读按键；无输入返回 None
     */
    public func readKey(): Option<KeyEvent> {
        if (!this.hasInput()) {
            return None
        }
        unsafe {
            let ch = cj_term_read_key()
            if (ch < 0) {
                return None
            }
            return Some(KeyEvent(ch))
        }
    }

    public func size(): (Int64, Int64) {
        unsafe {
            let rowsOpt = LibC.malloc<Int32>(count: 1)
            if (let rows <- rowsOpt) {
                let colsOpt = LibC.malloc<Int32>(count: 1)
                if (let cols <- colsOpt) {
                    cj_term_size(rows, cols)
                    let r = Int64(rows.read())
                    let c = Int64(cols.read())
                    LibC.free(rows)
                    LibC.free(cols)
                    return (r, c)
                }
            }
            return (24, 80)
        }
    }
}
