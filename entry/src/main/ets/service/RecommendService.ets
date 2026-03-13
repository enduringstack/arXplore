/**
 * LinUCB-based online learning recommendation engine.
 *
 * Feature vector per paper (dimension D=20):
 *   [0..9]   category one-hot (top-10 arXiv categories the user has seen)
 *   [10..14] keyword TF features (top-5 keyword buckets from saved papers)
 *   [15]     author-overlap ratio (how many authors appeared in saved papers)
 *   [16]     affiliation-overlap ratio
 *   [17]     recency (days since published, normalized 0-1)
 *   [18]     title length (normalized)
 *   [19]     abstract length (normalized)
 *
 * Reward: save=1, skip=0, detail-view=0.5
 *
 * Persisted to /recommendation_model.json
 */
import { fileIo } from '@kit.CoreFileKit';
import { Paper } from '../model/DataModels';

const D = 20; // feature dimension
const ALPHA = 1.5; // exploration parameter
const MODEL_FILE = '/recommendation_model.json';
const VOCAB_FILE = '/recommendation_vocab.json';

// Simple matrix helpers (ArkTS-compatible, no spread)
function zeros(n: number): number[] {
  const arr: number[] = [];
  for (let i = 0; i < n; i++) arr.push(0);
  return arr;
}

function identity(n: number): number[][] {
  const m: number[][] = [];
  for (let i = 0; i < n; i++) {
    const row = zeros(n);
    row[i] = 1;
    m.push(row);
  }
  return m;
}

function matVecMul(mat: number[][], vec: number[]): number[] {
  const n = mat.length;
  const result = zeros(n);
  for (let i = 0; i < n; i++) {
    let sum = 0;
    for (let j = 0; j < vec.length; j++) {
      sum += mat[i][j] * vec[j];
    }
    result[i] = sum;
  }
  return result;
}

function dot(a: number[], b: number[]): number {
  let s = 0;
  for (let i = 0; i < a.length; i++) s += a[i] * b[i];
  return s;
}

function vecAdd(a: number[], b: number[]): number[] {
  const r = zeros(a.length);
  for (let i = 0; i < a.length; i++) r[i] = a[i] + b[i];
  return r;
}

function vecScale(a: number[], s: number): number[] {
  const r = zeros(a.length);
  for (let i = 0; i < a.length; i++) r[i] = a[i] * s;
  return r;
}

// Outer product: v * v^T
function outerProduct(v: number[]): number[][] {
  const n = v.length;
  const m: number[][] = [];
  for (let i = 0; i < n; i++) {
    const row = zeros(n);
    for (let j = 0; j < n; j++) {
      row[j] = v[i] * v[j];
    }
    m.push(row);
  }
  return m;
}

function matAdd(a: number[][], b: number[][]): number[][] {
  const n = a.length;
  const m: number[][] = [];
  for (let i = 0; i < n; i++) {
    const row = zeros(n);
    for (let j = 0; j < n; j++) {
      row[j] = a[i][j] + b[i][j];
    }
    m.push(row);
  }
  return m;
}

// Simple matrix inverse via Gauss-Jordan (for small D=20)
function matInverse(mat: number[][]): number[][] {
  const n = mat.length;
  // Augmented matrix [mat | I]
  const aug: number[][] = [];
  for (let i = 0; i < n; i++) {
    const row = zeros(2 * n);
    for (let j = 0; j < n; j++) row[j] = mat[i][j];
    row[n + i] = 1;
    aug.push(row);
  }
  for (let col = 0; col < n; col++) {
    // Find pivot
    let maxVal = Math.abs(aug[col][col]);
    let maxRow = col;
    for (let r = col + 1; r < n; r++) {
      if (Math.abs(aug[r][col]) > maxVal) {
        maxVal = Math.abs(aug[r][col]);
        maxRow = r;
      }
    }
    const temp = aug[col];
    aug[col] = aug[maxRow];
    aug[maxRow] = temp;
    const pivot = aug[col][col];
    if (Math.abs(pivot) < 1e-10) continue;
    for (let j = 0; j < 2 * n; j++) aug[col][j] /= pivot;
    for (let r = 0; r < n; r++) {
      if (r === col) continue;
      const factor = aug[r][col];
      for (let j = 0; j < 2 * n; j++) aug[r][j] -= factor * aug[col][j];
    }
  }
  const inv: number[][] = [];
  for (let i = 0; i < n; i++) {
    const row = zeros(n);
    for (let j = 0; j < n; j++) row[j] = aug[i][n + j];
    inv.push(row);
  }
  return inv;
}

interface ModelData {
  A: number[][];
  b: number[];
  totalActions: number;
}

interface VocabData {
  categoryVocab: string[];
  keywordVocab: string[];
  authorSet: string[];
  affiliationSet: string[];
}

export class RecommendService {
  private static A: number[][] = identity(D);
  private static b: number[] = zeros(D);
  private static totalActions: number = 0;
  private static filesDir: string = '';

  // Vocabulary built from saved papers
  private static categoryVocab: string[] = []; // top 10 categories
  private static keywordVocab: string[] = [];  // top 5 keyword buckets
  private static authorSet: string[] = [];
  private static affiliationSet: string[] = [];

  static init(filesDir: string, savedPapers: Paper[]): void {
    RecommendService.filesDir = filesDir;
    RecommendService.buildVocab(savedPapers);
    RecommendService.loadModel();
  }

  // Build vocabulary from user's saved papers
  private static buildVocab(papers: Paper[]): void {
    const catCount: Record<string, number> = {};
    const wordCount: Record<string, number> = {};
    const authors: Set<string> = new Set();
    const affiliations: Set<string> = new Set();
    const stopWords = new Set(['a','an','the','of','for','in','on','to','and','with','by','from',
      'is','are','that','this','via','using','its','our','we','has','have','been','not','but',
      'can','all','more','these','their','they','each','into','based','over','between','such',
      'than','also','which','about','both','new','two','only','how','what','when','where','most',
      'some','do','does','did','will','would','should','could','may','might','model','models',
      'learning','method','methods','data','approach','paper','results','propose','proposed']);

    for (const p of papers) {
      for (const cat of p.categories) {
        catCount[cat] = (catCount[cat] || 0) + 1;
      }
      const words = p.title.toLowerCase().split(/[\s:,\-–()\[\]{}]+/);
      for (const w of words) {
        if (w.length > 3 && !stopWords.has(w)) {
          wordCount[w] = (wordCount[w] || 0) + 1;
        }
      }
      for (const a of p.authors) {
        authors.add(a.name.toLowerCase());
        if (a.affiliation) affiliations.add(a.affiliation.toLowerCase());
      }
    }

    // Sort by frequency, take top N
    const catEntries: Array<[string, number]> = [];
    const catKeys = Object.keys(catCount);
    for (const k of catKeys) catEntries.push([k, catCount[k]]);
    catEntries.sort((a, b) => b[1] - a[1]);
    RecommendService.categoryVocab = catEntries.slice(0, 10).map(e => e[0]);

    const wordEntries: Array<[string, number]> = [];
    const wordKeys = Object.keys(wordCount);
    for (const k of wordKeys) wordEntries.push([k, wordCount[k]]);
    wordEntries.sort((a, b) => b[1] - a[1]);
    RecommendService.keywordVocab = wordEntries.slice(0, 5).map(e => e[0]);

    const authorArr: string[] = [];
    authors.forEach(a => authorArr.push(a));
    RecommendService.authorSet = authorArr;

    const affArr: string[] = [];
    affiliations.forEach(a => affArr.push(a));
    RecommendService.affiliationSet = affArr;

    // Save vocab
    RecommendService.saveVocab();
  }

  // Extract feature vector for a paper
  static featurize(paper: Paper): number[] {
    const x = zeros(D);

    // [0..9] category one-hot
    for (const cat of paper.categories) {
      const idx = RecommendService.categoryVocab.indexOf(cat);
      if (idx >= 0 && idx < 10) x[idx] = 1;
    }

    // [10..14] keyword TF
    const titleLower = paper.title.toLowerCase();
    for (let i = 0; i < RecommendService.keywordVocab.length && i < 5; i++) {
      if (titleLower.includes(RecommendService.keywordVocab[i])) {
        x[10 + i] = 1;
      }
    }
    // Also check abstract
    const absLower = paper.summary.toLowerCase();
    for (let i = 0; i < RecommendService.keywordVocab.length && i < 5; i++) {
      if (absLower.includes(RecommendService.keywordVocab[i])) {
        x[10 + i] = Math.max(x[10 + i], 0.5);
      }
    }

    // [15] author overlap
    if (RecommendService.authorSet.length > 0) {
      let overlap = 0;
      for (const a of paper.authors) {
        if (RecommendService.authorSet.includes(a.name.toLowerCase())) overlap++;
      }
      x[15] = Math.min(1, overlap / Math.max(1, paper.authors.length));
    }

    // [16] affiliation overlap
    if (RecommendService.affiliationSet.length > 0) {
      let overlap = 0;
      for (const a of paper.authors) {
        if (a.affiliation && RecommendService.affiliationSet.includes(a.affiliation.toLowerCase())) {
          overlap++;
        }
      }
      x[16] = Math.min(1, overlap / Math.max(1, paper.authors.length));
    }

    // [17] recency (0=very old, 1=today)
    if (paper.published) {
      const pubDate = new Date(paper.published).getTime();
      const now = Date.now();
      const daysDiff = (now - pubDate) / (1000 * 60 * 60 * 24);
      x[17] = Math.max(0, 1 - daysDiff / 365);
    }

    // [18] title length normalized
    x[18] = Math.min(1, paper.title.length / 150);

    // [19] abstract length normalized
    x[19] = Math.min(1, paper.summary.length / 2000);

    return x;
  }

  // Compute UCB score for a paper
  static score(paper: Paper): number {
    const x = RecommendService.featurize(paper);
    const Ainv = matInverse(RecommendService.A);
    const theta = matVecMul(Ainv, RecommendService.b);
    const predicted = dot(theta, x);
    const uncertainty = Math.sqrt(dot(x, matVecMul(Ainv, x)));
    return predicted + ALPHA * uncertainty;
  }

  // Rank papers by UCB score
  static rank(papers: Paper[]): Paper[] {
    const scored: Array<[Paper, number]> = [];
    for (const p of papers) {
      scored.push([p, RecommendService.score(p)]);
    }
    scored.sort((a, b) => b[1] - a[1]);
    const result: Paper[] = [];
    for (const item of scored) result.push(item[0]);
    return result;
  }

  // Update model with user feedback
  // reward: 1=save, 0=skip, 0.5=viewed detail
  static update(paper: Paper, reward: number): void {
    const x = RecommendService.featurize(paper);
    RecommendService.A = matAdd(RecommendService.A, outerProduct(x));
    RecommendService.b = vecAdd(RecommendService.b, vecScale(x, reward));
    RecommendService.totalActions++;
    // Persist every 5 actions
    if (RecommendService.totalActions % 5 === 0) {
      RecommendService.saveModel();
    }
  }

  // Force save (call on page exit)
  static save(): void {
    RecommendService.saveModel();
  }

  // Get model stats for UI display
  static getStats(): string {
    return `${RecommendService.totalActions} 次学习 · ${RecommendService.categoryVocab.length} 类别 · ${RecommendService.keywordVocab.length} 关键词`;
  }

  // Persistence
  private static saveModel(): void {
    if (!RecommendService.filesDir) return;
    const data: ModelData = {
      A: RecommendService.A,
      b: RecommendService.b,
      totalActions: RecommendService.totalActions
    };
    const fp = RecommendService.filesDir + MODEL_FILE;
    try {
      const tmpPath = fp + '.tmp';
      const f = fileIo.openSync(tmpPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, JSON.stringify(data));
      fileIo.closeSync(f.fd);
      try { fileIo.renameSync(tmpPath, fp); } catch (_) {}
    } catch (_) {}
  }

  private static loadModel(): void {
    if (!RecommendService.filesDir) return;
    const fp = RecommendService.filesDir + MODEL_FILE;
    try {
      if (fileIo.accessSync(fp)) {
        const content = fileIo.readTextSync(fp);
        const data = JSON.parse(content) as ModelData;
        if (data.A && data.b && data.A.length === D && data.b.length === D) {
          RecommendService.A = data.A;
          RecommendService.b = data.b;
          RecommendService.totalActions = data.totalActions || 0;
        }
      }
    } catch (_) {
      // Start fresh
      RecommendService.A = identity(D);
      RecommendService.b = zeros(D);
    }
  }

  private static saveVocab(): void {
    if (!RecommendService.filesDir) return;
    const data: VocabData = {
      categoryVocab: RecommendService.categoryVocab,
      keywordVocab: RecommendService.keywordVocab,
      authorSet: RecommendService.authorSet,
      affiliationSet: RecommendService.affiliationSet
    };
    const fp = RecommendService.filesDir + VOCAB_FILE;
    try {
      const f = fileIo.openSync(fp,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, JSON.stringify(data));
      fileIo.closeSync(f.fd);
    } catch (_) {}
  }
}
