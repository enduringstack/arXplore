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
  // AI quick assessment
  @State aiTakes: Record<string, string> = {};
  @State aiLoading: Record<string, boolean> = {};
  @State llmInited: boolean = false;
  @State rlStats: string = '';
  // Saved paper keywords for relevance matching
  private savedKeywords: Set<string> = new Set();
  private animating: boolean = false;

  aboutToAppear(): void {
    this.loadPapers();
  }

  aboutToDisappear(): void {
    RecommendService.save();
  }

  async loadPapers(): Promise<void> {
    await PreferencesUtil.init(getContext(this));
    this.favoriteIds = PreferencesUtil.getFavoriteIds();
    const categories = await PreferencesUtil.getCategories();

    // Build keyword set from saved papers for relevance matching
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
          if (!ids.has(p.id) && !favSet.has(p.id)) {
            ids.add(p.id);
            all.push(p);
          }
        }
      } catch (_) {}
    }

    // Init LinUCB recommendation engine with saved papers
    RecommendService.init(getContext(this).filesDir, favPapers);

    // Rank papers using LinUCB (combines learned preferences + exploration)
    const ranked = RecommendService.rank(all);
    this.papers = ranked.slice(0, 30);
    this.isLoading = false;
    this.rlStats = RecommendService.getStats();

    // Init LLM
    try { this.llmInited = await localChatModel.init(); } catch (_) { this.llmInited = false; }

    if (this.papers.length === 0) {
      this.errorMsg = '没有新论文可速览';
    } else {
      // Preload AI take for first 2 papers
      this.preloadAiTakes();
    }
  }

  computeRelevance(paper: Paper): number {
    if (this.savedKeywords.size === 0) return 0;
    let score = 0;
    const titleWords = paper.title.toLowerCase().split(/[\s:,\-–()\[\]]+/);
    for (const w of titleWords) {
      if (this.savedKeywords.has(w)) score += 2;
    }
    for (const cat of paper.categories) {
      if (this.savedKeywords.has(cat.toLowerCase())) score += 3;
    }
    return score;
  }

  getRelevanceTags(paper: Paper): string[] {
    if (this.savedKeywords.size === 0) return [];
    const tags: string[] = [];
    const titleWords = paper.title.toLowerCase().split(/[\s:,\-–()\[\]]+/);
    for (const w of titleWords) {
      if (this.savedKeywords.has(w) && w.length > 3 && tags.length < 3) {
        if (!tags.includes(w)) tags.push(w);
      }
    }
    return tags;
  }

  preloadAiTakes(): void {
    for (let i = this.currentIdx; i < Math.min(this.currentIdx + 2, this.papers.length); i++) {
      const p = this.papers[i];
      if (!this.aiTakes[p.id] && !this.aiLoading[p.id]) {
        this.generateAiTake(p);
      }
    }
  }

  async generateAiTake(paper: Paper): Promise<void> {
    const loadingMap: Record<string, boolean> = {};
    const lKeys = Object.keys(this.aiLoading);
    for (const k of lKeys) { loadingMap[k] = this.aiLoading[k]; }
    loadingMap[paper.id] = true;
    this.aiLoading = loadingMap;

    const prompt = `你是论文推荐助手。用一句中文（不超过60字）概括这篇论文的核心创新点和实用价值，让读者快速判断是否值得深读。直接输出概括，不要任何前缀。

标题：${paper.title}
摘要：${paper.summary.substring(0, 500)}`;

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
      } else {
        result = await CloudLLMService.chat(prompt);
      }
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

  swipeIndicator(): number {
    if (Math.abs(this.cardOffsetX) < 40) return 0;
    return this.cardOffsetX > 0 ? 1 : -1;
  }

  skip(): void {
    if (this.animating || this.currentIdx >= this.papers.length) return;
    this.animating = true;
    RecommendService.update(this.papers[this.currentIdx], 0); // negative signal
    this.skippedCount++;
    animateTo({ duration: 250, curve: Curve.EaseOut }, () => {
      this.cardOffsetX = -600;
      this.cardOpacity = 0;
      this.cardRotate = -15;
    });
    setTimeout(() => {
      this.currentIdx++;
      this.cardOffsetX = 0;
      this.cardOpacity = 1;
      this.cardRotate = 0;
      this.expandAbstract = false;
      this.animating = false;
      this.preloadAiTakes();
    }, 270);
  }

  save(): void {
    if (this.animating || this.currentIdx >= this.papers.length) return;
    this.animating = true;
    const paper = this.papers[this.currentIdx];
    if (paper) {
      RecommendService.update(paper, 1); // positive signal
      PreferencesUtil.addFavorite(paper);
      this.favoriteIds = [...this.favoriteIds, paper.id];
      this.savedCount++;
    }
    animateTo({ duration: 250, curve: Curve.EaseOut }, () => {
      this.cardOffsetX = 600;
      this.cardOpacity = 0;
      this.cardRotate = 15;
    });
    setTimeout(() => {
      this.currentIdx++;
      this.cardOffsetX = 0;
      this.cardOpacity = 1;
      this.cardRotate = 0;
      this.expandAbstract = false;
      this.animating = false;
      this.preloadAiTakes();
    }, 270);
  }

  openDetail(): void {
    if (this.currentIdx >= this.papers.length) return;
    RecommendService.update(this.papers[this.currentIdx], 0.5); // mild positive
    AppStorage.setOrCreate('selectedPaperJson', JSON.stringify(this.papers[this.currentIdx]));
    router.pushUrl({ url: 'pages/PaperDetail' });
  }

  fmtDate(d: string): string { return d ? d.substring(0, 10) : ''; }

  readTime(paper: Paper): number {
    return Math.max(1, Math.ceil(paper.summary.split(' ').length / 40));
  }

  pageTransition() {
    PageTransitionEnter({ duration: 250 }).slide(SlideEffect.Right)
    PageTransitionExit({ duration: 200 }).opacity(0.8)
  }

  build() {
    Column() {
      // Header
      Row() {
        Row() {
          Text('\u2039').fontSize(34).fontColor('#007AFF').height(44).textAlign(TextAlign.Center)
        }
        .width(56).height(44).justifyContent(FlexAlign.Center)
        .onClick(() => { router.back(); })

        Text('智能速览')
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1D2129')

        Blank()

        if (!this.isDone() && this.papers.length > 0 && !this.isLoading) {
          Column() {
            Text(`${this.currentIdx + 1} / ${this.papers.length}`)
              .fontSize(13).fontColor('#AEAEB2')
            if (this.rlStats) {
              Text(this.rlStats)
                .fontSize(9).fontColor('#C7C7CC')
            }
          }
          .alignItems(HorizontalAlign.End)
          .padding({ right: 16 })
        }
      }
      .width('100%').height(44)
      .alignItems(VerticalAlign.Center)
      .backgroundColor('#FFFFFF')

      // Progress bar — gradient
      if (this.papers.length > 0 && !this.isDone()) {
        Stack({ alignContent: Alignment.Start }) {
          Row().width('100%').height(3).backgroundColor('#F2F2F7')
          Row()
            .width(`${Math.round(this.currentIdx / this.papers.length * 100)}%`)
            .height(3)
            .linearGradient({
              direction: GradientDirection.Right,
              colors: [['#007AFF', 0], ['#6C5CE7', 1]]
            })
            .borderRadius(1.5)
        }
        .width('100%').height(3)
      }

      if (this.isLoading) {
        Column({ space: 12 }) {
          LoadingProgress().width(48).height(48).color('#007AFF')
          Text('正在智能筛选论文...').fontSize(15).fontColor('#86909C')
          if (this.loadingCategory) {
            Text(this.loadingCategory).fontSize(13).fontColor('#AEAEB2')
          }
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.errorMsg) {
        Column({ space: 16 }) {
          Text(this.errorMsg).fontSize(15).fontColor('#86909C')
          Text('返回').fontSize(16).fontColor('#007AFF')
            .onClick(() => { router.back(); })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.isDone()) {
        this.CompletionView()
      } else {
        this.CardView()
      }
    }
    .width('100%').height('100%')
    .backgroundColor('#F5F5FA')
  }

  @Builder
  CompletionView() {
    Column({ space: 0 }) {
      Blank()

      Column({ space: 8 }) {
        Text('\u2713')
          .fontSize(48).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
          .width(80).height(80).textAlign(TextAlign.Center)
          .borderRadius(40)
          .backgroundColor('#34C759')

        Text('速览完成')
          .fontSize(24).fontWeight(FontWeight.Bold).fontColor('#1D2129')
          .margin({ top: 16 })

        Text('你已浏览了所有推荐论文')
          .fontSize(14).fontColor('#86909C')
      }
      .alignItems(HorizontalAlign.Center)

      Row({ space: 40 }) {
        Column({ space: 6 }) {
          Text(this.savedCount.toString())
            .fontSize(36).fontWeight(FontWeight.Bold).fontColor('#007AFF')
          Text('已收藏').fontSize(13).fontColor('#86909C')
        }.alignItems(HorizontalAlign.Center)

        Column().width(1).height(40).backgroundColor('#E5E5EA')

        Column({ space: 6 }) {
          Text(this.skippedCount.toString())
            .fontSize(36).fontWeight(FontWeight.Bold).fontColor('#AEAEB2')
          Text('已跳过').fontSize(13).fontColor('#86909C')
        }.alignItems(HorizontalAlign.Center)
      }
      .margin({ top: 32 })

      Blank()

      Button('查看收藏')
        .type(ButtonType.Normal)
        .fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF').backgroundColor('#007AFF')
        .borderRadius(24).width('80%').height(50)
        .onClick(() => { router.back(); })

      Text('返回首页')
        .fontSize(15).fontColor('#86909C').margin({ top: 12, bottom: 48 })
        .onClick(() => { router.back(); })
    }
    .width('100%').layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  CardView() {
    Stack() {
      Column() {
        // Card area
        Column() {
          Blank().height(8)

          Stack() {
            // The card — now scrollable for full content
            Column({ space: 0 }) {
              // Top accent bar with gradient
              Row()
                .width('100%').height(4)
                .borderRadius({ topLeft: 16, topRight: 16 })
                .linearGradient({
                  direction: GradientDirection.Right,
                  colors: this.swipeIndicator() > 0
                    ? [['#34C759', 0], ['#30D158', 1]]
                    : this.swipeIndicator() < 0
                      ? [['#FF3B30', 0], ['#FF6961', 1]]
                      : [['#007AFF', 0], ['#5856D6', 1]]
                })

              Scroll() {
                Column({ space: 0 }) {
                  // Relevance badge + reading time
                  Row({ space: 8 }) {
                    if (this.getRelevanceTags(this.papers[this.currentIdx]).length > 0) {
                      Row({ space: 4 }) {
                        Text('✦').fontSize(10).fontColor('#FF9500')
                        Text('与收藏相关').fontSize(11).fontColor('#FF9500').fontWeight(FontWeight.Medium)
                      }
                      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                      .borderRadius(10)
                      .backgroundColor('#FF950015')
                    }

                    Blank()

                    Text(`${this.readTime(this.papers[this.currentIdx])} min read`)
                      .fontSize(11).fontColor('#AEAEB2')
                  }
                  .width('100%')
                  .padding({ left: 20, right: 20, top: 14 })

                  // Title
                  Text(this.papers[this.currentIdx].title)
                    .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1D1D1F')
                    .lineHeight(26).width('100%')
                    .padding({ left: 20, right: 20, top: 10 })

                  // Authors + affiliation
                  Text(this.papers[this.currentIdx].authors.slice(0, 4).map(a => a.name).join(', '))
                    .fontSize(13).fontColor('#86868B')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .padding({ left: 20, right: 20, top: 6 })

                  // Affiliations
                  if (this.papers[this.currentIdx].authors.length > 0 &&
                    this.papers[this.currentIdx].authors[0].affiliation) {
                    Text(this.papers[this.currentIdx].authors[0].affiliation)
                      .fontSize(12).fontColor('#AEAEB2')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                      .padding({ left: 20, right: 20, top: 2 })
                  }

                  // Meta: categories + date
                  Row() {
                    Row({ space: 6 }) {
                      ForEach(this.papers[this.currentIdx].categories.slice(0, 3), (cat: string) => {
                        Text(cat)
                          .fontSize(10).fontColor('#007AFF')
                          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                          .borderRadius(10)
                          .backgroundColor('#EDF4FF')
                      }, (cat: string) => cat)
                    }
                    Blank()
                    Text(this.fmtDate(this.papers[this.currentIdx].published))
                      .fontSize(11).fontColor('#AEAEB2')
                  }
                  .width('100%')
                  .padding({ left: 20, right: 20, top: 10 })

                  // AI Quick Take
                  Column() {
                    Row({ space: 6 }) {
                      Text('✦').fontSize(12).fontColor('#6C5CE7')
                      Text('AI 速评').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#6C5CE7')
                    }

                    if (this.aiLoading[this.papers[this.currentIdx].id]) {
                      Row({ space: 6 }) {
                        LoadingProgress().width(14).height(14).color('#6C5CE7')
                        Text('正在分析...').fontSize(13).fontColor('#AEAEB2')
                      }
                      .margin({ top: 6 })
                    } else if (this.aiTakes[this.papers[this.currentIdx].id]) {
                      Text(this.aiTakes[this.papers[this.currentIdx].id])
                        .fontSize(13).fontColor('#4A4A5A').lineHeight(20)
                        .margin({ top: 6 })
                        .width('100%')
                    } else {
                      Text('点击生成 AI 速评')
                        .fontSize(13).fontColor('#AEAEB2')
                        .margin({ top: 6 })
                        .onClick(() => { this.generateAiTake(this.papers[this.currentIdx]); })
                    }
                  }
                  .width('100%')
                  .padding(12)
                  .margin({ left: 20, right: 20, top: 12 })
                  .backgroundColor('#F5F3FF')
                  .borderRadius(10)
                  .border({ width: { left: 3 }, color: '#6C5CE7' })

                  // Divider
                  Row().width('100%').height(1).backgroundColor('#F2F2F7')
                    .margin({ top: 12, left: 20, right: 20 })

                  // Abstract — expandable
                  Text(this.papers[this.currentIdx].summary)
                    .fontSize(14).fontColor('#4E5969')
                    .lineHeight(22)
                    .maxLines(this.expandAbstract ? undefined : 4)
                    .textOverflow(this.expandAbstract ? undefined : { overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .padding({ left: 20, right: 20, top: 12 })

                  if (!this.expandAbstract) {
                    Text('展开全文摘要 ▾')
                      .fontSize(13).fontColor('#007AFF').fontWeight(FontWeight.Medium)
                      .padding({ left: 20, top: 6 })
                      .onClick(() => { this.expandAbstract = true; })
                  } else {
                    Text('收起 ▴')
                      .fontSize(13).fontColor('#007AFF').fontWeight(FontWeight.Medium)
                      .padding({ left: 20, top: 6 })
                      .onClick(() => { this.expandAbstract = false; })
                  }

                  // Relevance keywords
                  if (this.getRelevanceTags(this.papers[this.currentIdx]).length > 0) {
                    Row({ space: 6 }) {
                      Text('关联关键词:').fontSize(11).fontColor('#AEAEB2')
                      ForEach(this.getRelevanceTags(this.papers[this.currentIdx]), (tag: string) => {
                        Text(tag)
                          .fontSize(11).fontColor('#FF9500')
                          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                          .borderRadius(4)
                          .backgroundColor('#FF950015')
                      }, (tag: string) => tag)
                    }
                    .padding({ left: 20, right: 20, top: 10 })
                    .width('100%')
                  }

                  // Detail link
                  Row() {
                    Text('查看完整论文')
                      .fontSize(13).fontColor('#007AFF').fontWeight(FontWeight.Medium)
                    Text(' \u203A')
                      .fontSize(15).fontColor('#007AFF')
                  }
                  .padding({ left: 20, top: 12, bottom: 20 })
                  .onClick(() => { this.openDetail(); })
                }
              }
              .layoutWeight(1)
              .scrollBar(BarState.Off)
            }
            .width('100%')
            .backgroundColor('#FFFFFF')
            .borderRadius(16)
            .shadow({ radius: 20, color: '#1A000000', offsetX: 0, offsetY: 8 })
            .translate({ x: this.cardOffsetX })
            .opacity(this.cardOpacity)
            .rotate({ angle: this.cardRotate })
            .clip(true)
            .gesture(
              PanGesture({ direction: PanDirection.Horizontal, distance: 15 })
                .onActionUpdate((event?: GestureEvent) => {
                  if (event && !this.animating) {
                    this.cardOffsetX = event.offsetX;
                    this.cardRotate = event.offsetX * 0.03;
                    this.cardOpacity = Math.max(0.5, 1 - Math.abs(event.offsetX) / 500);
                  }
                })
                .onActionEnd((event?: GestureEvent) => {
                  if (!event || this.animating) return;
                  if (event.offsetX > 100) {
                    this.save();
                  } else if (event.offsetX < -100) {
                    this.skip();
                  } else {
                    animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
                      this.cardOffsetX = 0;
                      this.cardOpacity = 1;
                      this.cardRotate = 0;
                    });
                  }
                })
            )

            // Swipe indicator overlays
            if (this.swipeIndicator() > 0) {
              Row() {
                Text('收藏')
                  .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#34C759')
                  .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                  .borderRadius(8)
                  .border({ width: 3, color: '#34C759', style: BorderStyle.Solid })
                  .rotate({ angle: -20 })
              }
              .width('100%').height('100%')
              .justifyContent(FlexAlign.Start)
              .alignItems(VerticalAlign.Top)
              .padding({ left: 30, top: 30 })
              .hitTestBehavior(HitTestMode.None)
            }

            if (this.swipeIndicator() < 0) {
              Row() {
                Blank()
                Text('跳过')
                  .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FF3B30')
                  .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                  .borderRadius(8)
                  .border({ width: 3, color: '#FF3B30', style: BorderStyle.Solid })
                  .rotate({ angle: 20 })
              }
              .width('100%').height('100%')
              .alignItems(VerticalAlign.Top)
              .padding({ right: 30, top: 30 })
              .hitTestBehavior(HitTestMode.None)
            }
          }
          .width('100%').layoutWeight(1)

          Blank().height(4)
        }
        .width('100%').layoutWeight(1)
        .padding({ left: 16, right: 16 })

        // Action buttons
        Row() {
          // Skip button
          Column() {
            Text('\u2717').fontSize(22).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
          }
          .width(52).height(52).borderRadius(26)
          .backgroundColor('#FF3B30')
          .justifyContent(FlexAlign.Center)
          .shadow({ radius: 8, color: '#33FF3B30', offsetX: 0, offsetY: 4 })
          .onClick(() => { this.skip(); })

          // AI assess button
          Column() {
            Text('✦').fontSize(20).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
          }
          .width(52).height(52).borderRadius(26)
          .backgroundColor('#6C5CE7')
          .justifyContent(FlexAlign.Center)
          .shadow({ radius: 8, color: '#336C5CE7', offsetX: 0, offsetY: 4 })
          .onClick(() => {
            if (this.currentIdx < this.papers.length) {
              this.generateAiTake(this.papers[this.currentIdx]);
            }
          })

          // Detail button
          Column() {
            Text('\u2197').fontSize(20).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
          }
          .width(52).height(52).borderRadius(26)
          .backgroundColor('#86909C')
          .justifyContent(FlexAlign.Center)
          .shadow({ radius: 8, color: '#3386909C', offsetX: 0, offsetY: 4 })
          .onClick(() => { this.openDetail(); })

          // Save button
          Column() {
            Text('\u2605').fontSize(22).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
          }
          .width(52).height(52).borderRadius(26)
          .backgroundColor('#007AFF')
          .justifyContent(FlexAlign.Center)
          .shadow({ radius: 8, color: '#33007AFF', offsetX: 0, offsetY: 4 })
          .onClick(() => { this.save(); })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceEvenly)
        .alignItems(VerticalAlign.Center)
        .padding({ bottom: 4, top: 4 })

        // Stats
        Row({ space: 16 }) {
          Row({ space: 4 }) {
            Text('\u2605').fontSize(12).fontColor('#007AFF')
            Text(`${this.savedCount}`).fontSize(12).fontColor('#007AFF').fontWeight(FontWeight.Medium)
          }
          Text('\u00B7').fontSize(14).fontColor('#D1D1D6')
          Row({ space: 4 }) {
            Text('\u2717').fontSize(12).fontColor('#AEAEB2')
            Text(`${this.skippedCount}`).fontSize(12).fontColor('#AEAEB2').fontWeight(FontWeight.Medium)
          }
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .padding({ bottom: 32 })
      }
      .width('100%').height('100%')
    }
    .width('100%').layoutWeight(1)
  }
}
