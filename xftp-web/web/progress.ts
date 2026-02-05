const SIZE = 120
const LINE_WIDTH = 8
const RADIUS = (SIZE - LINE_WIDTH) / 2
const CENTER = SIZE / 2
const BG_COLOR = '#e0e0e0'
const FG_COLOR = '#3b82f6'

export interface ProgressRing {
  canvas: HTMLCanvasElement
  update(fraction: number): void
}

export function createProgressRing(): ProgressRing {
  const canvas = document.createElement('canvas')
  canvas.width = SIZE * devicePixelRatio
  canvas.height = SIZE * devicePixelRatio
  canvas.style.width = SIZE + 'px'
  canvas.style.height = SIZE + 'px'
  canvas.className = 'progress-ring'
  const ctx = canvas.getContext('2d')!
  ctx.scale(devicePixelRatio, devicePixelRatio)

  function draw(fraction: number) {
    ctx.clearRect(0, 0, SIZE, SIZE)
    // Background arc
    ctx.beginPath()
    ctx.arc(CENTER, CENTER, RADIUS, 0, 2 * Math.PI)
    ctx.strokeStyle = BG_COLOR
    ctx.lineWidth = LINE_WIDTH
    ctx.lineCap = 'round'
    ctx.stroke()
    // Foreground arc
    if (fraction > 0) {
      ctx.beginPath()
      ctx.arc(CENTER, CENTER, RADIUS, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * fraction)
      ctx.strokeStyle = FG_COLOR
      ctx.lineWidth = LINE_WIDTH
      ctx.lineCap = 'round'
      ctx.stroke()
    }
    // Percentage text
    const pct = Math.round(fraction * 100)
    ctx.fillStyle = '#333'
    ctx.font = '600 20px system-ui, sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillText(pct + '%', CENTER, CENTER)
  }

  draw(0)
  return {canvas, update: draw}
}
