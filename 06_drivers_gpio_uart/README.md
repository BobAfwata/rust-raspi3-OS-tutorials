# Tutorial 06 - Drivers: GPIO and UART

## tl;dr

Now that we enabled safe globals in the previous tutorial, the infrastructure is
laid for adding the first real device drivers. We throw out the magic QEMU
console and use a real UART now. Like real though embedded people do!

- A `DeviceDriver` trait is added for abstracting BSP driver implementations
  from kernel code.
- Introducing the `GPIO` driver, which pinmuxes the RPi's Mini UART.
- Most importantly, the `MiniUart` driver: It implements the `Console` traits
  and is from now on used as the system console output.
    - **Be sure to check it out by booting this kernel from the SD card and
      watching the output!**
- `memory_map.rs` contains the RPi3 device's MMIO addresses.


## Diff to previous
```diff

diff -uNr 05_safe_globals/Cargo.toml 06_drivers_gpio_uart/Cargo.toml
--- 05_safe_globals/Cargo.toml
+++ 06_drivers_gpio_uart/Cargo.toml
@@ -10,10 +10,11 @@
 # The features section is used to select the target board.
 [features]
 default = []
-bsp_rpi3 = ["cortex-a"]
+bsp_rpi3 = ["cortex-a", "register"]

 [dependencies]
 r0 = "0.2.*"

 # Optional dependencies
 cortex-a = { version = "2.*", optional = true }
+register = { version = "0.3.*", optional = true }

diff -uNr 05_safe_globals/src/bsp/rpi3/driver/gpio.rs 06_drivers_gpio_uart/src/bsp/rpi3/driver/gpio.rs
--- 05_safe_globals/src/bsp/rpi3/driver/gpio.rs
+++ 06_drivers_gpio_uart/src/bsp/rpi3/driver/gpio.rs
@@ -0,0 +1,164 @@
+// SPDX-License-Identifier: MIT
+//
+// Copyright (c) 2018-2019 Andre Richter <andre.o.richter@gmail.com>
+
+//! GPIO driver.
+
+use super::super::NullLock;
+use crate::interface;
+use core::ops;
+use cortex_a::asm;
+use register::{mmio::ReadWrite, register_bitfields};
+
+// GPIO registers.
+//
+// Descriptions taken from
+// https://github.com/raspberrypi/documentation/files/1888662/BCM2837-ARM-Peripherals.-.Revised.-.V2-1.pdf
+register_bitfields! {
+    u32,
+
+    /// GPIO Function Select 1
+    GPFSEL1 [
+        /// Pin 15
+        FSEL15 OFFSET(15) NUMBITS(3) [
+            Input = 0b000,
+            Output = 0b001,
+            RXD0 = 0b100, // UART0     - Alternate function 0
+            RXD1 = 0b010  // Mini UART - Alternate function 5
+
+        ],
+
+        /// Pin 14
+        FSEL14 OFFSET(12) NUMBITS(3) [
+            Input = 0b000,
+            Output = 0b001,
+            TXD0 = 0b100, // UART0     - Alternate function 0
+            TXD1 = 0b010  // Mini UART - Alternate function 5
+        ]
+    ],
+
+    /// GPIO Pull-up/down Clock Register 0
+    GPPUDCLK0 [
+        /// Pin 15
+        PUDCLK15 OFFSET(15) NUMBITS(1) [
+            NoEffect = 0,
+            AssertClock = 1
+        ],
+
+        /// Pin 14
+        PUDCLK14 OFFSET(14) NUMBITS(1) [
+            NoEffect = 0,
+            AssertClock = 1
+        ]
+    ]
+}
+
+#[allow(non_snake_case)]
+#[repr(C)]
+pub struct RegisterBlock {
+    pub GPFSEL0: ReadWrite<u32>,                        // 0x00
+    pub GPFSEL1: ReadWrite<u32, GPFSEL1::Register>,     // 0x04
+    pub GPFSEL2: ReadWrite<u32>,                        // 0x08
+    pub GPFSEL3: ReadWrite<u32>,                        // 0x0C
+    pub GPFSEL4: ReadWrite<u32>,                        // 0x10
+    pub GPFSEL5: ReadWrite<u32>,                        // 0x14
+    __reserved_0: u32,                                  // 0x18
+    GPSET0: ReadWrite<u32>,                             // 0x1C
+    GPSET1: ReadWrite<u32>,                             // 0x20
+    __reserved_1: u32,                                  //
+    GPCLR0: ReadWrite<u32>,                             // 0x28
+    __reserved_2: [u32; 2],                             //
+    GPLEV0: ReadWrite<u32>,                             // 0x34
+    GPLEV1: ReadWrite<u32>,                             // 0x38
+    __reserved_3: u32,                                  //
+    GPEDS0: ReadWrite<u32>,                             // 0x40
+    GPEDS1: ReadWrite<u32>,                             // 0x44
+    __reserved_4: [u32; 7],                             //
+    GPHEN0: ReadWrite<u32>,                             // 0x64
+    GPHEN1: ReadWrite<u32>,                             // 0x68
+    __reserved_5: [u32; 10],                            //
+    pub GPPUD: ReadWrite<u32>,                          // 0x94
+    pub GPPUDCLK0: ReadWrite<u32, GPPUDCLK0::Register>, // 0x98
+    pub GPPUDCLK1: ReadWrite<u32>,                      // 0x9C
+}
+
+/// The driver's private data.
+struct GPIOInner {
+    base_addr: usize,
+}
+
+/// Deref to RegisterBlock.
+impl ops::Deref for GPIOInner {
+    type Target = RegisterBlock;
+
+    fn deref(&self) -> &Self::Target {
+        unsafe { &*self.ptr() }
+    }
+}
+
+impl GPIOInner {
+    const fn new(base_addr: usize) -> GPIOInner {
+        GPIOInner { base_addr }
+    }
+
+    /// Return a pointer to the register block.
+    fn ptr(&self) -> *const RegisterBlock {
+        self.base_addr as *const _
+    }
+
+    /// Map Mini UART as standard output.
+    ///
+    /// TX to pin 14
+    /// RX to pin 15
+    fn map_mini_uart(&mut self) {
+        // Map to pins.
+        self.GPFSEL1
+            .modify(GPFSEL1::FSEL14::TXD1 + GPFSEL1::FSEL15::RXD1);
+
+        // Enable pins 14 and 15.
+        self.GPPUD.set(0);
+        for _ in 0..150 {
+            asm::nop();
+        }
+
+        self.GPPUDCLK0
+            .write(GPPUDCLK0::PUDCLK14::AssertClock + GPPUDCLK0::PUDCLK15::AssertClock);
+        for _ in 0..150 {
+            asm::nop();
+        }
+
+        self.GPPUDCLK0.set(0);
+    }
+}
+
+////////////////////////////////////////////////////////////////////////////////
+// OS interface implementations
+////////////////////////////////////////////////////////////////////////////////
+
+/// The driver's public data.
+pub struct GPIO {
+    inner: NullLock<GPIOInner>,
+}
+
+impl GPIO {
+    pub const unsafe fn new(base_addr: usize) -> GPIO {
+        GPIO {
+            inner: NullLock::new(GPIOInner::new(base_addr)),
+        }
+    }
+}
+
+impl interface::driver::DeviceDriver for GPIO {
+    fn compatible(&self) -> &str {
+        "GPIO"
+    }
+
+    fn init(&self) -> interface::driver::Result {
+        use interface::sync::Mutex;
+
+        let mut r = &self.inner;
+        r.lock(|i| i.map_mini_uart());
+
+        Ok(())
+    }
+}

diff -uNr 05_safe_globals/src/bsp/rpi3/driver/mini_uart.rs 06_drivers_gpio_uart/src/bsp/rpi3/driver/mini_uart.rs
--- 05_safe_globals/src/bsp/rpi3/driver/mini_uart.rs
+++ 06_drivers_gpio_uart/src/bsp/rpi3/driver/mini_uart.rs
@@ -0,0 +1,263 @@
+// SPDX-License-Identifier: MIT
+//
+// Copyright (c) 2018-2019 Andre Richter <andre.o.richter@gmail.com>
+
+//! Mini UART driver.
+
+use super::super::NullLock;
+use crate::interface;
+use core::{fmt, ops};
+use cortex_a::asm;
+use register::{mmio::*, register_bitfields};
+
+// Mini UART registers.
+//
+// Descriptions taken from
+// https://github.com/raspberrypi/documentation/files/1888662/BCM2837-ARM-Peripherals.-.Revised.-.V2-1.pdf
+register_bitfields! {
+    u32,
+
+    /// Auxiliary enables
+    AUX_ENABLES [
+        /// If set the mini UART is enabled. The UART will immediately
+        /// start receiving data, especially if the UART1_RX line is
+        /// low.
+        /// If clear the mini UART is disabled. That also disables any
+        /// mini UART register access
+        MINI_UART_ENABLE OFFSET(0) NUMBITS(1) []
+    ],
+
+    /// Mini Uart Interrupt Identify
+    AUX_MU_IIR [
+        /// Writing with bit 1 set will clear the receive FIFO
+        /// Writing with bit 2 set will clear the transmit FIFO
+        FIFO_CLEAR OFFSET(1) NUMBITS(2) [
+            Rx = 0b01,
+            Tx = 0b10,
+            All = 0b11
+        ]
+    ],
+
+    /// Mini Uart Line Control
+    AUX_MU_LCR [
+        /// Mode the UART works in
+        DATA_SIZE OFFSET(0) NUMBITS(2) [
+            SevenBit = 0b00,
+            EightBit = 0b11
+        ]
+    ],
+
+    /// Mini Uart Line Status
+    AUX_MU_LSR [
+        /// This bit is set if the transmit FIFO is empty and the transmitter is
+        /// idle. (Finished shifting out the last bit).
+        TX_IDLE    OFFSET(6) NUMBITS(1) [],
+
+        /// This bit is set if the transmit FIFO can accept at least
+        /// one byte.
+        TX_EMPTY   OFFSET(5) NUMBITS(1) [],
+
+        /// This bit is set if the receive FIFO holds at least 1
+        /// symbol.
+        DATA_READY OFFSET(0) NUMBITS(1) []
+    ],
+
+    /// Mini Uart Extra Control
+    AUX_MU_CNTL [
+        /// If this bit is set the mini UART transmitter is enabled.
+        /// If this bit is clear the mini UART transmitter is disabled.
+        TX_EN OFFSET(1) NUMBITS(1) [
+            Disabled = 0,
+            Enabled = 1
+        ],
+
+        /// If this bit is set the mini UART receiver is enabled.
+        /// If this bit is clear the mini UART receiver is disabled.
+        RX_EN OFFSET(0) NUMBITS(1) [
+            Disabled = 0,
+            Enabled = 1
+        ]
+    ],
+
+    /// Mini Uart Baudrate
+    AUX_MU_BAUD [
+        /// Mini UART baudrate counter
+        RATE OFFSET(0) NUMBITS(16) []
+    ]
+}
+
+#[allow(non_snake_case)]
+#[repr(C)]
+pub struct RegisterBlock {
+    __reserved_0: u32,                                  // 0x00
+    AUX_ENABLES: ReadWrite<u32, AUX_ENABLES::Register>, // 0x04
+    __reserved_1: [u32; 14],                            // 0x08
+    AUX_MU_IO: ReadWrite<u32>,                          // 0x40 - Mini Uart I/O Data
+    AUX_MU_IER: WriteOnly<u32>,                         // 0x44 - Mini Uart Interrupt Enable
+    AUX_MU_IIR: WriteOnly<u32, AUX_MU_IIR::Register>,   // 0x48
+    AUX_MU_LCR: WriteOnly<u32, AUX_MU_LCR::Register>,   // 0x4C
+    AUX_MU_MCR: WriteOnly<u32>,                         // 0x50
+    AUX_MU_LSR: ReadOnly<u32, AUX_MU_LSR::Register>,    // 0x54
+    __reserved_2: [u32; 2],                             // 0x58
+    AUX_MU_CNTL: WriteOnly<u32, AUX_MU_CNTL::Register>, // 0x60
+    __reserved_3: u32,                                  // 0x64
+    AUX_MU_BAUD: WriteOnly<u32, AUX_MU_BAUD::Register>, // 0x68
+}
+
+/// The driver's mutex protected part.
+struct MiniUartInner {
+    base_addr: usize,
+    chars_written: usize,
+}
+
+/// Deref to RegisterBlock.
+///
+/// Allows writing
+/// ```
+/// self.MU_IER.read()
+/// ```
+/// instead of something along the lines of
+/// ```
+/// unsafe { (*MiniUart::ptr()).MU_IER.read() }
+/// ```
+impl ops::Deref for MiniUartInner {
+    type Target = RegisterBlock;
+
+    fn deref(&self) -> &Self::Target {
+        unsafe { &*self.ptr() }
+    }
+}
+
+impl MiniUartInner {
+    const fn new(base_addr: usize) -> MiniUartInner {
+        MiniUartInner {
+            base_addr,
+            chars_written: 0,
+        }
+    }
+
+    /// Return a pointer to the register block.
+    fn ptr(&self) -> *const RegisterBlock {
+        self.base_addr as *const _
+    }
+
+    /// Set up baud rate and characteristics (115200 8N1).
+    fn init(&mut self) -> interface::driver::Result {
+        self.AUX_ENABLES.modify(AUX_ENABLES::MINI_UART_ENABLE::SET);
+        self.AUX_MU_IER.set(0);
+        self.AUX_MU_CNTL.set(0);
+        self.AUX_MU_LCR.write(AUX_MU_LCR::DATA_SIZE::EightBit);
+        self.AUX_MU_MCR.set(0);
+        self.AUX_MU_IER.set(0);
+        self.AUX_MU_IIR.write(AUX_MU_IIR::FIFO_CLEAR::All);
+        self.AUX_MU_BAUD.write(AUX_MU_BAUD::RATE.val(270)); // 115200 baud
+
+        // Enable receive and send.
+        self.AUX_MU_CNTL
+            .write(AUX_MU_CNTL::RX_EN::Enabled + AUX_MU_CNTL::TX_EN::Enabled);
+
+        // Clear FIFOs before using the device.
+        self.AUX_MU_IIR.write(AUX_MU_IIR::FIFO_CLEAR::All);
+
+        Ok(())
+    }
+
+    /// Send a character.
+    fn write_char(&mut self, c: char) {
+        // Wait until we can send.
+        loop {
+            if self.AUX_MU_LSR.is_set(AUX_MU_LSR::TX_EMPTY) {
+                break;
+            }
+
+            asm::nop();
+        }
+
+        // Write the character to the buffer.
+        self.AUX_MU_IO.set(c as u32);
+    }
+}
+
+/// Implementing `core::fmt::Write` enables usage of the `format_args!` macros,
+/// which in turn are used to implement the `kernel`'s `print!` and `println!`
+/// macros. By implementing `write_str()`, we get `write_fmt()` automatically.
+///
+/// The function takes an `&mut self`, so it must be implemented for the inner
+/// struct.
+///
+/// See [`src/print.rs`].
+///
+/// [`src/print.rs`]: ../../print/index.html
+impl fmt::Write for MiniUartInner {
+    fn write_str(&mut self, s: &str) -> fmt::Result {
+        for c in s.chars() {
+            // Convert newline to carrige return + newline.
+            if c == '
' {
+                self.write_char('
')
+            }
+
+            self.write_char(c);
+        }
+
+        self.chars_written += s.len();
+
+        Ok(())
+    }
+}
+
+////////////////////////////////////////////////////////////////////////////////
+// OS interface implementations
+////////////////////////////////////////////////////////////////////////////////
+
+/// The driver's main struct.
+pub struct MiniUart {
+    inner: NullLock<MiniUartInner>,
+}
+
+impl MiniUart {
+    /// # Safety
+    ///
+    /// The user must ensure to provide the correct `base_addr`.
+    pub const unsafe fn new(base_addr: usize) -> MiniUart {
+        MiniUart {
+            inner: NullLock::new(MiniUartInner::new(base_addr)),
+        }
+    }
+}
+
+impl interface::driver::DeviceDriver for MiniUart {
+    fn compatible(&self) -> &str {
+        "MiniUart"
+    }
+
+    fn init(&self) -> interface::driver::Result {
+        use interface::sync::Mutex;
+
+        let mut r = &self.inner;
+        r.lock(|i| i.init())
+    }
+}
+
+/// Passthrough of `args` to the `core::fmt::Write` implementation, but guarded
+/// by a Mutex to serialize access.
+impl interface::console::Write for MiniUart {
+    fn write_fmt(&self, args: core::fmt::Arguments) -> fmt::Result {
+        use interface::sync::Mutex;
+
+        // Fully qualified syntax for the call to
+        // `core::fmt::Write::write:fmt()` to increase readability.
+        let mut r = &self.inner;
+        r.lock(|i| fmt::Write::write_fmt(i, args))
+    }
+}
+
+impl interface::console::Read for MiniUart {}
+
+impl interface::console::Statistics for MiniUart {
+    fn chars_written(&self) -> usize {
+        use interface::sync::Mutex;
+
+        let mut r = &self.inner;
+        r.lock(|i| i.chars_written)
+    }
+}

diff -uNr 05_safe_globals/src/bsp/rpi3/driver.rs 06_drivers_gpio_uart/src/bsp/rpi3/driver.rs
--- 05_safe_globals/src/bsp/rpi3/driver.rs
+++ 06_drivers_gpio_uart/src/bsp/rpi3/driver.rs
@@ -0,0 +1,11 @@
+// SPDX-License-Identifier: MIT
+//
+// Copyright (c) 2018-2019 Andre Richter <andre.o.richter@gmail.com>
+
+//! Collection of device drivers.
+
+mod gpio;
+mod mini_uart;
+
+pub use gpio::GPIO;
+pub use mini_uart::MiniUart;

diff -uNr 05_safe_globals/src/bsp/rpi3/memory_map.rs 06_drivers_gpio_uart/src/bsp/rpi3/memory_map.rs
--- 05_safe_globals/src/bsp/rpi3/memory_map.rs
+++ 06_drivers_gpio_uart/src/bsp/rpi3/memory_map.rs
@@ -0,0 +1,13 @@
+// SPDX-License-Identifier: MIT
+//
+// Copyright (c) 2018-2019 Andre Richter <andre.o.richter@gmail.com>
+
+//! The board's memory map.
+
+/// Physical devices.
+#[rustfmt::skip]
+pub mod mmio {
+    pub const BASE:           usize =        0x3F00_0000;
+    pub const GPIO_BASE:      usize = BASE + 0x0020_0000;
+    pub const MINI_UART_BASE: usize = BASE + 0x0021_5000;
+}

diff -uNr 05_safe_globals/src/bsp/rpi3.rs 06_drivers_gpio_uart/src/bsp/rpi3.rs
--- 05_safe_globals/src/bsp/rpi3.rs
+++ 06_drivers_gpio_uart/src/bsp/rpi3.rs
@@ -4,11 +4,12 @@

 //! Board Support Package for the Raspberry Pi 3.

+mod driver;
+mod memory_map;
 mod panic_wait;
 mod sync;

 use crate::interface;
-use core::fmt;
 use cortex_a::{asm, regs::*};
 use sync::NullLock;

@@ -39,99 +40,13 @@
     }
 }

-/// A mystical, magical device for generating QEMU output out of the void.
-///
-/// The mutex protected part.
-struct QEMUOutputInner {
-    chars_written: usize,
-}
-
-impl QEMUOutputInner {
-    const fn new() -> QEMUOutputInner {
-        QEMUOutputInner { chars_written: 0 }
-    }
-
-    /// Send a character.
-    fn write_char(&mut self, c: char) {
-        unsafe {
-            core::ptr::write_volatile(0x3F21_5040 as *mut u8, c as u8);
-        }
-    }
-}
-
-/// Implementing `core::fmt::Write` enables usage of the `format_args!` macros,
-/// which in turn are used to implement the `kernel`'s `print!` and `println!`
-/// macros. By implementing `write_str()`, we get `write_fmt()` automatically.
-///
-/// The function takes an `&mut self`, so it must be implemented for the inner
-/// struct.
-///
-/// See [`src/print.rs`].
-///
-/// [`src/print.rs`]: ../../print/index.html
-impl fmt::Write for QEMUOutputInner {
-    fn write_str(&mut self, s: &str) -> fmt::Result {
-        for c in s.chars() {
-            // Convert newline to carrige return + newline.
-            if c == '
' {
-                self.write_char('
')
-            }
-
-            self.write_char(c);
-        }
-
-        self.chars_written += s.len();
-
-        Ok(())
-    }
-}
-
 ////////////////////////////////////////////////////////////////////////////////
-// OS interface implementations
+// Global BSP driver instances
 ////////////////////////////////////////////////////////////////////////////////

-/// The main struct.
-pub struct QEMUOutput {
-    inner: NullLock<QEMUOutputInner>,
-}
-
-impl QEMUOutput {
-    pub const fn new() -> QEMUOutput {
-        QEMUOutput {
-            inner: NullLock::new(QEMUOutputInner::new()),
-        }
-    }
-}
-
-/// Passthrough of `args` to the `core::fmt::Write` implementation, but guarded
-/// by a Mutex to serialize access.
-impl interface::console::Write for QEMUOutput {
-    fn write_fmt(&self, args: core::fmt::Arguments) -> fmt::Result {
-        use interface::sync::Mutex;
-
-        // Fully qualified syntax for the call to
-        // `core::fmt::Write::write:fmt()` to increase readability.
-        let mut r = &self.inner;
-        r.lock(|i| fmt::Write::write_fmt(i, args))
-    }
-}
-
-impl interface::console::Read for QEMUOutput {}
-
-impl interface::console::Statistics for QEMUOutput {
-    fn chars_written(&self) -> usize {
-        use interface::sync::Mutex;
-
-        let mut r = &self.inner;
-        r.lock(|i| i.chars_written)
-    }
-}
-
-////////////////////////////////////////////////////////////////////////////////
-// Global instances
-////////////////////////////////////////////////////////////////////////////////
-
-static QEMU_OUTPUT: QEMUOutput = QEMUOutput::new();
+static GPIO: driver::GPIO = unsafe { driver::GPIO::new(memory_map::mmio::GPIO_BASE) };
+static MINI_UART: driver::MiniUart =
+    unsafe { driver::MiniUart::new(memory_map::mmio::MINI_UART_BASE) };

 ////////////////////////////////////////////////////////////////////////////////
 // Implementation of the kernel's BSP calls
@@ -146,5 +61,15 @@

 /// Return a reference to a `console::All` implementation.
 pub fn console() -> &'static impl interface::console::All {
-    &QEMU_OUTPUT
+    &MINI_UART
+}
+
+/// Return an array of references to all `DeviceDriver` compatible `BSP`
+/// drivers.
+///
+/// # Safety
+///
+/// The order of devices is the order in which `DeviceDriver::init()` is called.
+pub fn device_drivers() -> [&'static dyn interface::driver::DeviceDriver; 2] {
+    [&GPIO, &MINI_UART]
 }

diff -uNr 05_safe_globals/src/interface.rs 06_drivers_gpio_uart/src/interface.rs
--- 05_safe_globals/src/interface.rs
+++ 06_drivers_gpio_uart/src/interface.rs
@@ -85,3 +85,20 @@
         fn lock<R>(&mut self, f: impl FnOnce(&mut Self::Data) -> R) -> R;
     }
 }
+
+/// Driver interfaces.
+pub mod driver {
+    /// Driver result type, e.g. for indicating successful driver init.
+    pub type Result = core::result::Result<(), ()>;
+
+    /// Device Driver operations.
+    pub trait DeviceDriver {
+        /// Return a compatibility string for identifying the driver.
+        fn compatible(&self) -> &str;
+
+        /// Called by the kernel to bring up the device.
+        fn init(&self) -> Result {
+            Ok(())
+        }
+    }
+}

diff -uNr 05_safe_globals/src/main.rs 06_drivers_gpio_uart/src/main.rs
--- 05_safe_globals/src/main.rs
+++ 06_drivers_gpio_uart/src/main.rs
@@ -34,10 +34,27 @@
 fn kernel_entry() -> ! {
     use interface::console::Statistics;

+    // Initialize the BSP's device drivers.
+    for i in bsp::device_drivers().iter() {
+        if let Err(()) = i.init() {
+            // This message will only be readable if, at the time of failure,
+            // the return value of `bsp::console()` is already in functioning
+            // state.
+            panic!("Error loading driver: {}", i.compatible())
+        }
+    }
+
+    // If all drivers are loaded, UART is functional now and `println!()` calls
+    // are transmitted on the physical wires.
     println!("[0] Hello from pure Rust!");

-    println!("[1] Chars written: {}", bsp::console().chars_written());
+    println!("[1] Drivers probed:");
+    for (i, driver) in bsp::device_drivers().iter().enumerate() {
+        println!("    {}. {}", i + 1, driver.compatible());
+    }
+
+    println!("[2] Chars written: {}", bsp::console().chars_written());

-    println!("[2] Stopping here.");
+    println!("[3] Stopping here.");
     bsp::wait_forever()
 }
```