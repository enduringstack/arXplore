import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { Paper, Category, getDefaultCategories, ReadingPlan, PLAN_UNREAD } from '../model/DataModels';

const PREFS_NAME = 'reading_papers_prefs';
const KEY_CATEGORIES = 'categories';
const KEY_PROGRESS_PREFIX = 'rp_';
const KEY_PDF_PAGE_PREFIX = 'pp_';
const FAVORITES_FILE = '/favorites.json';
const PLANS_FILE = '/reading_plans.json';
const KEY_LAST_READ = 'last_read_date';
const KEY_STREAK = 'reading_streak';

export class PreferencesUtil {
  private static prefs: preferences.Preferences | null = null;
  private static filesDir: string = '';
  private static initPromise: Promise<void> | null = null;

  // In-memory caches
  private static favsCache: Paper[] | null = null;
  private static favIdsCache: string[] | null = null;
  private static plansCache: ReadingPlan[] | null = null;

  static async init(context: Context): Promise<void> {
    if (PreferencesUtil.prefs) return;
    if (PreferencesUtil.initPromise) return PreferencesUtil.initPromise;
    PreferencesUtil.initPromise = (async () => {
      PreferencesUtil.prefs = await preferences.getPreferences(context, PREFS_NAME);
      PreferencesUtil.filesDir = context.filesDir;
    })();
    return PreferencesUtil.initPromise;
  }

  // ---- Atomic file write helper ----
  private static atomicWriteFile(filePath: string, data: string): void {
    const tmpPath = filePath + '.tmp';
    const f = fileIo.openSync(tmpPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, data);
    fileIo.closeSync(f.fd);
    try { fileIo.renameSync(tmpPath, filePath); } catch (_) {
      // Fallback: direct write if rename fails
      const f2 = fileIo.openSync(filePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f2.fd, data);
      fileIo.closeSync(f2.fd);
    }
  }

  private static readJsonFile<T>(filePath: string): T | null {
    try {
      if (fileIo.accessSync(filePath)) {
        const content = fileIo.readTextSync(filePath);
        return JSON.parse(content) as T;
      }
    } catch (_) {
      // Try backup
      try {
        const bakPath = filePath + '.bak';
        if (fileIo.accessSync(bakPath)) {
          const content = fileIo.readTextSync(bakPath);
          return JSON.parse(content) as T;
        }
      } catch (_) {}
    }
    return null;
  }

  private static writeJsonFile(filePath: string, data: Object): void {
    // Create backup of current file
    try {
      if (fileIo.accessSync(filePath)) {
        const bakPath = filePath + '.bak';
        try { fileIo.unlinkSync(bakPath); } catch (_) {}
        try { fileIo.copyFileSync(filePath, bakPath); } catch (_) {}
      }
    } catch (_) {}
    PreferencesUtil.atomicWriteFile(filePath, JSON.stringify(data));
  }

  // ---- Favorites (file-based, with in-memory cache) ----

  static getFavoritePapers(): Paper[] {
    if (PreferencesUtil.favsCache !== null) return PreferencesUtil.favsCache;
    const fp = PreferencesUtil.filesDir + FAVORITES_FILE;
    const result = PreferencesUtil.readJsonFile<Paper[]>(fp);
    PreferencesUtil.favsCache = result || [];
    PreferencesUtil.favIdsCache = PreferencesUtil.favsCache.map(p => p.id);
    return PreferencesUtil.favsCache;
  }

  private static saveFavoritePapers(papers: Paper[]): void {
    PreferencesUtil.favsCache = papers;
    PreferencesUtil.favIdsCache = papers.map(p => p.id);
    const fp = PreferencesUtil.filesDir + FAVORITES_FILE;
    PreferencesUtil.writeJsonFile(fp, papers);
  }

  static addFavorite(paper: Paper): void {
    const favs = PreferencesUtil.getFavoritePapers();
    if (!favs.some(p => p.id === paper.id)) {
      favs.push(paper);
      PreferencesUtil.saveFavoritePapers(favs);
    }
  }

  static removeFavorite(paperId: string): void {
    let favs = PreferencesUtil.getFavoritePapers();
    favs = favs.filter(p => p.id !== paperId);
    PreferencesUtil.saveFavoritePapers(favs);
  }

  static getFavoriteIds(): string[] {
    if (PreferencesUtil.favIdsCache !== null) return PreferencesUtil.favIdsCache;
    return PreferencesUtil.getFavoritePapers().map(p => p.id);
  }

  // ---- Categories ----

  static async getCategories(): Promise<Category[]> {
    if (!PreferencesUtil.prefs) return getDefaultCategories();
    const val = await PreferencesUtil.prefs.get(KEY_CATEGORIES, '');
    if (!(val as string)) return getDefaultCategories();
    try { return JSON.parse(val as string) as Category[]; }
    catch (_) { return getDefaultCategories(); }
  }

  static async saveCategories(categories: Category[]): Promise<void> {
    if (!PreferencesUtil.prefs) return;
    await PreferencesUtil.prefs.put(KEY_CATEGORIES, JSON.stringify(categories));
    await PreferencesUtil.prefs.flush();
  }

  // ---- Reading Progress ----

  static async getReadingProgress(paperId: string): Promise<number> {
    if (!PreferencesUtil.prefs) return 0;
    const key = KEY_PROGRESS_PREFIX + paperId.replace(/[^a-zA-Z0-9]/g, '_');
    const val = await PreferencesUtil.prefs.get(key, 0);
    return val as number;
  }

  static async saveReadingProgress(paperId: string, progress: number): Promise<void> {
    if (!PreferencesUtil.prefs) return;
    const key = KEY_PROGRESS_PREFIX + paperId.replace(/[^a-zA-Z0-9]/g, '_');
    await PreferencesUtil.prefs.put(key, Math.round(progress));
    await PreferencesUtil.prefs.flush();
    await PreferencesUtil.updateReadingStreak();
  }

  // ---- PDF Page Bookmark ----

  static async getPdfPage(paperId: string): Promise<number> {
    if (!PreferencesUtil.prefs) return 0;
    const key = KEY_PDF_PAGE_PREFIX + paperId.replace(/[^a-zA-Z0-9]/g, '_');
    const val = await PreferencesUtil.prefs.get(key, 0);
    return val as number;
  }

  static async savePdfPage(paperId: string, page: number): Promise<void> {
    if (!PreferencesUtil.prefs) return;
    const key = KEY_PDF_PAGE_PREFIX + paperId.replace(/[^a-zA-Z0-9]/g, '_');
    await PreferencesUtil.prefs.put(key, page);
    await PreferencesUtil.prefs.flush();
  }

  // ---- Reading Plans (file-based, with in-memory cache) ----

  static getPlans(): ReadingPlan[] {
    if (PreferencesUtil.plansCache !== null) return PreferencesUtil.plansCache;
    const fp = PreferencesUtil.filesDir + PLANS_FILE;
    const result = PreferencesUtil.readJsonFile<ReadingPlan[]>(fp);
    PreferencesUtil.plansCache = result || [];
    return PreferencesUtil.plansCache;
  }

  private static savePlans(plans: ReadingPlan[]): void {
    PreferencesUtil.plansCache = plans;
    const fp = PreferencesUtil.filesDir + PLANS_FILE;
    PreferencesUtil.writeJsonFile(fp, plans);
  }

  static getPlan(paperId: string): ReadingPlan | null {
    const plans = PreferencesUtil.getPlans();
    return plans.find(p => p.paperId === paperId) || null;
  }

  static savePlan(plan: ReadingPlan): void {
    const plans = PreferencesUtil.getPlans();
    const idx = plans.findIndex(p => p.paperId === plan.paperId);
    if (idx >= 0) { plans[idx] = plan; }
    else { plans.push(plan); }
    PreferencesUtil.savePlans(plans);
  }

  static removePlan(paperId: string): void {
    let plans = PreferencesUtil.getPlans();
    plans = plans.filter(p => p.paperId !== paperId);
    PreferencesUtil.savePlans(plans);
  }

  static createDefaultPlan(paperId: string): ReadingPlan {
    return {
      paperId: paperId, status: PLAN_UNREAD, priority: 0,
      deadline: '', notes: '', startedAt: '', completedAt: ''
    };
  }

  static async updateReadingStreak(): Promise<void> {
    if (!PreferencesUtil.prefs) return;
    const now = new Date();
    const todayStr = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}-${now.getDate().toString().padStart(2, '0')}`;
    const lastDate = (await PreferencesUtil.prefs.get(KEY_LAST_READ, '')) as string;
    if (lastDate === todayStr) return;
    let streak = (await PreferencesUtil.prefs.get(KEY_STREAK, 0)) as number;
    const y = new Date(now.getTime() - 86400000);
    const yesterdayStr = `${y.getFullYear()}-${(y.getMonth() + 1).toString().padStart(2, '0')}-${y.getDate().toString().padStart(2, '0')}`;
    streak = (lastDate === yesterdayStr) ? streak + 1 : 1;
    await PreferencesUtil.prefs.put(KEY_LAST_READ, todayStr);
    await PreferencesUtil.prefs.put(KEY_STREAK, streak);
    await PreferencesUtil.prefs.flush();
  }

  static async get(key: string, defaultValue: preferences.ValueType): Promise<preferences.ValueType> {
    if (!PreferencesUtil.prefs) return defaultValue;
    return await PreferencesUtil.prefs.get(key, defaultValue);
  }

  static async put(key: string, value: preferences.ValueType): Promise<void> {
    if (!PreferencesUtil.prefs) return;
    await PreferencesUtil.prefs.put(key, value);
    await PreferencesUtil.prefs.flush();
  }

  static async getReadingStreak(): Promise<number> {
    if (!PreferencesUtil.prefs) return 0;
    const now = new Date();
    const todayStr = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}-${now.getDate().toString().padStart(2, '0')}`;
    const y = new Date(now.getTime() - 86400000);
    const yesterdayStr = `${y.getFullYear()}-${(y.getMonth() + 1).toString().padStart(2, '0')}-${y.getDate().toString().padStart(2, '0')}`;
    const lastDate = (await PreferencesUtil.prefs.get(KEY_LAST_READ, '')) as string;
    if (lastDate !== todayStr && lastDate !== yesterdayStr) return 0;
    return (await PreferencesUtil.prefs.get(KEY_STREAK, 0)) as number;
  }
}
