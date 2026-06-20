// Package signalinit injects the -L path for libsignal_ffi into the CGo
// link flags. libsignalgo itself provides -lsignal_ffi; this package tells
// the linker WHERE to find the pre-compiled static library for each ABI.
// The .a files live at bridge-go/internal/signal_libs/{arm64,amd64}/.
package signalinit

/*
#cgo android,arm64 LDFLAGS: -L${SRCDIR}/../signal_libs/arm64
#cgo android,amd64 LDFLAGS: -L${SRCDIR}/../signal_libs/amd64
*/
import "C"
