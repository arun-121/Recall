import Foundation
import RecallCore

// MARK: - Entry point

let args = CommandLine.arguments

func defaultDBPath() -> String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("Recall/recall.sqlite").path
}

let dbPath = args.count > 1 ? args[1] : defaultDBPath()
let outPath = args.count > 2 ? args[2] : FileManager.default.currentDirectoryPath + "/embeddings.html"

guard FileManager.default.fileExists(atPath: dbPath) else {
    FileHandle.standardError.write(Data("""
    error: no database found at \(dbPath)
    Index some folders in Recall first, or pass an explicit path:
      swift run EmbeddingVisualizer /path/to/recall.sqlite output.html

    """.utf8))
    exit(1)
}

print("Reading embeddings from: \(dbPath)")

let repository: SQLiteDocumentRepository
do {
    repository = try SQLiteDocumentRepository(path: dbPath)
} catch {
    FileHandle.standardError.write(Data("error: could not open database: \(error)\n".utf8))
    exit(1)
}

let vectors = (try? repository.loadAllVectors()) ?? []
guard !vectors.isEmpty else {
    FileHandle.standardError.write(Data("error: no embeddings found. Index some documents in Recall first.\n".utf8))
    exit(1)
}

print("Loaded \(vectors.count) chunk embeddings.")

// Resolve a display label (filename) per document, cached.
var filenameCache: [Int64: String] = [:]
func filename(for documentID: Int64) -> String {
    if let cached = filenameCache[documentID] { return cached }
    let name = (try? repository.document(id: documentID))?.filename ?? "doc \(documentID)"
    filenameCache[documentID] = name
    return name
}

// MARK: - Build the data matrix

let dims = vectors.first!.1.count
var matrix: [[Double]] = vectors.map { $0.1.map(Double.init) }

// MARK: - PCA to 2D (dependency-free, deterministic)
//
// We center the data, then find the top-2 principal directions via power
// iteration with deflation on the covariance action (computed implicitly as
// Xáµ€X applied to a vector, so we never materialize a dims×dims matrix for large
// dims). This is simple, has no external dependencies, and is deterministic.

let n = matrix.count

// 1. Center columns (mean-subtract).
var mean = [Double](repeating: 0, count: dims)
for row in matrix { for j in 0..<dims { mean[j] += row[j] } }
for j in 0..<dims { mean[j] /= Double(n) }
for i in 0..<n { for j in 0..<dims { matrix[i][j] -= mean[j] } }

/// Applies the (unscaled) covariance operator C = Xáµ€X to a vector v: returns Xáµ€(X v).
func covApply(_ v: [Double]) -> [Double] {
    // Xv : length n
    var xv = [Double](repeating: 0, count: n)
    for i in 0..<n {
        var s = 0.0
        let row = matrix[i]
        for j in 0..<dims { s += row[j] * v[j] }
        xv[i] = s
    }
    // Xáµ€(Xv) : length dims
    var result = [Double](repeating: 0, count: dims)
    for i in 0..<n {
        let row = matrix[i]
        let c = xv[i]
        for j in 0..<dims { result[j] += row[j] * c }
    }
    return result
}

func normalize(_ v: [Double]) -> [Double] {
    var norm = 0.0
    for x in v { norm += x * x }
    norm = norm.squareRoot()
    guard norm > 0 else { return v }
    return v.map { $0 / norm }
}

func dot(_ a: [Double], _ b: [Double]) -> Double {
    var s = 0.0
    for i in 0..<a.count { s += a[i] * b[i] }
    return s
}

/// Power iteration for the dominant eigenvector of C, optionally deflating a
/// previously found component.
func dominantEigenvector(deflate previous: [Double]?, iterations: Int = 100) -> [Double] {
    // Deterministic seed.
    var v = [Double](repeating: 0, count: dims)
    for j in 0..<dims { v[j] = Double((j % 7) + 1) }
    v = normalize(v)
    for _ in 0..<iterations {
        var w = covApply(v)
        if let p = previous {
            // Remove the component along the previous eigenvector (deflation).
            let proj = dot(w, p)
            for j in 0..<dims { w[j] -= proj * p[j] }
        }
        let nw = normalize(w)
        // Convergence check.
        if dot(nw, v) > 0.999999 { v = nw; break }
        v = nw
    }
    return v
}

print("Projecting \(dims)-dim embeddings to 2D via PCA…")
let pc1 = dominantEigenvector(deflate: nil)
let pc2 = dominantEigenvector(deflate: pc1)

// Project each point onto (pc1, pc2).
struct Point { let x: Double; let y: Double; let label: String; let docID: Int64; let snippet: String }
var points: [Point] = []
for (idx, (meta, _)) in vectors.enumerated() {
    let centered = matrix[idx]
    let x = dot(centered, pc1)
    let y = dot(centered, pc2)
    let snippet = String(meta.text.prefix(120)).replacingOccurrences(of: "\n", with: " ")
    points.append(Point(x: x, y: y, label: filename(for: meta.documentID), docID: meta.documentID, snippet: snippet))
}

// MARK: - Emit HTML

// Assign a stable color per document.
let docIDs = Array(Set(points.map { $0.docID })).sorted()
var colorForDoc: [Int64: String] = [:]
for (i, id) in docIDs.enumerated() {
    let hue = Int(Double(i) / Double(max(1, docIDs.count)) * 360)
    colorForDoc[id] = "hsl(\(hue), 70%, 50%)"
}

func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
}

var pointsJSON = "[\n"
for p in points {
    pointsJSON += "  {\"x\": \(p.x), \"y\": \(p.y), \"label\": \"\(esc(p.label))\", \"color\": \"\(colorForDoc[p.docID]!)\", \"snippet\": \"\(esc(p.snippet))\"},\n"
}
pointsJSON += "]"

let html = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Recall — Embedding Visualization</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: -apple-system, system-ui, sans-serif; margin: 0; background: #f6f6f7; color: #1d1d1f; }
  header { padding: 16px 20px; border-bottom: 1px solid #ddd; }
  h1 { font-size: 18px; margin: 0 0 4px; }
  .meta { color: #666; font-size: 13px; }
  #wrap { display: flex; height: calc(100vh - 70px); }
  #canvas { flex: 1; }
  #legend { width: 240px; overflow-y: auto; border-left: 1px solid #ddd; padding: 12px; font-size: 13px; }
  .legend-item { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
  .swatch { width: 12px; height: 12px; border-radius: 3px; flex: none; }
  .tooltip { position: fixed; pointer-events: none; background: rgba(0,0,0,0.85); color: #fff;
             padding: 8px 10px; border-radius: 6px; font-size: 12px; max-width: 320px; display: none; z-index: 10; }
  @media (prefers-color-scheme: dark) {
    body { background: #1d1d1f; color: #f5f5f7; }
    header, #legend { border-color: #333; }
    .meta { color: #aaa; }
  }
</style>
</head>
<body>
<header>
  <h1>Recall — Embedding Visualization</h1>
  <div class="meta">\(points.count) chunks · \(docIDs.count) documents · \(dims)-dim embeddings projected to 2D (PCA)</div>
</header>
<div id="wrap">
  <canvas id="canvas"></canvas>
  <div id="legend"></div>
</div>
<div class="tooltip" id="tip"></div>
<script>
const points = \(pointsJSON);
const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d');
const tip = document.getElementById('tip');

// Build legend (unique labels/colors).
const seen = {};
const legend = document.getElementById('legend');
for (const p of points) {
  if (seen[p.label]) continue;
  seen[p.label] = p.color;
  const item = document.createElement('div');
  item.className = 'legend-item';
  item.innerHTML = '<span class="swatch" style="background:' + p.color + '"></span>' + p.label;
  legend.appendChild(item);
}

let view = { scale: 1, ox: 0, oy: 0 };
let bounds;

function computeBounds() {
  let minX=Infinity,maxX=-Infinity,minY=Infinity,maxY=-Infinity;
  for (const p of points){ minX=Math.min(minX,p.x);maxX=Math.max(maxX,p.x);minY=Math.min(minY,p.y);maxY=Math.max(maxY,p.y);}
  bounds = {minX,maxX,minY,maxY};
}

function resize(){ canvas.width = canvas.clientWidth * devicePixelRatio; canvas.height = canvas.clientHeight * devicePixelRatio; draw(); }

function toScreen(p){
  const pad = 40 * devicePixelRatio;
  const w = canvas.width - pad*2, h = canvas.height - pad*2;
  const rx = (p.x - bounds.minX) / (bounds.maxX - bounds.minX || 1);
  const ry = (p.y - bounds.minY) / (bounds.maxY - bounds.minY || 1);
  return { sx: pad + rx*w*view.scale + view.ox, sy: pad + (1-ry)*h*view.scale + view.oy };
}

function draw(){
  ctx.clearRect(0,0,canvas.width,canvas.height);
  for (const p of points){
    const {sx,sy} = toScreen(p);
    ctx.beginPath();
    ctx.arc(sx, sy, 4*devicePixelRatio, 0, Math.PI*2);
    ctx.fillStyle = p.color;
    ctx.globalAlpha = 0.8;
    ctx.fill();
  }
  ctx.globalAlpha = 1;
}

// Hover tooltip.
canvas.addEventListener('mousemove', (e)=>{
  const rect = canvas.getBoundingClientRect();
  const mx = (e.clientX-rect.left)*devicePixelRatio, my=(e.clientY-rect.top)*devicePixelRatio;
  let best=null,bestD=1e9;
  for (const p of points){ const {sx,sy}=toScreen(p); const d=(sx-mx)**2+(sy-my)**2; if(d<bestD){bestD=d;best=p;} }
  if (best && bestD < (8*devicePixelRatio)**2){
    tip.style.display='block'; tip.style.left=(e.clientX+12)+'px'; tip.style.top=(e.clientY+12)+'px';
    tip.innerHTML = '<b>'+best.label+'</b><br>'+best.snippet;
  } else { tip.style.display='none'; }
});

// Scroll to zoom, drag to pan.
canvas.addEventListener('wheel',(e)=>{ e.preventDefault(); const f=e.deltaY<0?1.1:0.9; view.scale*=f; draw(); },{passive:false});
let dragging=false,lx=0,ly=0;
canvas.addEventListener('mousedown',(e)=>{dragging=true;lx=e.clientX;ly=e.clientY;});
window.addEventListener('mouseup',()=>dragging=false);
canvas.addEventListener('mousemove',(e)=>{ if(dragging){ view.ox+=(e.clientX-lx)*devicePixelRatio; view.oy+=(e.clientY-ly)*devicePixelRatio; lx=e.clientX;ly=e.clientY; draw(); }});

computeBounds();
window.addEventListener('resize', resize);
resize();
</script>
</body>
</html>
"""

do {
    try html.write(toFile: outPath, atomically: true, encoding: .utf8)
    print("Wrote visualization to: \(outPath)")
    print("Open it with:  open \"\(outPath)\"")
} catch {
    FileHandle.standardError.write(Data("error: could not write output: \(error)\n".utf8))
    exit(1)
}
