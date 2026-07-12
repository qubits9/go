#!/bin/sh
# build_tte_openbsd.sh - Build and install a Go clone of terminaltexteffects
# Build directory: /tmp/tte-build
# Installation: ~/.local/bin
# Marco: versão pura com 21 efeitos (correção spotlights)

set -e

BUILD_DIR="/tmp/tte-build"
INSTALL_DIR="$HOME/.local/bin"
BINARY_NAME="tte"

echo "=== Building TerminalTextEffects (Go) for OpenBSD ==="
echo "Marco: versão pura + 21 efeitos (correção spotlights)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "Initializing Go module..."
cat > go.mod <<EOF
module tte

go 1.21
EOF

echo "Creating Go source files..."

cat > main.go << 'GOEOF'
package main

import (
	"fmt"
	"io"
	"math"
	"math/rand"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// ============================================================================
// Terminal utilities
// ============================================================================

type winsize struct {
	Row    uint16
	Col    uint16
	Xpixel uint16
	Ypixel uint16
}

func getTerminalSize() (int, int) {
	ws := &winsize{}
	ret, _, _ := syscall.Syscall(
		syscall.SYS_IOCTL,
		uintptr(syscall.Stdout),
		uintptr(syscall.TIOCGWINSZ),
		uintptr(unsafe.Pointer(ws)),
	)
	if ret != 0 {
		return 80, 24
	}
	if ws.Col == 0 {
		ws.Col = 80
	}
	if ws.Row == 0 {
		ws.Row = 24
	}
	return int(ws.Col), int(ws.Row)
}

func getCursorPosition() (int, int) {
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		return 0, 0
	}
	defer tty.Close()

	fd := int(tty.Fd())

	var oldTermios syscall.Termios
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), uintptr(syscall.TIOCGETA), uintptr(unsafe.Pointer(&oldTermios))); errno != 0 {
		return 0, 0
	}

	newTermios := oldTermios
	newTermios.Lflag &^= syscall.ICANON | syscall.ECHO
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), uintptr(syscall.TIOCSETA), uintptr(unsafe.Pointer(&newTermios))); errno != 0 {
		return 0, 0
	}

	defer func() {
		syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), uintptr(syscall.TIOCSETA), uintptr(unsafe.Pointer(&oldTermios)))
	}()

	tty.WriteString("\x1b[6n")

	type result struct {
		response string
		err      error
	}
	resultCh := make(chan result, 1)

	go func() {
		buf := make([]byte, 1)
		var response strings.Builder
		for {
			n, err := tty.Read(buf)
			if err != nil {
				resultCh <- result{"", err}
				return
			}
			if n > 0 {
				response.WriteByte(buf[0])
				if buf[0] == 'R' {
					resultCh <- result{response.String(), nil}
					return
				}
				if response.Len() > 32 {
					resultCh <- result{"", fmt.Errorf("response too long")}
					return
				}
			}
		}
	}()

	select {
	case res := <-resultCh:
		if res.err != nil {
			return 0, 0
		}
		var row, col int
		if _, err := fmt.Sscanf(res.response, "\x1b[%d;%dR", &row, &col); err != nil {
			return 0, 0
		}
		return row - 1, col - 1
	case <-time.After(200 * time.Millisecond):
		tty.Close()
		return 0, 0
	}
}

func allocateSpace(numRows int) int {
	_, termHeight := getTerminalSize()
	startRow, _ := getCursorPosition()

	fmt.Println()
	startRow++

	needed := startRow + numRows

	if needed >= termHeight {
		linesToPrint := needed - termHeight + 2
		for i := 0; i < linesToPrint; i++ {
			fmt.Println()
		}
		startRow, _ = getCursorPosition()
		startRow = startRow - numRows
	}

	return startRow
}

// ============================================================================
// ANSI escape codes
// ============================================================================

const (
	ansiHideCursor = "\x1b[?25l"
	ansiShowCursor = "\x1b[?25h"
	ansiReset      = "\x1b[0m"
)

// ============================================================================
// Color type
// ============================================================================

type Color struct {
	R, G, B uint8
}

func ParseColor(hex string) Color {
	if len(hex) == 6 {
		r, _ := strconv.ParseUint(hex[0:2], 16, 8)
		g, _ := strconv.ParseUint(hex[2:4], 16, 8)
		b, _ := strconv.ParseUint(hex[4:6], 16, 8)
		return Color{uint8(r), uint8(g), uint8(b)}
	}
	return Color{255, 255, 255}
}

func (c Color) String() string {
	return fmt.Sprintf("\x1b[38;2;%d;%d;%dm", c.R, c.G, c.B)
}

func (c Color) Lerp(other Color, t float64) Color {
	return Color{
		R: uint8(float64(c.R)*(1-t) + float64(other.R)*t),
		G: uint8(float64(c.G)*(1-t) + float64(other.G)*t),
		B: uint8(float64(c.B)*(1-t) + float64(other.B)*t),
	}
}

// ============================================================================
// Terminal state
// ============================================================================

type termState struct {
	startRow int
	numRows  int
	restored bool
}

func (t *termState) enter() {
	fmt.Print(ansiHideCursor)
}

func (t *termState) exit() {
	if t.restored {
		return
	}
	t.restored = true
	fmt.Print(ansiReset + ansiShowCursor)
	nextRow := t.startRow + t.numRows + 1
	fmt.Printf("\x1b[%d;1H\n", nextRow)
}

// ============================================================================
// Gradient and easing functions
// ============================================================================

func generateGradient(colors []Color, steps int) []Color {
	if len(colors) == 0 {
		return []Color{{255, 255, 255}}
	}
	if len(colors) == 1 {
		result := make([]Color, steps)
		for i := range result {
			result[i] = colors[0]
		}
		return result
	}

	result := make([]Color, 0, steps)
	segmentSize := float64(steps-1) / float64(len(colors)-1)

	for i := 0; i < len(colors)-1; i++ {
		start := int(float64(i) * segmentSize)
		end := int(float64(i+1) * segmentSize)
		segmentSteps := end - start
		if segmentSteps == 0 {
			segmentSteps = 1
		}
		for j := 0; j <= segmentSteps; j++ {
			t := float64(j) / float64(segmentSteps)
			result = append(result, colors[i].Lerp(colors[i+1], t))
		}
	}

	if len(result) > steps {
		result = result[:steps]
	}
	return result
}

func easeInOutCubic(t float64) float64 {
	if t < 0.5 {
		return 4 * t * t * t
	}
	return 1 - math.Pow(-2*t+2, 3)/2
}

func easeOutBack(t float64) float64 {
	c1 := 1.70158
	c3 := c1 + 1
	return 1 + c3*math.Pow(t-1, 3) + c1*math.Pow(t-1, 2)
}

func easeInQuad(t float64) float64 {
	return t * t
}

func easeOutQuad(t float64) float64 {
	return 1 - (1 - t) * (1 - t)
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// ============================================================================
// Effect interface and registry
// ============================================================================

type Effect interface {
	Name() string
	Description() string
	Run(text string, args map[string]interface{})
}

var effects = make(map[string]Effect)

func registerEffect(e Effect) {
	effects[e.Name()] = e
}

// ============================================================================
// DECRYPT EFFECT
// ============================================================================

type DecryptEffect struct{}

func (e DecryptEffect) Name() string        { return "decrypt" }
func (e DecryptEffect) Description() string { return "Display a movie style decryption effect." }
func (e DecryptEffect) Run(text string, args map[string]interface{}) {
	typingSpeed := getIntArg(args, "typing-speed", 2)
	ciphertextColors := getColorSliceArg(args, "ciphertext-colors", []string{"008000", "00cb00", "00ff00"})
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"eda000"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)
	chars := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()"

	for frame := 0; frame < 30; frame++ {
		var sb strings.Builder
		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					color := ciphertextColors[rand.Intn(len(ciphertextColors))]
					sb.WriteString(color.String())
					sb.WriteRune(rune(chars[rand.Intn(len(chars))]))
				} else {
					sb.WriteByte(' ')
				}
			}
			sb.WriteString("\x1b[K")
		}
		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/60) * time.Millisecond)
	}

	decrypted := make([][]bool, rows)
	for i := range decrypted {
		decrypted[i] = make([]bool, cols)
	}

	for frame := 0; frame < rows*cols/typingSpeed+10; frame++ {
		var sb strings.Builder
		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			for col := 0; col < cols; col++ {
				if col >= len(lines[row]) || lines[row][col] == ' ' {
					sb.WriteByte(' ')
					continue
				}
				ch := rune(lines[row][col])
				if !decrypted[row][col] && rand.Float64() < 0.1*float64(typingSpeed) {
					decrypted[row][col] = true
				}
				if decrypted[row][col] {
					progress := float64(row*cols+col) / float64(rows*cols)
					colorIdx := int(progress * float64(len(gradient)-1))
					if colorIdx >= len(gradient) {
						colorIdx = len(gradient) - 1
					}
					sb.WriteString(gradient[colorIdx].String())
					sb.WriteRune(ch)
				} else {
					color := ciphertextColors[rand.Intn(len(ciphertextColors))]
					sb.WriteString(color.String())
					sb.WriteRune(rune(chars[rand.Intn(len(chars))]))
				}
			}
			sb.WriteString("\x1b[K")
		}
		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/60) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				progress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(progress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// RAIN EFFECT
// ============================================================================

type RainEffect struct{}

func (e RainEffect) Name() string        { return "rain" }
func (e RainEffect) Description() string { return "Rain characters from the top of the canvas." }
func (e RainEffect) Run(text string, args map[string]interface{}) {
	rainColors := getColorSliceArg(args, "rain-colors", []string{"00315C", "004C8F", "0075DB", "3F91D9", "78B9F2", "9AC8F5", "B8D8F8", "E3EFFC"})
	movementSpeed := getFloatArg(args, "movement-speed", 0.45)
	rainSymbols := getStringSliceArg(args, "rain-symbols", []string{"o", ".", ",", "*", "|"})
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"488bff", "b2e7de", "57eaf7"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	type Drop struct {
		TargetRow  int
		TargetCol  int
		Char       rune
		CurrentRow float64
		Color      Color
		Symbol     string
		Landed     bool
	}

	drops := make([]Drop, 0)
	for row := 0; row < rows; row++ {
		for col := 0; col < len(lines[row]); col++ {
			if lines[row][col] != ' ' {
				drops = append(drops, Drop{
					TargetRow:  row,
					TargetCol:  col,
					Char:       rune(lines[row][col]),
					CurrentRow: -float64(rand.Intn(rows) + 5),
					Color:      rainColors[rand.Intn(len(rainColors))],
					Symbol:     rainSymbols[rand.Intn(len(rainSymbols))],
					Landed:     false,
				})
			}
		}
	}

	for frame := 0; frame < rows*3+60; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absRow := startRow + i + 1
			if absRow >= 1 && absRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		for i := range drops {
			if !drops[i].Landed {
				drops[i].CurrentRow += movementSpeed
				if drops[i].CurrentRow >= float64(drops[i].TargetRow) {
					drops[i].Landed = true
					drops[i].CurrentRow = float64(drops[i].TargetRow)
				}
			}

			if drops[i].Landed {
				if drops[i].TargetRow >= 0 && drops[i].TargetRow < rows && drops[i].TargetCol >= 0 && drops[i].TargetCol < cols {
					absRow := startRow + drops[i].TargetRow + 1
					if absRow >= 1 && absRow <= termHeight {
						sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absRow, drops[i].TargetCol+1))
						progress := float64(drops[i].TargetRow*cols+drops[i].TargetCol) / float64(rows*cols)
						colorIdx := int(progress * float64(len(gradient)-1))
						if colorIdx >= len(gradient) {
							colorIdx = len(gradient) - 1
						}
						sb.WriteString(gradient[colorIdx].String())
						sb.WriteRune(drops[i].Char)
					}
				}
			} else if drops[i].CurrentRow >= 0 && int(drops[i].CurrentRow) < rows {
				if drops[i].TargetCol >= 0 && drops[i].TargetCol < cols {
					absRow := startRow + int(drops[i].CurrentRow) + 1
					if absRow >= 1 && absRow <= termHeight {
						sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absRow, drops[i].TargetCol+1))
						sb.WriteString(drops[i].Color.String())
						sb.WriteString(drops[i].Symbol)
					}
				}
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/60) * time.Millisecond)

		allLanded := true
		for _, drop := range drops {
			if !drop.Landed {
				allLanded = false
				break
			}
		}
		if allLanded {
			break
		}
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				progress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(progress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// EXPAND EFFECT
// ============================================================================

type ExpandEffect struct{}

func (e ExpandEffect) Name() string        { return "expand" }
func (e ExpandEffect) Description() string { return "Expands the text from a single point." }
func (e ExpandEffect) Run(text string, args map[string]interface{}) {
	movementSpeed := getFloatArg(args, "movement-speed", 0.35)
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"8A008A", "00D1FF", "FFFFFF"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	centerRow := rows / 2
	centerCol := cols / 2

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	maxDist := float64(rows + cols)
	for frame := 0; frame < int(maxDist/movementSpeed)+10; frame++ {
		progress := easeInOutCubic(float64(frame) * movementSpeed / maxDist)
		if progress > 1 {
			progress = 1
		}

		var sb strings.Builder
		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					dist := math.Sqrt(math.Pow(float64(row-centerRow), 2) + math.Pow(float64(col-centerCol), 2))
					if dist/maxDist <= progress {
						gradProgress := float64(row*cols+col) / float64(rows*cols)
						colorIdx := int(gradProgress * float64(len(gradient)-1))
						if colorIdx >= len(gradient) {
							colorIdx = len(gradient) - 1
						}
						sb.WriteString(gradient[colorIdx].String())
						sb.WriteRune(rune(lines[row][col]))
					} else {
						sb.WriteByte(' ')
					}
				} else {
					sb.WriteByte(' ')
				}
			}
			sb.WriteString("\x1b[K")
		}
		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/60) * time.Millisecond)
		if progress >= 1 {
			break
		}
	}
}

// ============================================================================
// SCATTERED EFFECT
// ============================================================================

type ScatteredEffect struct{}

func (e ScatteredEffect) Name() string        { return "scattered" }
func (e ScatteredEffect) Description() string { return "Text is scattered across the canvas and moves into position." }
func (e ScatteredEffect) Run(text string, args map[string]interface{}) {
	movementSpeed := getFloatArg(args, "movement-speed", 0.5)
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"ff9048", "ab9dff", "bdffea"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	type CharInfo struct {
		Char      rune
		StartRow  int
		StartCol  int
		TargetRow int
		TargetCol int
	}

	chars := make([]CharInfo, 0)
	for row := 0; row < rows; row++ {
		for col := 0; col < len(lines[row]); col++ {
			if lines[row][col] != ' ' {
				chars = append(chars, CharInfo{
					Char:      rune(lines[row][col]),
					StartRow:  rand.Intn(rows),
					StartCol:  rand.Intn(cols),
					TargetRow: row,
					TargetCol: col,
				})
			}
		}
	}

	totalFrames := int(1.0 / movementSpeed * 60)
	for frame := 0; frame < totalFrames; frame++ {
		progress := easeOutBack(float64(frame) / float64(totalFrames))
		if progress > 1 {
			progress = 1
		}

		canvas := make(map[int]map[int]rune)
		for row := 0; row < rows; row++ {
			canvas[row] = make(map[int]rune)
		}

		for _, ch := range chars {
			currentRow := int(float64(ch.StartRow)*(1-progress) + float64(ch.TargetRow)*progress)
			currentCol := int(float64(ch.StartCol)*(1-progress) + float64(ch.TargetCol)*progress)
			if currentRow >= 0 && currentRow < rows && currentCol >= 0 && currentCol < cols {
				canvas[currentRow][currentCol] = ch.Char
			}
		}

		var sb strings.Builder
		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			for col := 0; col < cols; col++ {
				if ch, ok := canvas[row][col]; ok {
					gradProgress := float64(row*cols+col) / float64(rows*cols)
					colorIdx := int(gradProgress * float64(len(gradient)-1))
					if colorIdx >= len(gradient) {
						colorIdx = len(gradient) - 1
					}
					sb.WriteString(gradient[colorIdx].String())
					sb.WriteRune(ch)
				} else {
					sb.WriteByte(' ')
				}
			}
			sb.WriteString("\x1b[K")
		}
		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/60) * time.Millisecond)
	}
}

// ============================================================================
// WAVES EFFECT
// ============================================================================

type WavesEffect struct{}

func (e WavesEffect) Name() string        { return "waves" }
func (e WavesEffect) Description() string { return "Waves travel across the terminal leaving behind the characters." }
func (e WavesEffect) Run(text string, args map[string]interface{}) {
	waveSymbols := getStringSliceArg(args, "wave-symbols", []string{"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅", "▄", "▃", "▂", "▁"})
	waveLength := getIntArg(args, "wave-length", 2)
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"ffb102", "31a0d4", "f0ff65"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	for wave := 0; wave < cols+20; wave++ {
		var sb strings.Builder
		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					dist := abs(col - wave)
					if dist < waveLength*2 {
						symbolIdx := (dist + wave) % len(waveSymbols)
						sb.WriteString(waveSymbols[symbolIdx])
					} else {
						gradProgress := float64(row*cols+col) / float64(rows*cols)
						colorIdx := int(gradProgress * float64(len(gradient)-1))
						if colorIdx >= len(gradient) {
							colorIdx = len(gradient) - 1
						}
						sb.WriteString(gradient[colorIdx].String())
						sb.WriteRune(rune(lines[row][col]))
					}
				} else {
					sb.WriteByte(' ')
				}
			}
			sb.WriteString("\x1b[K")
		}
		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/60) * time.Millisecond)
	}
}

// ============================================================================
// BLACKHOLE EFFECT
// ============================================================================

type BlackholeEffect struct{}

func (e BlackholeEffect) Name() string        { return "blackhole" }
func (e BlackholeEffect) Description() string { return "Characters are consumed by a black hole and explode outwards." }
func (e BlackholeEffect) Run(text string, args map[string]interface{}) {
	blackholeColor := getColorArg(args, "blackhole-color", "ffffff")
	starColors := getColorSliceArg(args, "star-colors", []string{"ffcc0d", "ff7326", "ff194d", "bf2669", "702a8c", "049dbf"})
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"8A008A", "00D1FF", "ffffff"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 9)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	centerRow := rows / 2
	centerCol := cols / 2

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	for frame := 0; frame < 30; frame++ {
		progress := easeInQuad(float64(frame) / 30.0)
		var sb strings.Builder
		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					currentRow := int(float64(row)*(1-progress) + float64(centerRow)*progress)
					currentCol := int(float64(col)*(1-progress) + float64(centerCol)*progress)
					if currentRow == centerRow && currentCol == centerCol {
						sb.WriteString(blackholeColor.String())
						sb.WriteRune(rune(lines[row][col]))
					} else {
						sb.WriteByte(' ')
					}
				} else {
					sb.WriteByte(' ')
				}
			}
			sb.WriteString("\x1b[K")
		}
		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/60) * time.Millisecond)
	}

	for frame := 0; frame < 30; frame++ {
		progress := easeOutQuad(float64(frame) / 30.0)
		var sb strings.Builder
		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					currentRow := int(float64(centerRow)*(1-progress) + float64(row)*progress)
					currentCol := int(float64(centerCol)*(1-progress) + float64(col)*progress)
					if currentRow == row && currentCol == col {
						color := starColors[rand.Intn(len(starColors))]
						sb.WriteString(color.String())
						sb.WriteRune(rune(lines[row][col]))
					} else {
						sb.WriteByte(' ')
					}
				} else {
					sb.WriteByte(' ')
				}
			}
			sb.WriteString("\x1b[K")
		}
		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/60) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				gradProgress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// MATRIX EFFECT
// ============================================================================

type MatrixEffect struct{}

func (e MatrixEffect) Name() string        { return "matrix" }
func (e MatrixEffect) Description() string { return "Matrix digital rain effect." }
func (e MatrixEffect) Run(text string, args map[string]interface{}) {
	matrixColors := getColorSliceArg(args, "matrix-colors", []string{"35a837", "4ef854", "cbf7cf"})
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"35a837", "4ef854", "cbf7cf"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)
	movementSpeed := getFloatArg(args, "movement-speed", 0.5)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()

	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)
	matrixChars := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜｦﾝ"

	type MatrixColumn struct {
		col     int
		headRow float64
		length  int
		speed   float64
		chars   []rune
	}

	columns := make([]MatrixColumn, 0)
	for col := 0; col < cols; col++ {
		hasChar := false
		for _, line := range lines {
			if col < len(line) && line[col] != ' ' {
				hasChar = true
				break
			}
		}
		if hasChar {
			chars := make([]rune, rows+5)
			for i := range chars {
				chars[i] = rune(matrixChars[rand.Intn(len(matrixChars))])
			}
			columns = append(columns, MatrixColumn{
				col:     col,
				headRow: -float64(rand.Intn(5) + 3),
				length:  rand.Intn(rows/2) + 2,
				speed:   movementSpeed * (0.5 + rand.Float64()),
				chars:   chars,
			})
		}
	}

	drawChar := func(sb *strings.Builder, row, col int, ch rune, color Color) {
		if row < 0 || row >= rows || col < 0 || col >= cols {
			return
		}
		absoluteRow := startRow + row + 1
		if absoluteRow < 1 || absoluteRow > termHeight {
			return
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absoluteRow, col+1))
		sb.WriteString(color.String())
		sb.WriteRune(ch)
	}

	for frame := 0; frame < rows*4; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absoluteRow := startRow + i + 1
			if absoluteRow >= 1 && absoluteRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		for i := range columns {
			columns[i].headRow += columns[i].speed

			for j := 0; j < columns[i].length; j++ {
				drawRow := int(columns[i].headRow) - j

				if drawRow < 0 || drawRow >= rows {
					continue
				}
				if columns[i].col < 0 || columns[i].col >= cols {
					continue
				}
				absoluteRow := startRow + drawRow + 1
				if absoluteRow < 1 || absoluteRow > termHeight {
					continue
				}

				charIdx := (frame + j + i) % len(columns[i].chars)
				ch := columns[i].chars[charIdx]

				var color Color
				if j == 0 {
					color = Color{255, 255, 255}
				} else if j == 1 {
					color = matrixColors[0]
				} else {
					fade := float64(j) / float64(columns[i].length)
					baseColor := matrixColors[len(matrixColors)-1]
					color = Color{
						R: uint8(float64(baseColor.R) * (1 - fade)),
						G: uint8(float64(baseColor.G) * (1 - fade*0.5)),
						B: uint8(float64(baseColor.B) * (1 - fade)),
					}
				}

				drawChar(&sb, drawRow, columns[i].col, ch, color)
			}

			if int(columns[i].headRow)-columns[i].length >= rows+2 {
				columns[i].headRow = -float64(rand.Intn(3) + 2)
				columns[i].speed = movementSpeed * (0.5 + rand.Float64())
				columns[i].length = rand.Intn(rows/2) + 2
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	for frame := 0; frame < 30; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absoluteRow := startRow + i + 1
			if absoluteRow >= 1 && absoluteRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		for row := 0; row < rows; row++ {
			absoluteRow := startRow + row + 1
			if absoluteRow < 1 || absoluteRow > termHeight {
				continue
			}

			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					if rand.Float64() < float64(frame)/30.0 {
						gradProgress := float64(row*cols+col) / float64(rows*cols)
						colorIdx := int(gradProgress * float64(len(gradient)-1))
						if colorIdx >= len(gradient) {
							colorIdx = len(gradient) - 1
						}
						sb.WriteString(gradient[colorIdx].String())
						sb.WriteRune(rune(lines[row][col]))
					} else {
						ch := rune(matrixChars[rand.Intn(len(matrixChars))])
						sb.WriteString(matrixColors[rand.Intn(len(matrixColors))].String())
						sb.WriteRune(ch)
					}
				} else {
					sb.WriteByte(' ')
				}
			}
			sb.WriteString("\x1b[K")
		}
		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absoluteRow := startRow + row + 1
		if absoluteRow >= 1 && absoluteRow <= termHeight {
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) {
					gradProgress := float64(row*cols+col) / float64(rows*cols)
					colorIdx := int(gradProgress * float64(len(gradient)-1))
					if colorIdx >= len(gradient) {
						colorIdx = len(gradient) - 1
					}
					sb.WriteString(gradient[colorIdx].String())
					sb.WriteRune(rune(lines[row][col]))
				}
			}
			sb.WriteString("\x1b[K")
		}
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// FIREWORKS EFFECT
// ============================================================================

type FireworksEffect struct{}

func (e FireworksEffect) Name() string        { return "fireworks" }
func (e FireworksEffect) Description() string { return "Characters launch and explode like fireworks and fall into place." }
func (e FireworksEffect) Run(text string, args map[string]interface{}) {
	fireworkColors := getColorSliceArg(args, "firework-colors", []string{"ff0000", "ffff00", "00ff00", "00ffff", "ff00ff", "ffffff"})
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"ff194d", "ff7326", "ffcc0d"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	type Particle struct {
		char    rune
		x       float64
		y       float64
		vx      float64
		vy      float64
		color   Color
		targetX int
		targetY int
		phase   string
		life    int
	}

	particles := make([]Particle, 0)
	for row := 0; row < rows; row++ {
		for col := 0; col < len(lines[row]); col++ {
			if lines[row][col] != ' ' {
				particles = append(particles, Particle{
					char:    rune(lines[row][col]),
					x:       float64(col),
					y:       float64(rows + 5),
					vx:      0,
					vy:      0,
					color:   fireworkColors[rand.Intn(len(fireworkColors))],
					targetX: col,
					targetY: row,
					phase:   "launch",
					life:    0,
				})
			}
		}
	}

	for frame := 0; frame < 20; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absRow := startRow + i + 1
			if absRow >= 1 && absRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		for i := range particles {
			if particles[i].phase == "launch" {
				progress := float64(frame) / 20.0
				particles[i].y = float64(rows+5)*(1-progress) + float64(particles[i].targetY)*progress

				if int(particles[i].y) >= 0 && int(particles[i].y) < rows {
					absRow := startRow + int(particles[i].y) + 1
					if absRow >= 1 && absRow <= termHeight {
						sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absRow, int(particles[i].x)+1))
						sb.WriteString(particles[i].color.String())
						sb.WriteRune(particles[i].char)
					}
				}
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	for frame := 0; frame < 15; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absRow := startRow + i + 1
			if absRow >= 1 && absRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		for i := range particles {
			if particles[i].phase == "launch" {
				particles[i].phase = "explode"
				angle := rand.Float64() * 2 * math.Pi
				speed := 1.0 + rand.Float64()*2.0
				particles[i].vx = math.Cos(angle) * speed
				particles[i].vy = math.Sin(angle) * speed
			}

			if particles[i].phase == "explode" {
				particles[i].x += particles[i].vx
				particles[i].y += particles[i].vy
				particles[i].vy += 0.2
				particles[i].life++

				if int(particles[i].y) >= 0 && int(particles[i].y) < rows &&
					int(particles[i].x) >= 0 && int(particles[i].x) < cols {
					absRow := startRow + int(particles[i].y) + 1
					if absRow >= 1 && absRow <= termHeight {
						sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absRow, int(particles[i].x)+1))
						sb.WriteString(particles[i].color.String())
						sb.WriteRune('*')
					}
				}

				if particles[i].life > 10 {
					particles[i].phase = "fall"
				}
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	for frame := 0; frame < 30; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absRow := startRow + i + 1
			if absRow >= 1 && absRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		for i := range particles {
			if particles[i].phase == "fall" {
				progress := float64(frame) / 30.0
				particles[i].x = particles[i].x*(1-progress) + float64(particles[i].targetX)*progress
				particles[i].y = particles[i].y*(1-progress) + float64(particles[i].targetY)*progress

				if int(particles[i].y) >= 0 && int(particles[i].y) < rows &&
					int(particles[i].x) >= 0 && int(particles[i].x) < cols {
					absRow := startRow + int(particles[i].y) + 1
					if absRow >= 1 && absRow <= termHeight {
						sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absRow, int(particles[i].x)+1))
						sb.WriteString(particles[i].color.String())
						sb.WriteRune(particles[i].char)
					}
				}

				if progress >= 1.0 {
					particles[i].phase = "landed"
				}
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				gradProgress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// BEAMS EFFECT
// ============================================================================

type BeamsEffect struct{}

func (e BeamsEffect) Name() string        { return "beams" }
func (e BeamsEffect) Description() string { return "Create beams which travel over the canvas illuminating the characters behind them." }
func (e BeamsEffect) Run(text string, args map[string]interface{}) {
	beamColor := getColorArg(args, "beam-color", "ffffff")
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"FF0000", "00FF00", "0000FF"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)
	numBeams := getIntArg(args, "num-beams", 3)
	beamWidth := getIntArg(args, "beam-width", 2)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	beamSymbols := []rune{'▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'}

	type Beam struct {
		col    int
		speed  float64
		symbol rune
	}

	beams := make([]Beam, numBeams)
	for i := 0; i < numBeams; i++ {
		beams[i] = Beam{
			col:    -beamWidth - i*5,
			speed:  1.0 + rand.Float64()*1.5,
			symbol: beamSymbols[rand.Intn(len(beamSymbols))],
		}
	}

	revealed := make([][]bool, rows)
	for i := range revealed {
		revealed[i] = make([]bool, cols)
	}

	for frame := 0; frame < (cols+beamWidth*numBeams)*3; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absRow := startRow + i + 1
			if absRow >= 1 && absRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		allPassed := true

		for i := range beams {
			beams[i].col += int(beams[i].speed)

			if beams[i].col < cols+beamWidth {
				allPassed = false
			}

			for x := 0; x < beamWidth; x++ {
				colPos := beams[i].col + x
				if colPos >= 0 && colPos < cols {
					for row := 0; row < rows; row++ {
						absRow := startRow + row + 1
						if absRow < 1 || absRow > termHeight {
							continue
						}
						if colPos < len(lines[row]) && lines[row][colPos] != ' ' {
							revealed[row][colPos] = true
						}
						sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absRow, colPos+1))
						sb.WriteString(beamColor.String())
						sb.WriteRune(beams[i].symbol)
					}
				}
			}
		}

		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					if revealed[row][col] {
						beingIlluminated := false
						for _, beam := range beams {
							for x := 0; x < beamWidth; x++ {
								if beam.col+x == col {
									beingIlluminated = true
									break
								}
							}
							if beingIlluminated {
								break
							}
						}

						if !beingIlluminated {
							gradProgress := float64(row*cols+col) / float64(rows*cols)
							colorIdx := int(gradProgress * float64(len(gradient)-1))
							if colorIdx >= len(gradient) {
								colorIdx = len(gradient) - 1
							}
							sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absRow, col+1))
							sb.WriteString(gradient[colorIdx].String())
							sb.WriteRune(rune(lines[row][col]))
						}
					}
				}
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)

		if allPassed {
			break
		}
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				gradProgress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// WIPE EFFECT
// ============================================================================

type WipeEffect struct{}

func (e WipeEffect) Name() string        { return "wipe" }
func (e WipeEffect) Description() string { return "Wipes the text across the terminal to reveal characters." }
func (e WipeEffect) Run(text string, args map[string]interface{}) {
	wipeColor := getColorArg(args, "wipe-color", "ffffff")
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"FF6B00", "FFD700", "FFFFFF"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)
	wipeSpeed := getFloatArg(args, "wipe-speed", 1.0)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	var sb strings.Builder
	for i := 0; i < rows; i++ {
		absRow := startRow + i + 1
		if absRow >= 1 && absRow <= termHeight {
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			sb.WriteString(strings.Repeat(" ", cols))
			sb.WriteString("\x1b[K")
		}
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())

	totalFrames := int(float64(cols) / wipeSpeed)

	for frame := 0; frame <= totalFrames; frame++ {
		sb.Reset()

		for i := 0; i < rows; i++ {
			absRow := startRow + i + 1
			if absRow >= 1 && absRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		wipeCol := int(float64(frame) * wipeSpeed)

		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					if col < wipeCol {
						gradProgress := float64(row*cols+col) / float64(rows*cols)
						colorIdx := int(gradProgress * float64(len(gradient)-1))
						if colorIdx >= len(gradient) {
							colorIdx = len(gradient) - 1
						}
						sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absRow, col+1))
						sb.WriteString(gradient[colorIdx].String())
						sb.WriteRune(rune(lines[row][col]))
					} else if col == wipeCol {
						sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absRow, col+1))
						sb.WriteString(wipeColor.String())
						sb.WriteRune(rune(lines[row][col]))
					}
				}
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	sb.Reset()
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				gradProgress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// BURN EFFECT
// ============================================================================

type BurnEffect struct{}

func (e BurnEffect) Name() string        { return "burn" }
func (e BurnEffect) Description() string { return "Burns vertically in the canvas." }
func (e BurnEffect) Run(text string, args map[string]interface{}) {
	fireColors := getColorSliceArg(args, "fire-colors", []string{"FF0000", "FF4500", "FF8C00", "FFD700", "FFFF00"})
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"FF4500", "FFD700", "FFFFFF"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)
	burnSpeed := getFloatArg(args, "burn-speed", 0.3)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	fireSymbols := []rune{'░', '▒', '▓', '█', '▓', '▒', '░', '·', '°', '•'}

	burned := make([][]bool, rows)
	for i := range burned {
		burned[i] = make([]bool, cols)
	}

	drawChar := func(sb *strings.Builder, row, col int, ch rune, color Color) {
		if row < 0 || row >= rows || col < 0 || col >= cols {
			return
		}
		absoluteRow := startRow + row + 1
		if absoluteRow < 1 || absoluteRow > termHeight {
			return
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absoluteRow, col+1))
		sb.WriteString(color.String())
		sb.WriteRune(ch)
	}

	totalFrames := int(float64(rows) / burnSpeed)
	for frame := 0; frame <= totalFrames+10; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absoluteRow := startRow + i + 1
			if absoluteRow >= 1 && absoluteRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		fireRow := rows - int(float64(frame)*burnSpeed)

		for row := 0; row < rows; row++ {
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					if row > fireRow {
						burned[row][col] = true
						gradProgress := float64(row*cols+col) / float64(rows*cols)
						colorIdx := int(gradProgress * float64(len(gradient)-1))
						if colorIdx >= len(gradient) {
							colorIdx = len(gradient) - 1
						}
						drawChar(&sb, row, col, rune(lines[row][col]), gradient[colorIdx])
					} else if row == fireRow || row == fireRow+1 {
						sym := fireSymbols[rand.Intn(len(fireSymbols))]
						color := fireColors[rand.Intn(len(fireColors))]
						drawChar(&sb, row, col, sym, color)
					}
				}
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	for frame := 0; frame < 20; frame++ {
		var sb strings.Builder

		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					if rand.Float64() < float64(frame)/20.0 {
						gradProgress := float64(row*cols+col) / float64(rows*cols)
						colorIdx := int(gradProgress * float64(len(gradient)-1))
						if colorIdx >= len(gradient) {
							colorIdx = len(gradient) - 1
						}
						sb.WriteString(gradient[colorIdx].String())
						sb.WriteRune(rune(lines[row][col]))
					} else {
						sym := fireSymbols[rand.Intn(len(fireSymbols))]
						color := fireColors[rand.Intn(len(fireColors))]
						sb.WriteString(color.String())
						sb.WriteRune(sym)
					}
				} else {
					sb.WriteByte(' ')
				}
			}
			sb.WriteString("\x1b[K")
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				gradProgress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// CRUMBLE EFFECT
// ============================================================================

type CrumbleEffect struct{}

func (e CrumbleEffect) Name() string        { return "crumble" }
func (e CrumbleEffect) Description() string { return "Characters lose color and crumble into dust, vacuumed up, and reformed." }
func (e CrumbleEffect) Run(text string, args map[string]interface{}) {
	dustColors := getColorSliceArg(args, "dust-colors", []string{"808080", "A0A0A0", "C0C0C0", "E0E0E0"})
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"FF6B9D", "C06C84", "6C5B7B"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	dustSymbols := []rune{'.', '·', '°', '•', '∙', '∘', '◦'}

	type CrumbleChar struct {
		char      rune
		targetRow int
		targetCol int
		dustRow   float64
		dustCol   float64
		phase     string
	}

	chars := make([]CrumbleChar, 0)
	for row := 0; row < rows; row++ {
		for col := 0; col < len(lines[row]); col++ {
			if lines[row][col] != ' ' {
				chars = append(chars, CrumbleChar{
					char:      rune(lines[row][col]),
					targetRow: row,
					targetCol: col,
					dustRow:   float64(row),
					dustCol:   float64(col),
					phase:     "solid",
				})
			}
		}
	}

	drawChar := func(sb *strings.Builder, row, col int, ch rune, color Color) {
		if row < 0 || row >= rows || col < 0 || col >= cols {
			return
		}
		absoluteRow := startRow + row + 1
		if absoluteRow < 1 || absoluteRow > termHeight {
			return
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absoluteRow, col+1))
		sb.WriteString(color.String())
		sb.WriteRune(ch)
	}

	for frame := 0; frame < 15; frame++ {
		var sb strings.Builder
		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) {
					sb.WriteRune(rune(lines[row][col]))
				}
			}
			sb.WriteString("\x1b[K")
		}
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	for frame := 0; frame < 40; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absRow := startRow + i + 1
			if absRow >= 1 && absRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		progress := float64(frame) / 40.0

		for i := range chars {
			if progress < 0.5 {
				if rand.Float64() < progress*2 {
					chars[i].phase = "dust"
					chars[i].dustRow = float64(chars[i].targetRow) + rand.Float64()*3
					chars[i].dustCol = float64(chars[i].targetCol) + (rand.Float64()-0.5)*4
				}
			} else {
				chars[i].phase = "vacuum"
				centerRow := float64(rows) / 2
				centerCol := float64(cols) / 2
				vacuumProgress := (progress - 0.5) * 2
				chars[i].dustRow = chars[i].dustRow*(1-vacuumProgress) + centerRow*vacuumProgress
				chars[i].dustCol = chars[i].dustCol*(1-vacuumProgress) + centerCol*vacuumProgress
			}

			if chars[i].phase == "dust" || chars[i].phase == "vacuum" {
				drawRow := int(chars[i].dustRow)
				drawCol := int(chars[i].dustCol)
				if drawRow >= 0 && drawRow < rows && drawCol >= 0 && drawCol < cols {
					sym := dustSymbols[rand.Intn(len(dustSymbols))]
					color := dustColors[rand.Intn(len(dustColors))]
					drawChar(&sb, drawRow, drawCol, sym, color)
				}
			} else {
				drawChar(&sb, chars[i].targetRow, chars[i].targetCol, chars[i].char, Color{255, 255, 255})
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	for frame := 0; frame < 30; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absRow := startRow + i + 1
			if absRow >= 1 && absRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		progress := float64(frame) / 30.0

		for i := range chars {
			chars[i].phase = "reform"
			centerRow := float64(rows) / 2
			centerCol := float64(cols) / 2
			chars[i].dustRow = centerRow*(1-progress) + float64(chars[i].targetRow)*progress
			chars[i].dustCol = centerCol*(1-progress) + float64(chars[i].targetCol)*progress

			drawRow := int(chars[i].dustRow)
			drawCol := int(chars[i].dustCol)
			if drawRow >= 0 && drawRow < rows && drawCol >= 0 && drawCol < cols {
				if progress > 0.8 {
					gradProgress := float64(chars[i].targetRow*cols+chars[i].targetCol) / float64(rows*cols)
					colorIdx := int(gradProgress * float64(len(gradient)-1))
					if colorIdx >= len(gradient) {
						colorIdx = len(gradient) - 1
					}
					drawChar(&sb, drawRow, drawCol, chars[i].char, gradient[colorIdx])
				} else {
					sym := dustSymbols[rand.Intn(len(dustSymbols))]
					color := dustColors[rand.Intn(len(dustColors))]
					drawChar(&sb, drawRow, drawCol, sym, color)
				}
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				gradProgress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// SMOKE EFFECT
// ============================================================================

type SmokeEffect struct{}

func (e SmokeEffect) Name() string        { return "smoke" }
func (e SmokeEffect) Description() string { return "Smoke floods the canvas colorizing any characters it crosses." }
func (e SmokeEffect) Run(text string, args map[string]interface{}) {
	smokeColors := getColorSliceArg(args, "smoke-colors", []string{"707070", "909090", "B0B0B0", "D0D0D0"})
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"4A90E2", "7B68EE", "9370DB"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)
	smokeDensity := getFloatArg(args, "smoke-density", 0.3)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	smokeSymbols := []rune{'░', '▒', '▓', '·', '°', '•', '∙', '∘', '◦'}

	colorized := make([][]bool, rows)
	for i := range colorized {
		colorized[i] = make([]bool, len(lines[i]))
	}

	smokeFront := -5

	drawChar := func(sb *strings.Builder, row, col int, ch rune, color Color) {
		if row < 0 || row >= rows || col < 0 || col >= cols {
			return
		}
		absoluteRow := startRow + row + 1
		if absoluteRow < 1 || absoluteRow > termHeight {
			return
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absoluteRow, col+1))
		sb.WriteString(color.String())
		sb.WriteRune(ch)
	}

	for frame := 0; frame < cols+30; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absoluteRow := startRow + i + 1
			if absoluteRow >= 1 && absoluteRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		smokeFront = frame - 5

		for row := 0; row < rows; row++ {
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					distFromSmoke := col - smokeFront

					if distFromSmoke < 0 {
						colorized[row][col] = true
						gradProgress := float64(row*cols+col) / float64(rows*cols)
						colorIdx := int(gradProgress * float64(len(gradient)-1))
						if colorIdx >= len(gradient) {
							colorIdx = len(gradient) - 1
						}
						drawChar(&sb, row, col, rune(lines[row][col]), gradient[colorIdx])
					} else if distFromSmoke >= 0 && distFromSmoke < 8 {
						if rand.Float64() < smokeDensity {
							sym := smokeSymbols[rand.Intn(len(smokeSymbols))]
							color := smokeColors[rand.Intn(len(smokeColors))]
							drawChar(&sb, row, col, sym, color)
						}
					}
				} else if col < len(lines[row]) {
					distFromSmoke := col - smokeFront
					if distFromSmoke >= 0 && distFromSmoke < 8 {
						if rand.Float64() < smokeDensity*0.5 {
							sym := smokeSymbols[rand.Intn(len(smokeSymbols))]
							color := smokeColors[rand.Intn(len(smokeColors))]
							drawChar(&sb, row, col, sym, color)
						}
					}
				}
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	for frame := 0; frame < 20; frame++ {
		var sb strings.Builder

		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					if colorized[row][col] {
						gradProgress := float64(row*cols+col) / float64(rows*cols)
						colorIdx := int(gradProgress * float64(len(gradient)-1))
						if colorIdx >= len(gradient) {
							colorIdx = len(gradient) - 1
						}
						sb.WriteString(gradient[colorIdx].String())
						sb.WriteRune(rune(lines[row][col]))
					} else if rand.Float64() < float64(20-frame)/40.0 {
						sym := smokeSymbols[rand.Intn(len(smokeSymbols))]
						color := smokeColors[rand.Intn(len(smokeColors))]
						sb.WriteString(color.String())
						sb.WriteRune(sym)
					} else {
						sb.WriteByte(' ')
					}
				} else {
					sb.WriteByte(' ')
				}
			}
			sb.WriteString("\x1b[K")
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				gradProgress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// SLIDE EFFECT
// ============================================================================

type SlideEffect struct{}

func (e SlideEffect) Name() string        { return "slide" }
func (e SlideEffect) Description() string { return "Slide characters into view from outside the terminal." }
func (e SlideEffect) Run(text string, args map[string]interface{}) {
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"00FF87", "00D4FF", "B700FF"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)
	slideSpeed := getFloatArg(args, "slide-speed", 1.0)
	slideDirection := getStringArg(args, "slide-direction", "left")

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	type SlideChar struct {
		char      rune
		targetRow int
		targetCol int
		startCol  int
	}

	chars := make([]SlideChar, 0)
	for row := 0; row < rows; row++ {
		for col := 0; col < len(lines[row]); col++ {
			if lines[row][col] != ' ' {
				startCol := -cols - rand.Intn(10)
				if slideDirection == "right" {
					startCol = cols + rand.Intn(10)
				}
				chars = append(chars, SlideChar{
					char:      rune(lines[row][col]),
					targetRow: row,
					targetCol: col,
					startCol:  startCol,
				})
			}
		}
	}

	drawChar := func(sb *strings.Builder, row, col int, ch rune, color Color) {
		if row < 0 || row >= rows || col < 0 || col >= cols {
			return
		}
		absoluteRow := startRow + row + 1
		if absoluteRow < 1 || absoluteRow > termHeight {
			return
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absoluteRow, col+1))
		sb.WriteString(color.String())
		sb.WriteRune(ch)
	}

	totalFrames := int(float64(cols+10) / slideSpeed)
	for frame := 0; frame <= totalFrames; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absoluteRow := startRow + i + 1
			if absoluteRow >= 1 && absoluteRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		progress := float64(frame) / float64(totalFrames)
		if progress > 1 {
			progress = 1
		}

		easedProgress := easeOutBack(progress)
		if easedProgress > 1 {
			easedProgress = 1
		}

		for _, ch := range chars {
			currentCol := float64(ch.startCol)*(1-easedProgress) + float64(ch.targetCol)*easedProgress
			colInt := int(currentCol)

			if colInt >= 0 && colInt < cols {
				gradProgress := float64(ch.targetRow*cols+ch.targetCol) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				color := gradient[colorIdx]
				drawChar(&sb, ch.targetRow, colInt, ch.char, color)
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				gradProgress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// COLORSHIFT EFFECT
// ============================================================================

type ColorShiftEffect struct{}

func (e ColorShiftEffect) Name() string        { return "colorshift" }
func (e ColorShiftEffect) Description() string { return "Display a gradient that shifts colors across the terminal." }
func (e ColorShiftEffect) Run(text string, args map[string]interface{}) {
	gradientStops := getColorSliceArg(args, "gradient-stops", []string{"FF0000", "FFFF00", "00FF00", "00FFFF", "0000FF", "FF00FF"})
	gradientSteps := getIntArg(args, "gradient-steps", 60)
	shiftSpeed := getFloatArg(args, "shift-speed", 1.0)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(gradientStops, gradientSteps)

	for frame := 0; frame < 120; frame++ {
		var sb strings.Builder

		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					pos := (col + row + frame*int(shiftSpeed)) % gradientSteps
					if pos < 0 {
						pos += gradientSteps
					}
					color := gradient[pos]
					sb.WriteString(color.String())
					sb.WriteRune(rune(lines[row][col]))
				} else {
					sb.WriteByte(' ')
				}
			}
			sb.WriteString("\x1b[K")
		}
		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				pos := (col + row) % gradientSteps
				color := gradient[pos]
				sb.WriteString(color.String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// HIGHLIGHT EFFECT
// ============================================================================

type HighlightEffect struct{}

func (e HighlightEffect) Name() string        { return "highlight" }
func (e HighlightEffect) Description() string { return "Run a specular highlight across the text." }
func (e HighlightEffect) Run(text string, args map[string]interface{}) {
	highlightColor := getColorArg(args, "highlight-color", "ffffff")
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"FF1493", "FF69B4", "FFB6C1"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)
	highlightWidth := getIntArg(args, "highlight-width", 5)
	highlightSpeed := getFloatArg(args, "highlight-speed", 1.0)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	totalFrames := int(float64(cols+highlightWidth*2) / highlightSpeed)
	for frame := 0; frame <= totalFrames; frame++ {
		var sb strings.Builder

		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					highlightPos := int(float64(frame) * highlightSpeed)
					dist := abs(col - highlightPos)

					if dist == 0 {
						sb.WriteString(highlightColor.String())
						sb.WriteRune(rune(lines[row][col]))
					} else if dist < highlightWidth {
						intensity := 1.0 - float64(dist)/float64(highlightWidth)
						baseColor := gradient[0]
						blendedColor := Color{
							R: uint8(float64(highlightColor.R)*intensity + float64(baseColor.R)*(1-intensity)),
							G: uint8(float64(highlightColor.G)*intensity + float64(baseColor.G)*(1-intensity)),
							B: uint8(float64(highlightColor.B)*intensity + float64(baseColor.B)*(1-intensity)),
						}
						sb.WriteString(blendedColor.String())
						sb.WriteRune(rune(lines[row][col]))
					} else {
						gradProgress := float64(row*cols+col) / float64(rows*cols)
						colorIdx := int(gradProgress * float64(len(gradient)-1))
						if colorIdx >= len(gradient) {
							colorIdx = len(gradient) - 1
						}
						sb.WriteString(gradient[colorIdx].String())
						sb.WriteRune(rune(lines[row][col]))
					}
				} else {
					sb.WriteByte(' ')
				}
			}
			sb.WriteString("\x1b[K")
		}
		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				gradProgress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// LASERETCH EFFECT (MELHORADO COM FAÍSCAS)
// ============================================================================

type LaserEtchEffect struct{}

func (e LaserEtchEffect) Name() string        { return "laseretch" }
func (e LaserEtchEffect) Description() string { return "A laser etches characters onto the terminal with sparks." }
func (e LaserEtchEffect) Run(text string, args map[string]interface{}) {
	laserColor := getColorArg(args, "laser-color", "FF0000")
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"FF0000", "FF6600", "FFCC00"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)
	laserSpeed := getFloatArg(args, "laser-speed", 1.0)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	etched := make([][]bool, rows)
	for i := range etched {
		etched[i] = make([]bool, cols)
	}

	sparkChars := []rune{'\'', '.', ';', '*', '+', '·', '°', '•', '∙', '∘'}
	sparkColors := []Color{
		{255, 255, 255},
		{255, 200, 100},
		{255, 150, 50},
		{255, 100, 0},
	}

	type Spark struct {
		row   int
		col   int
		char  rune
		color Color
		life  int
	}

	sparkList := make([]Spark, 0)

	drawChar := func(sb *strings.Builder, row, col int, ch rune, color Color) {
		if row < 0 || row >= rows || col < 0 || col >= cols {
			return
		}
		absoluteRow := startRow + row + 1
		if absoluteRow < 1 || absoluteRow > termHeight {
			return
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absoluteRow, col+1))
		sb.WriteString(color.String())
		sb.WriteRune(ch)
	}

	generateSparks := func(laserCol int) {
		numSparks := 3 + rand.Intn(6)
		for i := 0; i < numSparks; i++ {
			sparkCol := laserCol + rand.Intn(3) - 1
			if sparkCol < 0 || sparkCol >= cols {
				continue
			}
			sparkRow := rand.Intn(rows)
			sparkChar := sparkChars[rand.Intn(len(sparkChars))]
			sparkColor := sparkColors[rand.Intn(len(sparkColors))]
			life := 1 + rand.Intn(3)

			sparkList = append(sparkList, Spark{
				row:   sparkRow,
				col:   sparkCol,
				char:  sparkChar,
				color: sparkColor,
				life:  life,
			})
		}
	}

	totalFrames := int(float64(cols) / laserSpeed)
	for frame := 0; frame <= totalFrames; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absoluteRow := startRow + i + 1
			if absoluteRow >= 1 && absoluteRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		laserCol := int(float64(frame) * laserSpeed)

		if laserCol >= 0 && laserCol < cols {
			for row := 0; row < rows; row++ {
				if laserCol < len(lines[row]) && lines[row][laserCol] != ' ' {
					etched[row][laserCol] = true
				}
			}

			generateSparks(laserCol)
		}

		for row := 0; row < rows; row++ {
			for col := 0; col < cols; col++ {
				if etched[row][col] {
					gradProgress := float64(row*cols+col) / float64(rows*cols)
					colorIdx := int(gradProgress * float64(len(gradient)-1))
					if colorIdx >= len(gradient) {
						colorIdx = len(gradient) - 1
					}
					drawChar(&sb, row, col, rune(lines[row][col]), gradient[colorIdx])
				}
			}
		}

		if laserCol >= 0 && laserCol < cols {
			for row := 0; row < rows; row++ {
				drawChar(&sb, row, laserCol, '|', Color{255, 255, 255})
			}
		}

		newSparkList := make([]Spark, 0)
		for _, spark := range sparkList {
			if spark.life > 0 {
				drawChar(&sb, spark.row, spark.col, spark.char, spark.color)
				spark.life--
				if spark.life > 0 {
					newSparkList = append(newSparkList, spark)
				}
			}
		}
		sparkList = newSparkList

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	for frame := 0; frame < 10; frame++ {
		var sb strings.Builder

		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					if frame%2 == 0 {
						sb.WriteString(laserColor.String())
					} else {
						gradProgress := float64(row*cols+col) / float64(rows*cols)
						colorIdx := int(gradProgress * float64(len(gradient)-1))
						if colorIdx >= len(gradient) {
							colorIdx = len(gradient) - 1
						}
						sb.WriteString(gradient[colorIdx].String())
					}
					sb.WriteRune(rune(lines[row][col]))
				} else {
					sb.WriteByte(' ')
				}
			}
			sb.WriteString("\x1b[K")
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				gradProgress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// RINGS EFFECT
// ============================================================================

type RingsEffect struct{}

func (e RingsEffect) Name() string        { return "rings" }
func (e RingsEffect) Description() string { return "Characters are dispersed and form into spinning rings." }
func (e RingsEffect) Run(text string, args map[string]interface{}) {
	ringColors := getColorSliceArg(args, "ring-colors", []string{"FF00FF", "00FFFF", "FFFF00"})
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"FF1493", "00BFFF", "FFD700"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)
	ringSpeed := getFloatArg(args, "ring-speed", 1.0)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	centerRow := rows / 2
	centerCol := cols / 2

	type RingChar struct {
		char      rune
		targetRow int
		targetCol int
		distance  float64
		angle     float64
	}

	chars := make([]RingChar, 0)
	for row := 0; row < rows; row++ {
		for col := 0; col < len(lines[row]); col++ {
			if lines[row][col] != ' ' {
				dx := float64(col - centerCol)
				dy := float64(row - centerRow)
				distance := math.Sqrt(dx*dx + dy*dy)
				angle := math.Atan2(dy, dx)
				chars = append(chars, RingChar{
					char:      rune(lines[row][col]),
					targetRow: row,
					targetCol: col,
					distance:  distance,
					angle:     angle,
				})
			}
		}
	}

	drawChar := func(sb *strings.Builder, row, col int, ch rune, color Color) {
		if row < 0 || row >= rows || col < 0 || col >= cols {
			return
		}
		absoluteRow := startRow + row + 1
		if absoluteRow < 1 || absoluteRow > termHeight {
			return
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absoluteRow, col+1))
		sb.WriteString(color.String())
		sb.WriteRune(ch)
	}

	for frame := 0; frame < 60; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absoluteRow := startRow + i + 1
			if absoluteRow >= 1 && absoluteRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		rotation := float64(frame) * ringSpeed * 0.1

		for _, ch := range chars {
			newAngle := ch.angle + rotation
			newX := centerCol + int(ch.distance*math.Cos(newAngle))
			newY := centerRow + int(ch.distance*math.Sin(newAngle))

			if newX >= 0 && newX < cols && newY >= 0 && newY < rows {
				colorIdx := int(ch.distance) % len(ringColors)
				color := ringColors[colorIdx]
				drawChar(&sb, newY, newX, ch.char, color)
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	for frame := 0; frame < 30; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absoluteRow := startRow + i + 1
			if absoluteRow >= 1 && absoluteRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		progress := float64(frame) / 30.0
		rotation := float64(60) * ringSpeed * 0.1 * (1 - progress)

		for _, ch := range chars {
			newAngle := ch.angle + rotation
			ringX := centerCol + int(ch.distance*math.Cos(newAngle))
			ringY := centerRow + int(ch.distance*math.Sin(newAngle))

			currentX := float64(ringX)*(1-progress) + float64(ch.targetCol)*progress
			currentY := float64(ringY)*(1-progress) + float64(ch.targetRow)*progress

			if int(currentX) >= 0 && int(currentX) < cols && int(currentY) >= 0 && int(currentY) < rows {
				if progress > 0.8 {
					gradProgress := float64(ch.targetRow*cols+ch.targetCol) / float64(rows*cols)
					colorIdx := int(gradProgress * float64(len(gradient)-1))
					if colorIdx >= len(gradient) {
						colorIdx = len(gradient) - 1
					}
					drawChar(&sb, int(currentY), int(currentX), ch.char, gradient[colorIdx])
				} else {
					colorIdx := int(ch.distance) % len(ringColors)
					color := ringColors[colorIdx]
					drawChar(&sb, int(currentY), int(currentX), ch.char, color)
				}
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				gradProgress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// SPRAY EFFECT
// ============================================================================

type SprayEffect struct{}

func (e SprayEffect) Name() string        { return "spray" }
func (e SprayEffect) Description() string { return "Draws the characters spawning at varying rates from a single point." }
func (e SprayEffect) Run(text string, args map[string]interface{}) {
	sprayColors := getColorSliceArg(args, "spray-colors", []string{"FF6B6B", "4ECDC4", "45B7D1", "FFA07A"})
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"FF6B6B", "4ECDC4", "45B7D1"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)
	sprayDensity := getFloatArg(args, "spray-density", 0.5)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	originRow := 0
	originCol := 0

	sprayed := make([][]bool, rows)
	for i := range sprayed {
		sprayed[i] = make([]bool, cols)
	}

	drawChar := func(sb *strings.Builder, row, col int, ch rune, color Color) {
		if row < 0 || row >= rows || col < 0 || col >= cols {
			return
		}
		absoluteRow := startRow + row + 1
		if absoluteRow < 1 || absoluteRow > termHeight {
			return
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absoluteRow, col+1))
		sb.WriteString(color.String())
		sb.WriteRune(ch)
	}

	for frame := 0; frame < 100; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absoluteRow := startRow + i + 1
			if absoluteRow >= 1 && absoluteRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		for row := 0; row < rows; row++ {
			for col := 0; col < cols; col++ {
				if sprayed[row][col] {
					gradProgress := float64(row*cols+col) / float64(rows*cols)
					colorIdx := int(gradProgress * float64(len(gradient)-1))
					if colorIdx >= len(gradient) {
						colorIdx = len(gradient) - 1
					}
					drawChar(&sb, row, col, rune(lines[row][col]), gradient[colorIdx])
				}
			}
		}

		charsPerFrame := int(float64(rows*cols) * sprayDensity * 0.05)
		for i := 0; i < charsPerFrame; i++ {
			for attempts := 0; attempts < 10; attempts++ {
				row := rand.Intn(rows)
				col := rand.Intn(cols)
				if col < len(lines[row]) && lines[row][col] != ' ' && !sprayed[row][col] {
					sprayed[row][col] = true
					color := sprayColors[rand.Intn(len(sprayColors))]
					drawChar(&sb, row, col, rune(lines[row][col]), color)
					break
				}
			}
		}

		drawChar(&sb, originRow, originCol, '*', Color{255, 255, 255})

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)

		allSprayed := true
		for row := 0; row < rows; row++ {
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' && !sprayed[row][col] {
					allSprayed = false
					break
				}
			}
			if !allSprayed {
				break
			}
		}
		if allSprayed {
			break
		}
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				gradProgress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// BUBBLES EFFECT
// ============================================================================

type BubblesEffect struct{}

func (e BubblesEffect) Name() string        { return "bubbles" }
func (e BubblesEffect) Description() string { return "Characters are formed into bubbles that float up and pop." }
func (e BubblesEffect) Run(text string, args map[string]interface{}) {
	bubbleColors := getColorSliceArg(args, "bubble-colors", []string{"87CEEB", "ADD8E6", "B0E0E6", "E0FFFF"})
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"87CEEB", "ADD8E6", "B0E0E6"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)
	bubbleSpeed := getFloatArg(args, "bubble-speed", 0.5)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	type Bubble struct {
		char      rune
		targetRow int
		targetCol int
		currentY  float64
		wobble    float64
		popped    bool
		color     Color
	}

	bubbles := make([]Bubble, 0)
	for row := 0; row < rows; row++ {
		for col := 0; col < len(lines[row]); col++ {
			if lines[row][col] != ' ' {
				bubbles = append(bubbles, Bubble{
					char:      rune(lines[row][col]),
					targetRow: row,
					targetCol: col,
					currentY:  float64(rows),
					wobble:    rand.Float64() * 2 * math.Pi,
					popped:    false,
					color:     bubbleColors[rand.Intn(len(bubbleColors))],
				})
			}
		}
	}

	drawChar := func(sb *strings.Builder, row, col int, ch rune, color Color) {
		if row < 0 || row >= rows || col < 0 || col >= cols {
			return
		}
		absoluteRow := startRow + row + 1
		if absoluteRow < 1 || absoluteRow > termHeight {
			return
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absoluteRow, col+1))
		sb.WriteString(color.String())
		sb.WriteRune(ch)
	}

	for frame := 0; frame < 80; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absoluteRow := startRow + i + 1
			if absoluteRow >= 1 && absoluteRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		allPopped := true
		for i := range bubbles {
			if !bubbles[i].popped {
				allPopped = false

				bubbles[i].currentY -= bubbleSpeed
				bubbles[i].wobble += 0.1

				wobbleOffset := int(math.Sin(bubbles[i].wobble) * 1.5)
				currentCol := bubbles[i].targetCol + wobbleOffset
				currentRow := int(bubbles[i].currentY)

				if currentRow >= 0 && currentRow < rows && currentCol >= 0 && currentCol < cols {
					if currentCol > 0 {
						drawChar(&sb, currentRow, currentCol-1, '(', bubbles[i].color)
					}
					drawChar(&sb, currentRow, currentCol, bubbles[i].char, Color{255, 255, 255})
					if currentCol < cols-1 {
						drawChar(&sb, currentRow, currentCol+1, ')', bubbles[i].color)
					}
				}

				if currentRow <= bubbles[i].targetRow {
					bubbles[i].popped = true
				}
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)

		if allPopped {
			break
		}
	}

	for frame := 0; frame < 20; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absoluteRow := startRow + i + 1
			if absoluteRow >= 1 && absoluteRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		progress := float64(frame) / 20.0

		for _, bubble := range bubbles {
			gradProgress := float64(bubble.targetRow*cols+bubble.targetCol) / float64(rows*cols)
			colorIdx := int(gradProgress * float64(len(gradient)-1))
			if colorIdx >= len(gradient) {
				colorIdx = len(gradient) - 1
			}

			if progress < 0.5 {
				drawChar(&sb, bubble.targetRow, bubble.targetCol, bubble.char, bubble.color)
			} else {
				drawChar(&sb, bubble.targetRow, bubble.targetCol, bubble.char, gradient[colorIdx])
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				gradProgress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// SPOTLIGHTS EFFECT (CORRIGIDO)
// ============================================================================

type SpotlightsEffect struct{}

func (e SpotlightsEffect) Name() string        { return "spotlights" }
func (e SpotlightsEffect) Description() string { return "Spotlights search the text area, illuminating characters." }
func (e SpotlightsEffect) Run(text string, args map[string]interface{}) {
	spotlightColor := getColorArg(args, "spotlight-color", "FFFFE0")
	finalGradientStops := getColorSliceArg(args, "final-gradient-stops", []string{"FFD700", "FFA500", "FF6347"})
	finalGradientSteps := getIntArg(args, "final-gradient-steps", 12)
	spotlightRadius := getIntArg(args, "spotlight-radius", 4)
	spotlightSpeed := getFloatArg(args, "spotlight-speed", 1.0)

	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	gradient := generateGradient(finalGradientStops, finalGradientSteps)

	type Spotlight struct {
		x     float64
		y     float64
		vx    float64
		vy    float64
		color Color
	}

	spotlights := []Spotlight{
		{
			x:     float64(cols / 4),
			y:     float64(rows / 4),
			vx:    1.5 * spotlightSpeed,
			vy:    1.0 * spotlightSpeed,
			color: Color{255, 255, 200},
		},
		{
			x:     float64(cols / 2),
			y:     float64(rows / 2),
			vx:    -1.2 * spotlightSpeed,
			vy:    1.3 * spotlightSpeed,
			color: Color{255, 220, 180},
		},
		{
			x:     float64(3 * cols / 4),
			y:     float64(3 * rows / 4),
			vx:    1.0 * spotlightSpeed,
			vy:    -1.5 * spotlightSpeed,
			color: Color{255, 200, 150},
		},
	}

	revealed := make([][]bool, rows)
	for i := range revealed {
		revealed[i] = make([]bool, cols)
	}

	drawChar := func(sb *strings.Builder, row, col int, ch rune, color Color) {
		if row < 0 || row >= rows || col < 0 || col >= cols {
			return
		}
		absoluteRow := startRow + row + 1
		if absoluteRow < 1 || absoluteRow > termHeight {
			return
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;%dH", absoluteRow, col+1))
		sb.WriteString(color.String())
		sb.WriteRune(ch)
	}

	for frame := 0; frame < 150; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absoluteRow := startRow + i + 1
			if absoluteRow >= 1 && absoluteRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		for i := range spotlights {
			spotlights[i].x += spotlights[i].vx
			spotlights[i].y += spotlights[i].vy

			if spotlights[i].x < 0 || spotlights[i].x >= float64(cols) {
				spotlights[i].vx = -spotlights[i].vx
				spotlights[i].x += spotlights[i].vx
			}
			if spotlights[i].y < 0 || spotlights[i].y >= float64(rows) {
				spotlights[i].vy = -spotlights[i].vy
				spotlights[i].y += spotlights[i].vy
			}
		}

		for row := 0; row < rows; row++ {
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					illuminated := false
					var closestDist float64 = 999999
					var closestSpotlight Spotlight

					for _, spot := range spotlights {
						dx := float64(col) - spot.x
						dy := float64(row) - spot.y
						dist := math.Sqrt(dx*dx + dy*dy)

						if dist <= float64(spotlightRadius) {
							illuminated = true
							if dist < closestDist {
								closestDist = dist
								closestSpotlight = spot
							}
						}
					}

					if illuminated {
						revealed[row][col] = true
						drawChar(&sb, row, col, rune(lines[row][col]), closestSpotlight.color)
					} else if revealed[row][col] {
						gradProgress := float64(row*cols+col) / float64(rows*cols)
						colorIdx := int(gradProgress * float64(len(gradient)-1))
						if colorIdx >= len(gradient) {
							colorIdx = len(gradient) - 1
						}
						drawChar(&sb, row, col, rune(lines[row][col]), gradient[colorIdx])
					}
				}
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)

		allRevealed := true
		for row := 0; row < rows; row++ {
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' && !revealed[row][col] {
					allRevealed = false
					break
				}
			}
			if !allRevealed {
				break
			}
		}
		if allRevealed {
			break
		}
	}

	for frame := 0; frame < 20; frame++ {
		var sb strings.Builder

		for i := 0; i < rows; i++ {
			absoluteRow := startRow + i + 1
			if absoluteRow >= 1 && absoluteRow <= termHeight {
				sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absoluteRow))
				sb.WriteString(strings.Repeat(" ", cols))
				sb.WriteString("\x1b[K")
			}
		}

		progress := float64(frame) / 20.0

		for row := 0; row < rows; row++ {
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) && lines[row][col] != ' ' {
					gradProgress := float64(row*cols+col) / float64(rows*cols)
					colorIdx := int(gradProgress * float64(len(gradient)-1))
					if colorIdx >= len(gradient) {
						colorIdx = len(gradient) - 1
					}

					if progress < 0.5 {
						drawChar(&sb, row, col, rune(lines[row][col]), spotlightColor)
					} else {
						drawChar(&sb, row, col, rune(lines[row][col]), gradient[colorIdx])
					}
				}
			}
		}

		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/30) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				gradProgress := float64(row*cols+col) / float64(rows*cols)
				colorIdx := int(gradProgress * float64(len(gradient)-1))
				if colorIdx >= len(gradient) {
					colorIdx = len(gradient) - 1
				}
				sb.WriteString(gradient[colorIdx].String())
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// SIMPLE EFFECT
// ============================================================================

type SimpleEffect struct {
	name        string
	description string
}

func (e SimpleEffect) Name() string        { return e.name }
func (e SimpleEffect) Description() string { return e.description }
func (e SimpleEffect) Run(text string, args map[string]interface{}) {
	lines := strings.Split(text, "\n")
	rows := len(lines)
	cols := 0
	for _, line := range lines {
		if len(line) > cols {
			cols = len(line)
		}
	}

	startRow := allocateSpace(rows)
	_, termHeight := getTerminalSize()
	ts := &termState{startRow: startRow, numRows: rows}
	ts.enter()
	defer ts.exit()

	for frame := 0; frame < 30; frame++ {
		var sb strings.Builder
		for row := 0; row < rows; row++ {
			absRow := startRow + row + 1
			if absRow < 1 || absRow > termHeight {
				continue
			}
			sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
			for col := 0; col < cols; col++ {
				if col < len(lines[row]) {
					if rand.Float64() < 0.1 {
						sb.WriteByte('.')
					} else {
						sb.WriteRune(rune(lines[row][col]))
					}
				} else {
					sb.WriteByte(' ')
				}
			}
			sb.WriteString("\x1b[K")
		}
		sb.WriteString(ansiReset)
		fmt.Print(sb.String())
		time.Sleep(time.Duration(1000/60) * time.Millisecond)
	}

	var sb strings.Builder
	for row := 0; row < rows; row++ {
		absRow := startRow + row + 1
		if absRow < 1 || absRow > termHeight {
			continue
		}
		sb.WriteString(fmt.Sprintf("\x1b[%d;1H", absRow))
		for col := 0; col < cols; col++ {
			if col < len(lines[row]) {
				sb.WriteRune(rune(lines[row][col]))
			}
		}
		sb.WriteString("\x1b[K")
	}
	sb.WriteString(ansiReset)
	fmt.Print(sb.String())
}

// ============================================================================
// Argument helpers
// ============================================================================

func getIntArg(args map[string]interface{}, key string, defaultVal int) int {
	if val, ok := args[key]; ok {
		if v, ok := val.(int); ok {
			return v
		}
	}
	return defaultVal
}

func getFloatArg(args map[string]interface{}, key string, defaultVal float64) float64 {
	if val, ok := args[key]; ok {
		if v, ok := val.(float64); ok {
			return v
		}
	}
	return defaultVal
}

func getStringArg(args map[string]interface{}, key string, defaultVal string) string {
	if val, ok := args[key]; ok {
		if v, ok := val.(string); ok {
			return v
		}
	}
	return defaultVal
}

func getStringSliceArg(args map[string]interface{}, key string, defaultVal []string) []string {
	if val, ok := args[key]; ok {
		if v, ok := val.([]string); ok {
			return v
		}
	}
	return defaultVal
}

func getColorArg(args map[string]interface{}, key string, defaultVal string) Color {
	if val, ok := args[key]; ok {
		if v, ok := val.(string); ok {
			return ParseColor(v)
		}
	}
	return ParseColor(defaultVal)
}

func getColorSliceArg(args map[string]interface{}, key string, defaultVal []string) []Color {
	if val, ok := args[key]; ok {
		if v, ok := val.([]string); ok {
			colors := make([]Color, len(v))
			for i, c := range v {
				colors[i] = ParseColor(c)
			}
			return colors
		}
	}
	colors := make([]Color, len(defaultVal))
	for i, c := range defaultVal {
		colors[i] = ParseColor(c)
	}
	return colors
}

// ============================================================================
// Usage
// ============================================================================

func usage() {
	fmt.Fprintf(os.Stderr, `tte - terminaltexteffects clone in Go

Usage:
  tte <effect> [options]
  command | tte <effect> [options]

Effects (implementados - 21):
  decrypt            Display a movie style decryption effect
  rain               Rain characters from the top of the canvas
  expand             Expands the text from a single point
  scattered          Text is scattered across the canvas and moves into position
  waves              Waves travel across the terminal leaving behind the characters
  blackhole          Characters are consumed by a black hole and explode outwards
  matrix             Matrix digital rain effect
  fireworks          Characters launch and explode like fireworks and fall into place
  beams              Create beams which travel over the canvas illuminating characters
  wipe               Wipes the text across the terminal to reveal characters
  burn               Burns vertically in the canvas
  crumble            Characters crumble into dust, vacuumed up, and reformed
  smoke              Smoke floods the canvas colorizing any characters it crosses
  slide              Slide characters into view from outside the terminal
  colorshift         Display a gradient that shifts colors across the terminal
  highlight          Run a specular highlight across the text
  laseretch          A laser etches characters with sparks
  rings              Characters form into spinning rings
  spray              Characters spawn from a single point
  bubbles            Characters float up in bubbles that pop
  spotlights         Spotlights illuminate the text

Effects (placeholder - aguardando implementação - 16):
  binarypath, bouncyballs, errorcorrect, middleout,
  orbittingvolley, overflow, pour, print, randomsequence,
  slice, swarm, sweep, synthgrid, thunderstorm, unstable, vhstape

Options:
  -h            show this help
  -f FILE       read from file instead of stdin
  --loop        loop the effect
  --max-loops N maximum number of loops

Examples:
  echo 'Hello OpenBSD' | tte decrypt
  echo 'Matrix' | tte matrix
  echo 'Boom!' | tte fireworks
  echo 'Test' | tte laseretch --laser-speed 2.0
  echo 'Test' | tte rings --ring-speed 1.5
  echo 'Test' | tte spray --spray-density 0.7
  echo 'Test' | tte bubbles --bubble-speed 0.8
  echo 'Test' | tte spotlights --spotlight-radius 5
`)
}

// ============================================================================
// Main
// ============================================================================

func main() {
	registerEffect(DecryptEffect{})
	registerEffect(RainEffect{})
	registerEffect(ExpandEffect{})
	registerEffect(ScatteredEffect{})
	registerEffect(WavesEffect{})
	registerEffect(BlackholeEffect{})
	registerEffect(MatrixEffect{})
	registerEffect(FireworksEffect{})
	registerEffect(BeamsEffect{})
	registerEffect(WipeEffect{})
	registerEffect(BurnEffect{})
	registerEffect(CrumbleEffect{})
	registerEffect(SmokeEffect{})
	registerEffect(SlideEffect{})
	registerEffect(ColorShiftEffect{})
	registerEffect(HighlightEffect{})
	registerEffect(LaserEtchEffect{})
	registerEffect(RingsEffect{})
	registerEffect(SprayEffect{})
	registerEffect(BubblesEffect{})
	registerEffect(SpotlightsEffect{})

	registerEffect(SimpleEffect{name: "binarypath", description: "Binary representations move to position"})
	registerEffect(SimpleEffect{name: "bouncyballs", description: "Characters bounce like balls"})
	registerEffect(SimpleEffect{name: "errorcorrect", description: "Error correction effect"})
	registerEffect(SimpleEffect{name: "middleout", description: "Expand from middle"})
	registerEffect(SimpleEffect{name: "orbittingvolley", description: "Orbiting volley effect"})
	registerEffect(SimpleEffect{name: "overflow", description: "Overflow scroll"})
	registerEffect(SimpleEffect{name: "pour", description: "Pour characters"})
	registerEffect(SimpleEffect{name: "print", description: "Print effect"})
	registerEffect(SimpleEffect{name: "randomsequence", description: "Random sequence"})
	registerEffect(SimpleEffect{name: "slice", description: "Slice and slide"})
	registerEffect(SimpleEffect{name: "swarm", description: "Swarm effect"})
	registerEffect(SimpleEffect{name: "sweep", description: "Sweep effect"})
	registerEffect(SimpleEffect{name: "synthgrid", description: "Synth grid effect"})
	registerEffect(SimpleEffect{name: "thunderstorm", description: "Thunderstorm effect"})
	registerEffect(SimpleEffect{name: "unstable", description: "Unstable effect"})
	registerEffect(SimpleEffect{name: "vhstape", description: "VHS tape effect"})

	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	if os.Args[1] == "-h" || os.Args[1] == "--help" {
		usage()
		os.Exit(0)
	}

	args := make(map[string]interface{})
	file := ""
	loop := false
	maxLoops := 0
	effectName := ""

	for i := 1; i < len(os.Args); i++ {
		arg := os.Args[i]
		if effectName == "" && !strings.HasPrefix(arg, "-") {
			effectName = arg
			continue
		}
		if arg == "-f" && i+1 < len(os.Args) {
			file = os.Args[i+1]
			i++
		} else if arg == "--loop" {
			loop = true
		} else if arg == "--max-loops" && i+1 < len(os.Args) {
			maxLoops, _ = strconv.Atoi(os.Args[i+1])
			i++
		} else if strings.HasPrefix(arg, "--") || strings.HasPrefix(arg, "-") {
			key := strings.TrimLeft(arg, "-")
			if i+1 < len(os.Args) && !strings.HasPrefix(os.Args[i+1], "-") {
				val := os.Args[i+1]
				if intVal, err := strconv.Atoi(val); err == nil {
					args[key] = intVal
				} else if floatVal, err := strconv.ParseFloat(val, 64); err == nil {
					args[key] = floatVal
				} else {
					values := []string{val}
					for i+1 < len(os.Args) && !strings.HasPrefix(os.Args[i+1], "-") {
						i++
						values = append(values, os.Args[i])
					}
					if len(values) > 1 {
						args[key] = values
					} else {
						args[key] = val
					}
				}
				i++
			} else {
				args[key] = true
			}
		}
	}

	if effectName == "" {
		fmt.Fprintln(os.Stderr, "Error: no effect specified")
		usage()
		os.Exit(1)
	}

	effect, exists := effects[effectName]
	if !exists {
		fmt.Fprintf(os.Stderr, "Unknown effect: %s\n", effectName)
		usage()
		os.Exit(1)
	}

	var text string
	if file != "" {
		data, err := os.ReadFile(file)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error reading %s: %v\n", file, err)
			os.Exit(1)
		}
		text = string(data)
	} else {
		stat, _ := os.Stdin.Stat()
		if (stat.Mode() & os.ModeCharDevice) != 0 {
			fmt.Fprintln(os.Stderr, "Error: no input. Pipe data or use -f FILE")
			fmt.Fprintln(os.Stderr, "Example: echo 'Hello' | tte decrypt")
			os.Exit(1)
		}
		data, err := io.ReadAll(os.Stdin)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error reading stdin: %v\n", err)
			os.Exit(1)
		}
		text = string(data)
	}

	text = strings.TrimSpace(text)
	if text == "" {
		fmt.Fprintln(os.Stderr, "Error: empty input")
		os.Exit(1)
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		fmt.Print(ansiReset + ansiShowCursor)
		os.Exit(130)
	}()

	if loop {
		loopCount := 0
		for {
			effect.Run(text, args)
			loopCount++
			if maxLoops > 0 && loopCount >= maxLoops {
				break
			}
		}
	} else {
		effect.Run(text, args)
	}
}
GOEOF

echo "Building binary..."
CGO_ENABLED=0 GOFLAGS="-trimpath" \
    go build -ldflags="-s -w" -o "$BINARY_NAME" .

echo "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp "$BINARY_NAME" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/$BINARY_NAME"

echo ""
echo "=== Build complete! ==="
echo "Binary installed to: $INSTALL_DIR/$BINARY_NAME"
echo ""
echo "Efeitos implementados (21):"
echo "  decrypt, rain, expand, scattered, waves, blackhole,"
echo "  matrix, fireworks, beams, wipe, burn, crumble,"
echo "  smoke, slide, colorshift, highlight, laseretch,"
echo "  rings, spray, bubbles, spotlights"
echo ""
echo "Efeitos aguardando implementação (16):"
echo "  binarypath, bouncyballs, errorcorrect, middleout,"
echo "  orbittingvolley, overflow, pour, print, randomsequence,"
echo "  slice, swarm, sweep, synthgrid, thunderstorm, unstable, vhstape"
echo ""
echo "Correção aplicada:"
echo "  - spotlights: CORRIGIDO (erro de compilação resolvido)"

cd /
rm -rf "$BUILD_DIR"

echo ""
echo "Build directory cleaned up."
