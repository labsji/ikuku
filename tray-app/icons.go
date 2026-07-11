package main

// Icon data — 16x16 solid colored circles as ICO format

// Grey icon (installing)
var iconGrey = generateIcon(128, 128, 128)

// Amber icon (ready, not activated)
var iconAmber = generateIcon(255, 191, 0)

// Green icon (active)
var iconGreen = generateIcon(76, 175, 80)

// Red icon (error)
var iconRed = generateIcon(244, 67, 54)

// generateIcon creates a minimal 16x16 ICO with a solid colored circle
func generateIcon(r, g, b byte) []byte {
	width := 16
	height := 16

	// ICO header (6 bytes)
	header := []byte{
		0, 0, // reserved
		1, 0, // type: icon
		1, 0, // count: 1 image
	}

	// Pixel data size
	pixelSize := width * height * 4
	maskSize := width * height / 8
	imageSize := 40 + pixelSize + maskSize

	// Directory entry (16 bytes)
	dir := []byte{
		byte(width), byte(height), // dimensions
		0,    // color palette
		0,    // reserved
		1, 0, // color planes
		32, 0, // bits per pixel
		byte(imageSize), byte(imageSize >> 8), byte(imageSize >> 16), byte(imageSize >> 24),
		22, 0, 0, 0, // offset to image data (6 + 16 = 22)
	}

	// BITMAPINFOHEADER (40 bytes)
	bmpHeader := make([]byte, 40)
	bmpHeader[0] = 40 // header size
	bmpHeader[4] = byte(width)
	bmpHeader[8] = byte(height * 2) // doubled for AND mask
	bmpHeader[12] = 1               // planes
	bmpHeader[14] = 32              // bpp

	// Pixel data (BGRA, bottom-to-top)
	pixels := make([]byte, pixelSize)
	for i := 0; i < width*height; i++ {
		x := i % width
		y := i / width
		cx, cy := width/2, height/2
		dx, dy := x-cx, y-cy
		if dx*dx+dy*dy <= (width/2-1)*(height/2-1) {
			pixels[i*4] = b     // B
			pixels[i*4+1] = g   // G
			pixels[i*4+2] = r   // R
			pixels[i*4+3] = 255 // A
		} else {
			pixels[i*4+3] = 0 // transparent
		}
	}

	// AND mask (1bpp, all zeros = fully visible)
	mask := make([]byte, maskSize)

	// Combine
	ico := make([]byte, 0, 6+16+40+pixelSize+maskSize)
	ico = append(ico, header...)
	ico = append(ico, dir...)
	ico = append(ico, bmpHeader...)
	ico = append(ico, pixels...)
	ico = append(ico, mask...)

	return ico
}
