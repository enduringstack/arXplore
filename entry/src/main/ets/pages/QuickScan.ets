import { router } from '@kit.ArkUI';
import { localChatModel } from '@kit.DataAugmentationKit';
import { Paper, Category } from '../model/DataModels';
import { ArxivService } from '../service/ArxivService';
import { PreferencesUtil } from '../common/PreferencesUtil';
import { CloudLLMService } from '../service/CloudLLMService';
import { RecommendService } from '../service/RecommendService';

@Entry
@Component
struct QuickScan {
  @State papers: Paper[] = [];
  @State currentIdx: number = 0;
  @State isLoading: boolean = true;
  @State loadingCategory: string = '';
  @State errorMsg: string = '';
  @State favoriteIds: string[] = [];
  @State cardOffsetX: number = 0;
  @State cardOpacity: number = 1;
  @State cardRotate: number = 0;
  @State savedCount: number = 0;
  @State skippedCount: number = 0;
  @State expandAbstract: boolean = false;
  @State aiTakes: Record<string, string> = {};
  @State aiLoading: Record<string, boolean> = {};
  @State llmInited: boolean = false;
  @State rlStats: string = '';
  private savedKeywords: Set<string> = new Set();
  private animating: boolean = false;

  aboutToAppear(): void { this.loadPapers(); }
  aboutToDisappear(): void { RecommendService.save(); }

  async loadPapers(): Promise<void> {
    await PreferencesUtil.init(getContext(this));
    this.favoriteIds = PreferencesUtil.getFavoriteIds();
    const categories = await PreferencesUtil.getCategories();
    const favPapers = PreferencesUtil.getFavoritePapers();
    const stopWords = new Set(['a','an','the','of','for','in','on','to','and','with','by','from','is','are','that','this','via','using','its','our','we','has','have','been','not','but','can','all','more','these','their','they','each','into','based','over','between','such','than','also','which','about','both','new','two','only','how','what','when','where','most','some','do','does','did','will','would','should','could','may','might']);
    for (const fp of favPapers) {
      const words = fp.title.toLowerCase().split(/[\s:,\-–()\[\]]+/);
      for (const w of words) {
        if (w.length > 3 && !stopWords.has(w)) this.savedKeywords.add(w);
      }
      for (const cat of fp.categories) this.savedKeywords.add(cat.toLowerCase());
    }
    const all: Paper[] = [];
    const ids = new Set<string>();
    const favSet = new Set<string>(this.favoriteIds);
    const limit = Math.min(4, categories.length);
    for (let i = 0; i < limit; i++) {
      this.loadingCategory = categories[i].name;
      try {
        const results = await ArxivService.searchPapers(categories[i].query, 0, 12, false);
        for (const p of results) {
          if (!ids.has(p.id) && !favSet.has(p.id)) { ids.add(p.id); all.push(p); }
        }
      } catch (_) {}
    }
    RecommendService.init(getContext(this).filesDir, favPapers);
    const ranked = RecommendService.rank(all);
    this.papers = ranked.slice(0, 30);
    this.isLoading = false;
    this.rlStats = RecommendService.getStats();
    try { this.llmInited = await localChatModel.init(); } catch (_) { this.llmInited = false; }
    if (this.papers.length === 0) { this.errorMsg = '没有新论文可速览'; }
    else { this.preloadAiTakes(); }
  }

  hasRelevance(paper: Paper): boolean {
    if (this.savedKeywords.size === 0) return false;
    for (const cat of paper.categories) {
      if (this.savedKeywords.has(cat.toLowerCase())) return true;
    }
    const words = paper.title.toLowerCase().split(/[\s:,\-–()\[\]]+/);
    for (const w of words) {
      if (w.length > 3 && this.savedKeywords.has(w)) return true;
    }
    return false;
  }

  preloadAiTakes(): void {
    for (let i = this.currentIdx; i < Math.min(this.currentIdx + 2, this.papers.length); i++) {
      const p = this.papers[i];
      if (!this.aiTakes[p.id] && !this.aiLoading[p.id]) { this.generateAiTake(p); }
    }
  }

  async generateAiTake(paper: Paper): Promise<void> {
    const loadingMap: Record<string, boolean> = {};
    const lKeys = Object.keys(this.aiLoading);
    for (const k of lKeys) { loadingMap[k] = this.aiLoading[k]; }
    loadingMap[paper.id] = true;
    this.aiLoading = loadingMap;
    const prompt = `你是论文推荐助手。用一句中文（不超过60字）概括这篇论文的核心创新点和实用价值，让读者快速判断是否值得深读。直接输出概括，不要任何前缀。\n\n标题：${paper.title}\n摘要：${paper.summary.substring(0, 500)}`;
    try {
      let result: string;
      if (this.llmInited) {
        result = await new Promise<string>((resolve) => {
          let text = '';
          const q: localChatModel.QuestionInfo = { questionId: Date.now(), content: prompt };
          localChatModel.chat(q, { isStream: true } as localChatModel.Config,
            (err, answer: localChatModel.Answer) => {
              if (err) { resolve(''); return; }
              text += answer.content;
              if (answer.isFinished) resolve(text);
            });
        });
      } else { result = await CloudLLMService.chat(prompt); }
      const takesMap: Record<string, string> = {};
      const tKeys = Object.keys(this.aiTakes);
      for (const k of tKeys) { takesMap[k] = this.aiTakes[k]; }
      takesMap[paper.id] = result;
      this.aiTakes = takesMap;
    } catch (_) {}
    const doneMap: Record<string, boolean> = {};
    const dKeys = Object.keys(this.aiLoading);
    for (const k of dKeys) { doneMap[k] = this.aiLoading[k]; }
    doneMap[paper.id] = false;
    this.aiLoading = doneMap;
  }

  isDone(): boolean {
    return !this.isLoading && this.currentIdx >= this.papers.length && this.papers.length > 0;
  }

  swipeDir(): number {
    if (Math.abs(this.cardOffsetX) < 50) return 0;
    return this.cardOffsetX > 0 ? 1 : -1;
  }

  skip(): void {
    if (this.animating || this.currentIdx >= this.papers.length) return;
    this.animating = true;
    RecommendService.update(this.papers[this.currentIdx], 0);
    this.skippedCount++;
    animateTo({ duration: 250, curve: Curve.EaseOut }, () => {
      this.cardOffsetX = -600; this.cardOpacity = 0; this.cardRotate = -12;
    });
    setTimeout(() => {
      this.currentIdx++; this.cardOffsetX = 0; this.cardOpacity = 1;
      this.cardRotate = 0; this.expandAbstract = false; this.animating = false;
      this.preloadAiTakes();
    }, 270);
  }

  save(): void {
    if (this.animating || this.currentIdx >= this.papers.length) return;
    this.animating = true;
    const paper = this.papers[this.currentIdx];
    if (paper) {
      RecommendService.update(paper, 1);
      PreferencesUtil.addFavorite(paper);
      this.favoriteIds = [...this.favoriteIds, paper.id];
      this.savedCount++;
    }
    animateTo({ duration: 250, curve: Curve.EaseOut }, () => {
      this.cardOffsetX = 600; this.cardOpacity = 0; this.cardRotate = 12;
    });
    setTimeout(() => {
      this.currentIdx++; this.cardOffsetX = 0; this.cardOpacity = 1;
      this.cardRotate = 0; this.expandAbstract = false; this.animating = false;
      this.preloadAiTakes();
    }, 270);
  }

  openDetail(): void {
    if (this.currentIdx >= this.papers.length) return;
    RecommendService.update(this.papers[this.currentIdx], 0.5);
    AppStorage.setOrCreate('selectedPaperJson', JSON.stringify(this.papers[this.currentIdx]));
    router.pushUrl({ url: 'pages/PaperDetail' });
  }

  fmtDate(d: string): string { return d ? d.substring(0, 10) : ''; }
  readTime(paper: Paper): number { return Math.max(1, Math.ceil(paper.summary.split(' ').length / 40)); }

  pageTransition() {
    PageTransitionEnter({ duration: 250 }).slide(SlideEffect.Right)
    PageTransitionExit({ duration: 200 }).opacity(0.8)
  }

  build() {
    Column() {
      // ─── Header ───
      Row() {
        Text('<')
          .fontSize(20).fontColor('#3C3C43').fontWeight(FontWeight.Medium)
          .width(44).height(44).textAlign(TextAlign.Center)
          .onClick(() => { router.back(); })

        Column() {
          Text('智能速览')
            .fontSize(17).fontWeight(FontWeight.Bold).fontColor('#1D1D1F')
          if (!this.isDone() && this.papers.length > 0 && !this.isLoading) {
            Text(`${this.currentIdx + 1} of ${this.papers.length}`)
              .fontSize(11).fontColor('#8E8E93')
          }
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        if (!this.isLoading && !this.isDone()) {
          Row({ space: 10 }) {
            Column({ space: 1 }) {
              Text(`${this.savedCount}`).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#007AFF')
              Text('收藏').fontSize(9).fontColor('#8E8E93')
            }.alignItems(HorizontalAlign.Center)
            Column({ space: 1 }) {
              Text(`${this.skippedCount}`).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#8E8E93')
              Text('跳过').fontSize(9).fontColor('#8E8E93')
            }.alignItems(HorizontalAlign.Center)
          }
          .padding({ right: 16 })
        }
      }
      .width('100%').height(52)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 4 })

      // ─── Progress ───
      if (this.papers.length > 0 && !this.isDone()) {
        Row() {
          Row()
            .width(`${Math.max(2, Math.round(this.currentIdx / this.papers.length * 100))}%`)
            .height('100%')
            .borderRadius(1)
            .backgroundColor('#007AFF')
        }
        .width('100%').height(2).backgroundColor('#F2F2F7')
      }

      // ─── Content ───
      if (this.isLoading) {
        Column({ space: 16 }) {
          LoadingProgress().width(36).height(36).color('#007AFF')
          Text('正在为你筛选论文...').fontSize(15).fontColor('#8E8E93')
          if (this.loadingCategory) {
            Text(this.loadingCategory).fontSize(13).fontColor('#AEAEB2')
          }
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.errorMsg) {
        Column({ space: 16 }) {
          Text(this.errorMsg).fontSize(15).fontColor('#8E8E93')
          Text('返回').fontSize(16).fontColor('#007AFF').onClick(() => { router.back(); })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.isDone()) {
        this.CompletionView()
      } else {
        this.CardArea()
      }
    }
    .width('100%').height('100%')
    .backgroundColor('#F2F2F7')
  }

  // ─── Completion ───
  @Builder
  CompletionView() {
    Column({ space: 0 }) {
      Blank()
      Column({ space: 20 }) {
        Text('Done').fontSize(48).fontWeight(FontWeight.Bold).fontColor('#007AFF')
        Text('你已浏览了所有推荐论文').fontSize(15).fontColor('#8E8E93')

        Row({ space: 32 }) {
          Column({ space: 4 }) {
            Text(this.savedCount.toString()).fontSize(32).fontWeight(FontWeight.Bold).fontColor('#007AFF')
            Text('已收藏').fontSize(13).fontColor('#8E8E93')
          }.alignItems(HorizontalAlign.Center)
          Column().width(1).height(36).backgroundColor('#D1D1D6')
          Column({ space: 4 }) {
            Text(this.skippedCount.toString()).fontSize(32).fontWeight(FontWeight.Bold).fontColor('#8E8E93')
            Text('已跳过').fontSize(13).fontColor('#8E8E93')
          }.alignItems(HorizontalAlign.Center)
        }
      }
      .alignItems(HorizontalAlign.Center)
      Blank()

      Text('查看收藏')
        .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
        .width('70%').height(48).textAlign(TextAlign.Center)
        .borderRadius(24).backgroundColor('#007AFF')
        .onClick(() => { router.back(); })
      Text('返回首页')
        .fontSize(14).fontColor('#8E8E93').margin({ top: 16, bottom: 48 })
        .onClick(() => { router.back(); })
    }
    .width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
  }

  // ─── Card + Actions ───
  @Builder
  CardArea() {
    Column() {
      // Card
      Stack() {
        Column({ space: 0 }) {
          Scroll() {
            Column({ space: 0 }) {
              // Header row: relevance dot + read time
              Row() {
                if (this.hasRelevance(this.papers[this.currentIdx])) {
                  Row({ space: 5 }) {
                    Column().width(6).height(6).borderRadius(3).backgroundColor('#FF9500')
                    Text('与你相关').fontSize(11).fontColor('#FF9500')
                  }
                }
                Blank()
                Text(`${this.readTime(this.papers[this.currentIdx])} min`)
                  .fontSize(11).fontColor('#C7C7CC')
              }
              .width('100%').padding({ left: 24, right: 24, top: 20 })

              // Title
              Text(this.papers[this.currentIdx].title)
                .fontSize(19).fontWeight(FontWeight.Bold).fontColor('#1D1D1F')
                .lineHeight(28).width('100%')
                .padding({ left: 24, right: 24, top: 8 })

              // Authors
              Text(this.papers[this.currentIdx].authors.slice(0, 3).map(a => a.name).join(', '))
                .fontSize(13).fontColor('#8E8E93')
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .padding({ left: 24, right: 24, top: 8 })

              // Categories + date
              Row({ space: 6 }) {
                ForEach(this.papers[this.currentIdx].categories.slice(0, 2), (cat: string) => {
                  Text(cat)
                    .fontSize(11).fontColor('#636366')
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .borderRadius(4)
                    .backgroundColor('#F2F2F7')
                }, (cat: string) => cat)
                Blank()
                Text(this.fmtDate(this.papers[this.currentIdx].published))
                  .fontSize(11).fontColor('#C7C7CC')
              }
              .width('100%').padding({ left: 24, right: 24, top: 10 })

              // AI take — subtle inline
              if (this.aiLoading[this.papers[this.currentIdx].id]) {
                Row({ space: 6 }) {
                  LoadingProgress().width(12).height(12).color('#007AFF')
                  Text('AI 分析中...').fontSize(12).fontColor('#C7C7CC')
                }
                .padding({ left: 24, right: 24, top: 14 })
              } else if (this.aiTakes[this.papers[this.currentIdx].id]) {
                Row() {
                  Text(this.aiTakes[this.papers[this.currentIdx].id])
                    .fontSize(13).fontColor('#007AFF').lineHeight(20)
                    .fontWeight(FontWeight.Medium)
                }
                .width('100%')
                .padding({ left: 24, right: 24, top: 14 })
              }

              // Divider
              Row().width('100%').height(1).backgroundColor('#F2F2F7').margin({ top: 14 })

              // Abstract
              Text(this.papers[this.currentIdx].summary)
                .fontSize(14).fontColor('#48484A').lineHeight(22)
                .maxLines(this.expandAbstract ? undefined : 5)
                .textOverflow(this.expandAbstract ? undefined : { overflow: TextOverflow.Ellipsis })
                .width('100%')
                .padding({ left: 24, right: 24, top: 14 })

              Text(this.expandAbstract ? '收起' : '展开摘要')
                .fontSize(13).fontColor('#007AFF')
                .padding({ left: 24, top: 6 })
                .onClick(() => { this.expandAbstract = !this.expandAbstract; })

              // View detail
              Text('查看完整论文 >')
                .fontSize(13).fontColor('#8E8E93')
                .padding({ left: 24, top: 14, bottom: 24 })
                .onClick(() => { this.openDetail(); })
            }
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
        .width('100%').height('100%')
        .backgroundColor('#FFFFFF')
        .borderRadius(20)
        .shadow({ radius: 16, color: '#14000000', offsetX: 0, offsetY: 4 })
        .clip(true)
        .translate({ x: this.cardOffsetX })
        .opacity(this.cardOpacity)
        .rotate({ angle: this.cardRotate })
        .gesture(
          PanGesture({ direction: PanDirection.Horizontal, distance: 15 })
            .onActionUpdate((event?: GestureEvent) => {
              if (event && !this.animating) {
                this.cardOffsetX = event.offsetX;
                this.cardRotate = event.offsetX * 0.02;
                this.cardOpacity = Math.max(0.6, 1 - Math.abs(event.offsetX) / 500);
              }
            })
            .onActionEnd((event?: GestureEvent) => {
              if (!event || this.animating) return;
              if (event.offsetX > 100) { this.save(); }
              else if (event.offsetX < -100) { this.skip(); }
              else {
                animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
                  this.cardOffsetX = 0; this.cardOpacity = 1; this.cardRotate = 0;
                });
              }
            })
        )

        // Swipe overlays — minimal
        if (this.swipeDir() > 0) {
          Column() {
            Text('SAVE')
              .fontSize(32).fontWeight(FontWeight.Bold).fontColor('#34C759')
              .opacity(Math.min(1, Math.abs(this.cardOffsetX) / 150))
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .hitTestBehavior(HitTestMode.None)
        }
        if (this.swipeDir() < 0) {
          Column() {
            Text('SKIP')
              .fontSize(32).fontWeight(FontWeight.Bold).fontColor('#FF3B30')
              .opacity(Math.min(1, Math.abs(this.cardOffsetX) / 150))
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .hitTestBehavior(HitTestMode.None)
        }
      }
      .width('100%').layoutWeight(1)
      .padding({ left: 20, right: 20, top: 8 })

      // ─── Action bar ───
      Row() {
        // Skip
        Row({ space: 6 }) {
          Text('跳过').fontSize(16).fontColor('#8E8E93').fontWeight(FontWeight.Medium)
        }
        .height(48).padding({ left: 32, right: 32 })
        .borderRadius(24)
        .backgroundColor('#F2F2F7')
        .justifyContent(FlexAlign.Center)
        .onClick(() => { this.skip(); })

        // AI
        Column() {
          Text('AI').fontSize(12).fontColor('#007AFF').fontWeight(FontWeight.Bold)
        }
        .width(40).height(40).borderRadius(20)
        .backgroundColor('#F2F2F7')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          if (this.currentIdx < this.papers.length) {
            this.generateAiTake(this.papers[this.currentIdx]);
          }
        })

        // Save
        Row({ space: 6 }) {
          Text('收藏').fontSize(16).fontColor('#FFFFFF').fontWeight(FontWeight.Medium)
        }
        .height(48).padding({ left: 32, right: 32 })
        .borderRadius(24)
        .backgroundColor('#007AFF')
        .justifyContent(FlexAlign.Center)
        .onClick(() => { this.save(); })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
      .alignItems(VerticalAlign.Center)
      .padding({ top: 12, bottom: 8 })

      // Swipe hint
      Text('左滑跳过 / 右滑收藏')
        .fontSize(11).fontColor('#C7C7CC')
        .width('100%').textAlign(TextAlign.Center)
        .padding({ bottom: 28 })
    }
    .width('100%').layoutWeight(1)
  }
}
